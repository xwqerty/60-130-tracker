// Minimal HSFZ (BMW diagnostics-over-Ethernet) client — Swift port of hsfz.py.
//
// The MHD WiFi adapter bridges the phone's WiFi onto the car's diagnostic
// ethernet. We speak the same protocol ISTA/E-SYS use: TCP port 6801,
// frames of [4-byte big-endian payload length][2-byte control word][payload],
// where diagnostic payloads are [source addr][target addr][UDS bytes...].
//
// iOS note: UDP broadcast discovery (port 6811) needs Apple's multicast
// entitlement, so instead we try the known adapter/gateway IPs directly —
// the HSFZ port is fixed, and the MHD adapter hands out addresses in a
// known subnet.

import Foundation
import Network

enum Hsfz {
    static let port: UInt16 = 6801
    static let ctrlDiag: UInt16 = 0x0001
    static let ctrlAck: UInt16 = 0x0002
    static let ctrlAlive: UInt16 = 0x0012
    static let ctrlAliveResp: UInt16 = 0x0013
    static let testerAddr: UInt8 = 0xF4
    static let dmeAddr: UInt8 = 0x12
    static let nrcResponsePending: UInt8 = 0x78
}

enum HsfzError: Error, LocalizedError {
    case connectionClosed
    case connectFailed(String)
    case timeout
    case negativeResponse(service: UInt8, nrc: UInt8)

    var errorDescription: String? {
        switch self {
        case .connectionClosed: return "connection closed by gateway"
        case .connectFailed(let s): return "connect failed: \(s)"
        case .timeout: return "timed out waiting for the ECU"
        case .negativeResponse(let s, let n):
            return String(format: "negative response to 0x%02X, NRC 0x%02X", s, n)
        }
    }
}

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw HsfzError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

final class HsfzClient: @unchecked Sendable {
    private let connection: NWConnection
    private let connectTimeout: Double
    private var buffer = Data()

    init(host: String, connectTimeout: Double = 4.0) {
        self.connectTimeout = connectTimeout
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true          // speed polling is many tiny request/response pairs
        tcp.connectionTimeout = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .wifi   // the adapter is only ever on WiFi
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: Hsfz.port)!,
                                  using: params)
    }

    func connect() async throws {
        try await withTimeout(connectTimeout) { [connection] in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumed = Locked(false)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumed.takeOnce() { cont.resume() }
                    case .failed(let err):
                        if resumed.takeOnce() { cont.resume(throwing: HsfzError.connectFailed(err.localizedDescription)) }
                    case .waiting(let err):
                        // "waiting" means unreachable for our purposes — fail fast
                        connection.cancel()
                        if resumed.takeOnce() { cont.resume(throwing: HsfzError.connectFailed(err.localizedDescription)) }
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }
    }

    func close() {
        connection.cancel()
    }

    // MARK: framing

    private func sendFrame(ctrl: UInt16, payload: Data) async throws {
        var frame = Data(capacity: 6 + payload.count)
        var len = UInt32(payload.count).bigEndian
        var ctrlBE = ctrl.bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &ctrlBE) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func receiveExact(_ n: Int) async throws -> Data {
        while buffer.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                    if let err { cont.resume(throwing: err) }
                    else if let data, !data.isEmpty { cont.resume(returning: data) }
                    else if isComplete { cont.resume(throwing: HsfzError.connectionClosed) }
                    else { cont.resume(returning: Data()) }
                }
            }
            buffer.append(chunk)
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    private func receiveFrame() async throws -> (ctrl: UInt16, payload: Data) {
        let header = try await receiveExact(6)
        let length = header.subdata(in: 0..<4).reduce(0) { ($0 << 8) | UInt32($1) }
        let ctrl = UInt16(header[4]) << 8 | UInt16(header[5])
        let payload = length > 0 ? try await receiveExact(Int(length)) : Data()
        return (ctrl, payload)
    }

    // MARK: diagnostics

    /// Send a UDS request to `target`, return the positive response bytes.
    /// Handles gateway ACKs, alive-check pings, and NRC 0x78 transparently.
    func request(target: UInt8, uds: Data, timeout: Double = 2.0) async throws -> Data {
        try await withTimeout(timeout) { [self] in
            try await sendFrame(ctrl: Hsfz.ctrlDiag, payload: Data([Hsfz.testerAddr, target]) + uds)
            while true {
                let (ctrl, payload) = try await receiveFrame()
                if ctrl == Hsfz.ctrlAck { continue }
                if ctrl == Hsfz.ctrlAlive {
                    try await sendFrame(ctrl: Hsfz.ctrlAliveResp, payload: Data([0x00, Hsfz.testerAddr]))
                    continue
                }
                guard ctrl == Hsfz.ctrlDiag, payload.count >= 3 else { continue }
                let src = payload[payload.startIndex]
                let dst = payload[payload.startIndex + 1]
                let data = payload.dropFirst(2)
                guard dst == Hsfz.testerAddr, src == target else { continue }
                if data.first == 0x7F, data.count >= 3 {
                    let service = data[data.index(data.startIndex, offsetBy: 1)]
                    let nrc = data[data.index(data.startIndex, offsetBy: 2)]
                    if nrc == Hsfz.nrcResponsePending { continue }
                    throw HsfzError.negativeResponse(service: service, nrc: nrc)
                }
                return Data(data)
            }
        }
    }
}

/// Tiny lock for one-shot continuation resumption.
final class Locked: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ v: Bool) { value = v }
    func takeOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
