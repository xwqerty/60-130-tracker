"""Minimal HSFZ (BMW "High-Speed Fahrzeugzugang") client.

This is the diagnostics-over-Ethernet protocol BMW F/G-series cars speak on
the OBD port's ethernet pins. The MHD WiFi adapter (ENET mode) bridges your
laptop's WiFi straight onto that network, so we talk to the car exactly like
ISTA/E-SYS do:

  - UDP broadcast on port 6811: gateway (ZGW) discovery / identification
  - TCP on port 6801: HSFZ framed diagnostic messages (UDS inside)

Frame layout (both directions):

  [4 bytes payload length, big-endian][2 bytes control word][payload]

For diagnostic messages (control word 0x0001) the payload is:

  [source address][target address][UDS bytes...]
"""

import socket
import struct

HSFZ_PORT = 6801
DISCOVERY_PORT = 6811

CTRL_DIAG = 0x0001        # diagnostic request/response (UDS payload)
CTRL_ACK = 0x0002         # gateway acknowledges our request
CTRL_IDENT = 0x0011       # identification (used for UDP discovery)
CTRL_ALIVE = 0x0012       # gateway pings us; must answer or it drops us
CTRL_ALIVE_RESP = 0x0013

TESTER_ADDR = 0xF4        # standard tester/diagnostic tool address
DME_ADDR = 0x12           # engine ECU on F/G series

# NRC 0x78 = "response pending", ECU asks us to keep waiting
NRC_RESPONSE_PENDING = 0x78


class HsfzError(Exception):
    pass


class NegativeResponse(HsfzError):
    def __init__(self, service, nrc):
        self.service = service
        self.nrc = nrc
        super().__init__(f"negative response to service 0x{service:02X}, NRC 0x{nrc:02X}")


def discover(timeout=3.0):
    """Broadcast an HSFZ identification request; return (gateway_ip, ident_bytes) or None.

    The ZGW answers from its own IP with an identification string that
    contains the VIN, so this also doubles as a "is the car awake" check.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.settimeout(timeout)
        msg = struct.pack(">IH", 0, CTRL_IDENT)
        sock.sendto(msg, ("255.255.255.255", DISCOVERY_PORT))
        try:
            data, addr = sock.recvfrom(1024)
            return addr[0], data
        except socket.timeout:
            return None
    finally:
        sock.close()


class HsfzClient:
    """TCP HSFZ connection to the vehicle gateway."""

    def __init__(self, host, port=HSFZ_PORT, timeout=5.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock = None
        self._buf = b""

    def connect(self):
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        # Speed polling is many tiny request/response pairs; disable Nagle.
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            finally:
                self.sock = None

    # -- framing ----------------------------------------------------------

    def _send_frame(self, ctrl, payload=b""):
        self.sock.sendall(struct.pack(">IH", len(payload), ctrl) + payload)

    def _recv_exact(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise HsfzError("connection closed by gateway")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def _recv_frame(self):
        header = self._recv_exact(6)
        length, ctrl = struct.unpack(">IH", header)
        payload = self._recv_exact(length) if length else b""
        return ctrl, payload

    # -- diagnostics ------------------------------------------------------

    def request(self, target, uds, timeout=None):
        """Send a UDS request to `target` ECU, return the positive response bytes.

        Handles gateway ACK frames, alive-check pings, and NRC 0x78
        (response pending) transparently.
        """
        self.sock.settimeout(timeout or self.timeout)
        self._send_frame(CTRL_DIAG, bytes([TESTER_ADDR, target]) + uds)

        while True:
            ctrl, payload = self._recv_frame()

            if ctrl == CTRL_ACK:
                continue
            if ctrl == CTRL_ALIVE:
                # Answer with our tester address or the gateway drops the link.
                self._send_frame(CTRL_ALIVE_RESP, struct.pack(">H", TESTER_ADDR))
                continue
            if ctrl != CTRL_DIAG or len(payload) < 3:
                continue

            src, dst, data = payload[0], payload[1], payload[2:]
            if dst != TESTER_ADDR or src != target:
                continue

            if data[0] == 0x7F and len(data) >= 3:
                if data[2] == NRC_RESPONSE_PENDING:
                    continue  # ECU is working on it; keep waiting
                raise NegativeResponse(data[1], data[2])

            return data
