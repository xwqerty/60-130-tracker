// Background engine: finds the adapter, polls speed, times armed runs.
// Swift port of the Engine class in app.py.

import Foundation
import SwiftUI

enum Phase: String {
    case searching, ready, armed, recording
}

struct SpeedRange: Hashable, Identifiable {
    let key: String
    let start: Double
    let end: Double
    var id: String { key }

    static let all: [SpeedRange] = [
        SpeedRange(key: "0–60", start: 0, end: 60),
        SpeedRange(key: "60–130", start: 60, end: 130),
        SpeedRange(key: "30–100", start: 30, end: 100),
    ]
}

/// How the app gets vehicle speed.
enum ConnectionMode: String, CaseIterable, Identifiable {
    case bmw, obd, gps, demo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bmw: "BMW · MHD / ENET adapter"
        case .obd: "Any car · Wi-Fi OBD (ELM327)"
        case .gps: "Phone GPS only — no adapter"
        case .demo: "Demo — simulated car"
        }
    }
    /// ECU-based sources whose speed benefits from GPS calibration.
    var isECU: Bool { self == .bmw || self == .obd }
}

@MainActor
final class Engine: ObservableObject {
    @Published var phase: Phase = .searching
    @Published var mph: Double = 0
    @Published var detail = ""
    @Published var elapsed: Double?
    @Published var armedRange: SpeedRange?
    @Published var results: [RunResult] = []

    @AppStorage("customHost") var customHost = ""      // BMW adapter IP override
    @AppStorage("obdHost") var obdHost = "192.168.0.10" // ELM327 Wi-Fi adapter IP
    @AppStorage("lastHost") var lastHost = ""
    @AppStorage("connModeRaw") var connModeRaw =
        (Engine.isSimulator ? ConnectionMode.demo : ConnectionMode.bmw).rawValue

    var connMode: ConnectionMode {
        get { ConnectionMode(rawValue: connModeRaw) ?? .bmw }
        set { connModeRaw = newValue.rawValue }
    }
    var demoMode: Bool { connMode == .demo }

    static let defaultObdPort: UInt16 = 35000

    // GPS calibration of ECU wheel speed
    let gps = GpsSpeed()
    @AppStorage("gpsCalEnabled") var gpsCalEnabled = true
    @AppStorage("speedFactor") var speedFactor = 1.0
    @AppStorage("speedFactorSamples") var speedFactorSamples = 0
    private var lastCalUpdate = Date.distantPast
    static let minCalSamples = 20

    /// True once enough GPS/ECU comparisons have been collected.
    var calibrated: Bool { gpsCalEnabled && speedFactorSamples >= Engine.minCalSamples }

    #if DEBUG
    lazy var scanner = DidScanner(engine: self)   // developer diagnostic; excluded from release
    #endif

    static let fallbackHosts = ["192.168.16.254", "169.254.128.7"]

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private var tracker: RunTracker?
    private var worker: Task<Void, Never>?
    private var lastT: Double = 0
    private let resultsURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("results.json")

    init() {
        if let data = try? Data(contentsOf: resultsURL),
           let saved = try? JSONDecoder().decode([RunResult].self, from: data) {
            results = saved
        }
        // The worker (and any GPS/location request) is started by the app only
        // after the safety gate and onboarding, so nothing prompts prematurely.
    }

    func start() {
        worker?.cancel()
        worker = Task { await runLoop() }
    }

    /// Release the timing connection so the DID scanner can hold the only
    /// diagnostic session on the gateway.
    func suspendTiming() {
        worker?.cancel()
        worker = nil
        phase = .searching
        mph = 0
    }

    func resumeTiming() {
        if worker == nil { start() }
    }

