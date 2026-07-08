"""Vehicle speed sources: the real car (via HSFZ/UDS) and a simulator."""

import math
import time

import hsfz

KMH_PER_MPH = 1.609344


class SpeedSourceError(Exception):
    pass


class EnetSpeedSource:
    """Polls vehicle speed from the DME over the MHD ENET adapter.

    Tries UDS ReadDataByIdentifier 0xF40D first (the UDS mirror of OBD
    PID 0x0D, vehicle speed), then falls back to classic OBD service 01.
    Both report whole km/h; the tracker interpolates threshold crossings
    so timing accuracy is far better than the 1 km/h quantization.
    """

    _MODES = [
        ("UDS 22 F40D", b"\x22\xf4\x0d", b"\x62\xf4\x0d"),
        ("OBD 01 0D", b"\x01\x0d", b"\x41\x0d"),
    ]

    def __init__(self, client, ecu=hsfz.DME_ADDR):
        self.client = client
        self.ecu = ecu
        self.mode = None

    def start(self):
        errors = []
        for name, req, prefix in self._MODES:
            try:
                data = self.client.request(self.ecu, req, timeout=3.0)
                if data.startswith(prefix) and len(data) > len(prefix):
                    self.mode = (name, req, prefix)
                    return name
                errors.append(f"{name}: unexpected reply {data.hex()}")
            except Exception as e:  # negative response, timeout, ...
                errors.append(f"{name}: {e}")
        raise SpeedSourceError(
            "could not read vehicle speed from ECU 0x%02X:\n  " % self.ecu
            + "\n  ".join(errors)
        )

    def read(self):
        """Return (timestamp_seconds, speed_kmh)."""
        _, req, prefix = self.mode
        data = self.client.request(self.ecu, req)
        if not data.startswith(prefix) or len(data) <= len(prefix):
            raise SpeedSourceError(f"unexpected reply: {data.hex()}")
        return time.perf_counter(), float(data[len(prefix)])

    def stop(self):
        pass


class SimSpeedSource:
    """Fake M240i pull for testing without the car.

    Sits still for 2 s, launches into a pull that tapers off past 130,
    then lifts and brakes back to a stop — so it exercises both the 0-40
    test range and the full 60-130 run. Output is quantized to whole km/h
    like the real PID. `speedup` > 1 runs faster than real time
    (timestamps are virtual, so run math is unaffected).
    """

    def __init__(self, rate=25.0, speedup=1.0):
        self.dt = 1.0 / rate
        self.speedup = speedup
        self.t = 0.0
        self.mph = 0.0
        self._lifted = False
        self._launch_t = 2.0

    def start(self):
        return "simulator"

    def _accel(self, mph):
        if not self._lifted:
            if self.t < self._launch_t:
                return 0.0                  # stationary before the launch
            # tapering pull: ~10 mph/s off the line down to ~3.5 mph/s at 130
            if mph < 138.0:
                return max(1.0, 10.0 - 0.047 * mph)
            self._lifted = True
        if mph <= 0.0:                      # stopped again: queue the next pull
            self._lifted = False
            self._launch_t = self.t + 3.0
            return 0.0
        return -6.0                         # lifted / braking to a stop

    def read(self):
        self.t += self.dt
        self.mph = max(0.0, self.mph + self._accel(self.mph) * self.dt)
        if self.speedup < 100:
            time.sleep(self.dt / self.speedup)
        kmh_quantized = float(round(self.mph * KMH_PER_MPH))
        return self.t, kmh_quantized

    def stop(self):
        pass
