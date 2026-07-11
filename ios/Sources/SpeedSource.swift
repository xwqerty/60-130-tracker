// Vehicle speed sources — Swift port of speed.py.

import Foundation

let kmhPerMph = 1.609344

protocol SpeedSource {
    /// Probe / initialize; returns a human-readable mode description.
    func start() async throws -> String
    /// Returns (monotonic timestamp seconds, speed in km/h).
    func read() async throws -> (t: Double, kmh: Double)
}

/// Polls vehicle speed from the DME over the MHD ENET adapter.
/// Tries UDS ReadDataByIdentifier 0xF40D (the UDS mirror of OBD PID 0x0D)
/// first, then falls back to classic OBD service 01.
final class EnetSpeedSource: SpeedSource, @unchecked Sendable {
    private let client: HsfzClient
    private let ecu: UInt8
    private var mode: (name: String, request: Data, prefix: Data)?

    private static let modes: [(String, Data, Data)] = [
        ("UDS 22 F40D", Data([0x22, 0xF4, 0x0D]), Data([0x62, 0xF4, 0x0D])),
        ("OBD 01 0D", Data([0x01, 0x0D]), Data([0x41, 0x0D])),
    ]

    init(client: HsfzClient, ecu: UInt8 = Hsfz.dmeAddr) {
        self.client = client
        self.ecu = ecu
    }

    func start() async throws -> String {
        var lastError: Error = HsfzError.timeout
        for (name, request, prefix) in Self.modes {
            do {
                let data = try await client.request(target: ecu, uds: request, timeout: 3.0)
                if data.starts(with: prefix), data.count > prefix.count {
                    mode = (name, request, prefix)
                    return name
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func read() async throws -> (t: Double, kmh: Double) {
        guard let mode else { throw HsfzError.connectionClosed }
        let data = try await client.request(target: ecu, uds: mode.request)
        guard data.starts(with: mode.prefix), data.count > mode.prefix.count else {
            throw HsfzError.connectionClosed
        }
        let raw = data[data.index(data.startIndex, offsetBy: mode.prefix.count)]
        return (ProcessInfo.processInfo.systemUptime, Double(raw))
    }
}

/// Times runs from the phone's own GPS speed — works on any car (or none),
/// no adapter required. GPS updates ~1 Hz, so timing is coarser than an ECU
/// feed; best with a clear view of the sky. This is the universal "try it
/// now" source; the adapter modes are the precision upgrade.
final class GpsSpeedSource: SpeedSource, @unchecked Sendable {
    private let gps: GpsSpeed
    private var lastStamp = Date.distantPast

    init(gps: GpsSpeed) { self.gps = gps }

    func start() async throws -> String {
        gps.start()
        for _ in 0..<40 where !gps.hasFix {     // wait up to ~8 s for a first fix
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return "phone GPS"
    }

    func read() async throws -> (t: Double, kmh: Double) {
        // Emit one sample per fresh GPS fix (~1 Hz) rather than spinning.
        for _ in 0..<300 {
            if gps.lastUpdate != lastStamp {
                lastStamp = gps.lastUpdate
                return (ProcessInfo.processInfo.systemUptime, (gps.mph ?? 0) * kmhPerMph)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return (ProcessInfo.processInfo.systemUptime, (gps.mph ?? 0) * kmhPerMph)
    }
}

/// Fake M240i for the iOS simulator / demo mode: sits still 3 s, pulls to
/// ~138 mph, brakes to a stop, repeats. Quantized to whole km/h like the
/// real PID.
final class SimSpeedSource: SpeedSource, @unchecked Sendable {
    private let dt = 1.0 / 25.0
    private var t = 0.0
    private var mph = 0.0
    private var lifted = false
    private var launchT = 3.0

    func start() async throws -> String { "simulator" }

    private func accel() -> Double {
        if !lifted {
            if t < launchT { return 0 }
            if mph < 138 { return max(1.0, 10.0 - 0.047 * mph) }
            lifted = true
        }
        if mph <= 0 {
            lifted = false
            launchT = t + 3.0
            return 0
        }
        return -6.0
    }

    func read() async throws -> (t: Double, kmh: Double) {
        t += dt
        mph = max(0, mph + accel() * dt)
        try await Task.sleep(nanoseconds: UInt64(dt * 1_000_000_000))
        return (t, (mph * kmhPerMph).rounded())
    }
}