    func arm(_ range: SpeedRange) {
        guard phase == .ready else { return }
        let note = calibrated
            ? String(format: "speed_correction: %+.2f%% (GPS-calibrated, %d fixes)",
                     (speedFactor - 1) * 100, speedFactorSamples)
            : nil
        tracker = RunTracker(startMph: range.start, endMph: range.end, note: note)
        armedRange = range
        phase = .armed
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func cancel() {
        if let r = tracker?.flush() { store(r) }
        disarm()
    }

    private func disarm() {
        tracker = nil
        armedRange = nil
        elapsed = nil
        if phase != .searching { phase = .ready }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func clearResults() {
        results.removeAll()
        try? FileManager.default.removeItem(at: resultsURL)
    }

    private func store(_ r: RunResult) {
        results.insert(r, at: 0)
        if let data = try? JSONEncoder().encode(results) {
            try? data.write(to: resultsURL)
        }
    }

    /// Compare GPS speed against ECU speed during steady, well-measured
    /// driving and fold the ratio into a slow-moving correction factor.
    private func updateCalibration(rawMph: Double) {
        guard gpsCalEnabled, connMode.isECU,
              let gpsMph = gps.mph, gps.accuracyOK,
              gps.lastUpdate > lastCalUpdate,               // one sample per GPS fix
              Date().timeIntervalSince(gps.lastUpdate) < 1.5,
              rawMph > 30, gpsMph > 30,                     // moving; ratio well-conditioned
              phase != .recording                           // hard acceleration skews latency
        else { return }
        lastCalUpdate = gps.lastUpdate
        let ratio = min(max(gpsMph / rawMph, 0.9), 1.1)     // reject outliers
        let alpha = speedFactorSamples < Engine.minCalSamples ? 0.15 : 0.02
        speedFactor = speedFactorSamples == 0 ? ratio : speedFactor * (1 - alpha) + ratio * alpha
        speedFactorSamples += 1
    }

    func resetCalibration() {
        speedFactor = 1.0
        speedFactorSamples = 0
    }

    // MARK: worker

    private func runLoop() async {
        while !Task.isCancelled {
            let (source, teardown) = await connect()
            guard let source else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            phase = .ready
            do {
                while !Task.isCancelled {
                    let (t, kmh) = try await source.read()
                    let rawMph = kmh / kmhPerMph
                    updateCalibration(rawMph: rawMph)
                    // GPS/demo speed is already ground truth; only scale ECU sources.
                    let mphNow = (connMode.isECU && calibrated) ? rawMph * speedFactor : rawMph
                    mph = mphNow
                    lastT = t
                    if let tracker {
                        if let result = tracker.addSample(t: t, mph: mphNow) {
                            store(result)
                            disarm()
                        } else if tracker.state == .recording {
                            phase = .recording
                            elapsed = tracker.tStart.map { t - $0 }
                        }
                    }
                }
            } catch {
                // lost the source; fall through and reconnect
            }
            teardown?()
            phase = .searching
            mph = 0
            disarm()
            phase = .searching
        }
    }

    private func connect() async -> (SpeedSource?, (() -> Void)?) {
        switch connMode {
        case .demo:
            detail = "SIMULATOR"
            return (SimSpeedSource(), nil)
        case .gps:
            gps.start()
            // Don't claim "connected" until GPS is actually usable. Until then
            // we return nil so the loop keeps showing "acquiring", then flips
            // to ready the moment a real fix arrives.
            guard gps.authorized else {
                detail = "Allow Location in Settings to use GPS mode"
                return (nil, nil)
            }
            guard gps.hasFix else {
                detail = "Acquiring GPS…"
                return (nil, nil)
            }
            detail = "phone GPS"
            return (GpsSpeedSource(gps: gps), nil)
        case .obd:
            return await connectElm()
        case .bmw:
            return await connectBmw()
        }
    }

    // MARK: BMW (HSFZ / ENET)

    private func connectBmw() async -> (SpeedSource?, (() -> Void)?) {
        let phoneIP = wifiIPv4()
        var hosts: [String] = []
        let custom = customHost.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { hosts.append(custom) }
        if !lastHost.isEmpty { hosts.append(lastHost) }
        hosts += Self.fallbackHosts
        var seen = Set<String>()
        hosts = hosts.filter { seen.insert($0).inserted }

        detail = phoneIP.map { "phone \($0) — trying known IPs…" }
            ?? "no WiFi — join the MHD ENET network"
        if let hit = await probe(hosts: hosts) { return hit }

        // Known IPs silent: sweep the phone's own /24 for the HSFZ port.
        if let ip = phoneIP, let dot = ip.lastIndex(of: ".") {
            let prefix = String(ip[..<dot])
            detail = "phone \(ip) — scanning \(prefix).x…"
            if let found = await scanSubnet(prefix: prefix, excluding: ip),
               let hit = await probe(hosts: [found]) {
                return hit
            }
        }

        detail = phoneIP.map {
            "phone \($0) — nothing answered. Allow Local Network in Settings; force-close the MHD app"
        } ?? "no WiFi — join the MHD ENET network"
        return (nil, nil)
    }

    private func probe(hosts: [String]) async -> (SpeedSource, (() -> Void))? {
        for host in hosts {
            let client = HsfzClient(host: host)
            do {
                try await client.connect()
                let source = EnetSpeedSource(client: client)
                let mode = try await source.start()
                detail = "\(host) · \(mode)"
                lastHost = host
                return (source, { client.close() })
            } catch {
                client.close()
            }
        }
        return nil
    }

    // MARK: generic OBD (ELM327 Wi-Fi)

    private func connectElm() async -> (SpeedSource?, (() -> Void)?) {
        let host = obdHost.trimmingCharacters(in: .whitespaces)
        detail = "connecting to OBD adapter \(host)…"
        let client = Elm327Client(host: host, port: Engine.defaultObdPort)
        do {
            try await client.connect()
            let source = Elm327SpeedSource(client: client)
            let mode = try await source.start()
            detail = "\(host) · \(mode)"
            return (source, { client.close() })
        } catch {
            client.close()
            detail = "no OBD adapter at \(host) — join its Wi-Fi, ignition on. Set its IP in Settings if different."
            return (nil, nil)
        }
    }
}
