// Run detection, timing, and CSV logging — Swift port of runlog.py.
//
// State machine fed with (timestamp, mph) samples. The exact threshold
// crossing times are linearly interpolated between samples, so timing
// accuracy is much finer than the polling interval. A start threshold of
// 0 mph means "clock starts at first movement".

import Foundation

struct RunResult: Identifiable, Codable, Equatable {
    var id = UUID()
    var when: Date
    var range: String
    var splitLabels: [String]
    var complete: Bool
    var total: Double?
    var split1: Double?
    var split2: Double?
    var vmaxMph: Double
    var sampleRateHz: Double
    var fileName: String?
}

final class RunTracker {
    enum State { case armed, recording, cooldown }

    static let abortDropMph = 4.0
    static let prerollSeconds = 3.0
    static let rearmMarginMph = 5.0

    let startMph: Double
    let endMph: Double
    let splitMph: Double
    let rearmMph: Double
    let label: String
    let splitLabels: [String]
    let note: String?

    private(set) var state: State = .armed
    private(set) var tStart: Double?
    private var tSplit: Double?
    private var tEnd: Double?
    private var prev: (t: Double, mph: Double)?
    private var preroll: [(t: Double, mph: Double)] = []
    private var samples: [(t: Double, mph: Double)] = []
    private var vmax = 0.0

    init(startMph: Double, endMph: Double, note: String? = nil) {
        self.startMph = startMph
        self.endMph = endMph
        self.note = note
        // 60-130 keeps the traditional 100 split; other ranges use the midpoint
        self.splitMph = (startMph == 60 && endMph == 130) ? 100 : (startMph + endMph) / 2
        self.rearmMph = max(startMph - Self.rearmMarginMph, 0)
        let f = { (v: Double) in v == v.rounded() ? String(Int(v)) : String(v) }
        self.label = "\(f(startMph))-\(f(endMph))"
        self.splitLabels = ["\(f(startMph))-\(f(splitMph))", "\(f(splitMph))-\(f(endMph))"]
    }

    private static func interpTime(_ t0: Double, _ v0: Double, _ t1: Double, _ v1: Double,
                                   threshold: Double) -> Double {
        v1 == v0 ? t1 : t0 + (threshold - v0) / (v1 - v0) * (t1 - t0)
    }

    private func crossedStart(_ prevMph: Double, _ mph: Double) -> Bool {
        startMph == 0 ? (prevMph <= 0 && mph > 0) : (prevMph < startMph && mph >= startMph)
    }

    /// Feed one sample; returns a result when a run just ended.
    func addSample(t: Double, mph: Double) -> RunResult? {
        defer { prev = (t, mph) }
        let p = prev

        switch state {
        case .armed:
            preroll.append((t, mph))
            while let first = preroll.first, t - first.t > Self.prerollSeconds {
                preroll.removeFirst()
            }
            if let p, crossedStart(p.mph, mph) {
                state = .recording
                tStart = Self.interpTime(p.t, p.mph, t, mph, threshold: startMph)
                tSplit = nil; tEnd = nil
                vmax = mph
                samples = preroll + [(t, mph)]
            }

        case .recording:
            samples.append((t, mph))
            vmax = max(vmax, mph)
            if let p, p.mph < splitMph, mph >= splitMph {
                tSplit = Self.interpTime(p.t, p.mph, t, mph, threshold: splitMph)
            }
            if let p, p.mph < endMph, mph >= endMph {
                tEnd = Self.interpTime(p.t, p.mph, t, mph, threshold: endMph)
                return finish(complete: true)
            }
            if mph < vmax - Self.abortDropMph {
                return finish(complete: false)
            }

        case .cooldown:
            if mph <= rearmMph {
                state = .armed
                preroll.removeAll()
            }
        }
        return nil
    }

    /// Save whatever is in progress (e.g. cancel mid-run).
    func flush() -> RunResult? {
        state == .recording && !samples.isEmpty ? finish(complete: false) : nil
    }

    private func finish(complete: Bool) -> RunResult {
        let tStart = tStart ?? samples.first?.t ?? 0
        let run = samples.filter { $0.t >= tStart }
        let rate = run.count > 1 ? Double(run.count - 1) / (run.last!.t - run.first!.t) : 0

        var result = RunResult(
            when: Date(),
            range: label,
            splitLabels: splitLabels,
            complete: complete,
            total: complete ? tEnd.map { $0 - tStart } : nil,
            split1: tSplit.map { $0 - tStart },
            split2: (complete && tSplit != nil) ? tEnd.map { $0 - tSplit! } : nil,
            vmaxMph: vmax,
            sampleRateHz: rate
        )
        result.fileName = writeCSV(result, tStart: tStart)
        state = .cooldown
        samples.removeAll()
        return result
    }

    private func writeCSV(_ r: RunResult, tStart: Double) -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let tag = r.complete ? "" : "_partial"
        let name = "run_\(label)_\(fmt.string(from: r.when))\(tag).csv"

        var text = "# \(label) run, \(r.when.ISO8601Format())\n"
        if let v = r.total { text += "# \(label): \(String(format: "%.2f", v)) s\n" }
        if let v = r.split1 { text += "# \(splitLabels[0]): \(String(format: "%.2f", v)) s\n" }
        if let v = r.split2 { text += "# \(splitLabels[1]): \(String(format: "%.2f", v)) s\n" }
        text += "# vmax: \(String(format: "%.1f", r.vmaxMph)) mph\n"
        if let note { text += "# \(note)\n" }
        text += "t_s,mph,kmh\n"
        for (t, mph) in samples {
            text += String(format: "%.3f,%.1f,%.1f\n", t - tStart, mph, mph * kmhPerMph)
        }

        do {
            let dir = try FileManager.default
                .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("logs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return name
        } catch {
            return nil
        }
    }
}
