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
        SpeedRange(key: "60–130", start: 60, end: 130),
        SpeedRange(key: "0–40 test", start: 0, end: 40),
        SpeedRange(key: "30–100", start: 30, end: 100),
    ]
}

@MainActor
final class Engine: ObservableObject {
    @Published var phase: Phase = .searching
    @Published var mph: Double = 0
    @Published var detail = ""
    @Published var elapsed: Double?
    @Published var armedRange: SpeedRange?
    @Published var results: [RunResult] = []

    @AppStorage("customHost") var customHost = ""
    @AppStorage("lastHost") var lastHost = ""
    @AppStorage("demoMode") var demoMode = Engine.isSimulator

    // GPS calibration of ECU wheel speed
    let gps = GpsSpeed()
    @AppStorage("gpsCalEnabled") var gpsCalEnabled = true
    @AppStorage("speedFactor") var speedFactor = 1.0
    @AppStorage("speedFactorSamples") var speedFactorSamples = 0
    private var lastCalUpdate = Date.distantPast
    static let minCalSamples = 20

    /// True once enough GPS/ECU comparisons have been collected.
    var calibrated: Bool { gpsCalEnabled && speedFactorSamples >= Engine.minCalSamples }

    lazy var scanner = DidScanner(engine: self)

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
    private var autoArmed = false
    private var lastT: Double = 0
    private let resultsURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("results.json")

    init() {
        if let data = try? Data(contentsOf: resultsURL),
           let saved = try? JSONDecoder().decode([RunResult].self, from: data) {
            results = saved
        }
        gps.start()
        start()
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
        guard gpsCalEnabled, !demoMode,
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
            let (source, client) = await connect()
            guard let source else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            phase = .ready
            if CommandLine.arguments.contains("-autoArm"), !autoArmed {
                autoArmed = true
                arm(SpeedRange.all[0])
            }
            do {
                while !Task.isCancelled {
                    let (t, kmh) = try await source.read()
                    let rawMph = kmh / kmhPerMph
                    updateCalibration(rawMph: rawMph)
                    let mphNow = calibrated ? rawMph * speedFactor : rawMph
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
                // lost the adapter; fall through and reconnect
            }
            client?.close()
            phase = .searching
            mph = 0
            disarm()
            phase = .searching
        }
    }

    private func connect() async -> (SpeedSource?, HsfzClient?) {
        if demoMode {
            detail = "SIMULATOR"
            return (SimSpeedSource(), nil)
        }

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
        if let hit = await probe(hosts: hosts) { return (hit.0, hit.1) }

        // Known IPs silent: sweep the phone's own /24 for the HSFZ port.
        if let ip = phoneIP, let dot = ip.lastIndex(of: ".") {
            let prefix = String(ip[..<dot])
            detail = "phone \(ip) — scanning \(prefix).x…"
            if let found = await scanSubnet(prefix: prefix, excluding: ip),
               let hit = await probe(hosts: [found]) {
                return (hit.0, hit.1)
            }
        }

        detail = phoneIP.map {
            "phone \($0) — nothing answered. Allow Local Network in Settings; force-close the MHD app"
        } ?? "no WiFi — join the MHD ENET network"
        return (nil, nil)
    }

    private func probe(hosts: [String]) async -> (SpeedSource, HsfzClient)? {
        for host in hosts {
            let client = HsfzClient(host: host)
            do {
                try await client.connect()
                let source = EnetSpeedSource(client: client)
                let mode = try await source.start()
                detail = "\(host) · \(mode)"
                lastHost = host
                return (source, client)
            } catch {
                client.close()
            }
        }
        return nil
    }
}
