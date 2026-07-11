// Generic OBD-II support via an ELM327 Wi-Fi adapter.
//
// The cheap "Wi-Fi OBD" dongles on Amazon are almost all ELM327 clones:
// they host their own Wi-Fi network and expose a raw TCP socket (default
// 192.168.0.10:35000) that speaks ELM327 AT commands. We init the adapter,
// then poll standard OBD PID 01 0D (vehicle speed, km/h) — universal on
// every 2008+ car — so the timer works on anything, not just BMWs.

import Foundation
import Network

final class Elm327Client: @unchecked Sendable {
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 4
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .wifi   // the adapter is a Wi-Fi hotspot
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: params)
    }

    func connect() async throws {
        try await withTimeout(5) { [connection] in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = Locked(false)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.takeOnce() { cont.resume() }
                    case .failed(let err):
                        if once.takeOnce() { cont.resume(throwing: err) }
                    case .waiting(let err):
                        connection.cancel()
                        if once.takeOnce() { cont.resume(throwing: err) }
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }
    }

    func close() { connection.cancel() }

    /// Send one AT/OBD command and read the reply up to the ELM327 '>' prompt.
    func command(_ cmd: String, timeout: Double = 2.0) async throws -> String {
        try await withTimeout(timeout) { [self] in
            try await send(Data((cmd + "\r").utf8))
            var text = ""
            while !text.contains(">") {
                let chunk = try await receive()
                if chunk.isEmpty { continue }
                text += String(decoding: chunk, as: UTF8.self)
            }
            return text
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, isComplete, err in
                if let err { cont.resume(throwing: err) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(throwing: HsfzError.connectionClosed) }
                else { cont.resume(returning: Data()) }
            }
        }
    }
}

final class Elm327SpeedSource: SpeedSource, @unchecked Sendable {
    private let client: Elm327Client

    init(client: Elm327Client) { self.client = client }

    func start() async throws -> String {
        // Reset, echo off, no linefeeds/spaces/headers, auto protocol.
        for cmd in ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"] {
            _ = try? await client.command(cmd, timeout: 3.0)
        }
        // The first speed read may return "SEARCHING…" while the protocol
        // negotiates — retry a few times before giving up.
        for _ in 0..<4 {
            if let resp = try? await client.command("010D", timeout: 3.0),
               parseSpeedKmh(resp) != nil {
                return "OBD 01 0D (ELM327)"
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw HsfzError.connectFailed("adapter connected but no speed PID (01 0D) — is the ignition on?")
    }

    func read() async throws -> (t: Double, kmh: Double) {
        let resp = try await client.command("010D", timeout: 1.5)
        guard let kmh = parseSpeedKmh(resp) else { throw HsfzError.connectionClosed }
        return (ProcessInfo.processInfo.systemUptime, Double(kmh))
    }

    /// Parse an OBD response containing "41 0D XX" → XX km/h. Tolerant of
    /// spaces, echo, headers, and multi-line replies.
    private func parseSpeedKmh(_ resp: String) -> Int? {
        let hex = resp.uppercased().filter(\.isHexDigit)
        guard let r = hex.range(of: "410D") else { return nil }
        let after = hex[r.upperBound...]
        guard after.count >= 2 else { return nil }
        return Int(after.prefix(2), radix: 16)
    }
}
