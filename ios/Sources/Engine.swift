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
    @AppStorage("demoMode") var demoMode = Engine.isSimulator

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
        start()
    }

    func start() {
        worker?.cancel()
        worker = Task { await runLoop() }
    }

    func arm(_ range: SpeedRange) {
        guard phase == .ready else { return }
        tracker = RunTracker(startMph: range.start, endMph: range.end)
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
                    let mphNow = kmh / kmhPerMph
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
        var hosts = Self.fallbackHosts
        let custom = customHost.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { hosts.insert(custom, at: 0) }

        for host in hosts {
            let client = HsfzClient(host: host)
            do {
                try await client.connect()
                let source = EnetSpeedSource(client: client)
                let mode = try await source.start()
                detail = "\(host) · \(mode)"
                return (source, client)
            } catch {
                client.close()
            }
        }
        return (nil, nil)
    }
}
