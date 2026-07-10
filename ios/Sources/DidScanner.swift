// DID scanner — a diagnostic tool to find wheel-speed data identifiers.
//
// Individual wheel speeds live in the DSC/ABS module, not the DME, under
// BMW-specific UDS DataIdentifiers that aren't publicly standardized. This
// scanner finds them empirically:
//
//   1. Pick a target ECU (DSC is the default) and confirm it answers.
//   2. Enumerate which DIDs the ECU responds to (UDS 0x22), parked.
//   3. Live-watch the responders while you roll, decoding each as an array
//      of 16-bit channels and correlating every channel against GPS speed.
//      The four wheel-speed channels give themselves away: correlation ~1.0
//      with GPS, four of them clustered at a consistent scale.
//
// It runs on its own HSFZ connection, and asks the Engine to pause timing
// so only one diagnostic session is live at a time.

import Foundation
import SwiftUI

struct FoundDid: Identifiable {
    let did: UInt16
    let bytes: [UInt8]
    var id: UInt16 { did }
    var hex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    /// Payload decoded as big-endian 16-bit channels (wheel speeds are uint16).
    var words: [UInt16] {
        stride(from: 0, to: bytes.count - 1, by: 2).map {
            UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }
    }
}

/// Running correlation of one decoded channel against GPS speed.
struct ChannelStat: Identifiable {
    let did: UInt16
    let word: Int
    var n = 0
    var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
    var lastRaw = 0.0
    var id: String { String(format: "%04X.%d", did, word) }

    mutating func add(raw: Double, gpsMph: Double) {
        n += 1; lastRaw = raw
        sx += raw; sy += gpsMph
        sxx += raw * raw; syy += gpsMph * gpsMph; sxy += raw * gpsMph
    }
    /// Pearson correlation with GPS speed.
    var correlation: Double {
        let cov = Double(n) * sxy - sx * sy
        let dx = Double(n) * sxx - sx * sx
        let dy = Double(n) * syy - sy * sy
        return dx > 0 && dy > 0 ? cov / (dx * dy).squareRoot() : 0
    }
    /// Best-fit scale mapping raw units → mph (through origin).
    var scaleToMph: Double { sxx > 0 ? sxy / sxx : 0 }
    /// This channel's current predicted speed in mph.
    var predictedMph: Double { lastRaw * scaleToMph }
}

@MainActor
final class DidScanner: ObservableObject {
    enum Preset: String, CaseIterable, Identifiable {
        case dsc = "DSC 0x29", dme = "DME 0x12", srs = "0x40", egs = "EGS 0x18"
        var id: String { rawValue }
        var addr: UInt8 {
            switch self { case .dsc: 0x29; case .dme: 0x12; case .srs: 0x40; case .egs: 0x18 }
        }
    }

    @Published var target: UInt8 = 0x29
    @Published var status = "Not connected"
    @Published var connected = false
    @Published var scanning = false
    @Published var progress = 0.0
    @Published var found: [FoundDid] = []
    @Published var watching = false
    @Published var stats: [String: ChannelStat] = [:]
    @Published var gpsMph: Double?

    // Enumeration window (full 16-bit space by default).
    @Published var rangeStart: UInt16 = 0x0000
    @Published var rangeEnd: UInt16 = 0xFFFF

    private weak var engine: Engine?
    private var client: HsfzClient?
    private var job: Task<Void, Never>?

    init(engine: Engine) { self.engine = engine }

    // MARK: connection

    func connect() async {
        guard let engine else { return }
        if engine.demoMode {
            connected = true
            status = "Demo — simulated DSC"
            return
        }
        engine.suspendTiming()               // release the timing session first
        status = "Connecting…"
        let host = engine.lastHost.isEmpty ? Engine.fallbackHosts[0] : engine.lastHost
        let c = HsfzClient(host: host)
        do {
            try await c.connect()
            // Deliberately NO DiagnosticSessionControl (0x10) here: putting a
            // chassis module (DSC/ABS) into an extended session suspends its
            // normal operation and lights the brake/ABS warnings on the
            // cluster. Plain ReadDataByIdentifier works in the default
            // session and is the same passive read any OBD datalogger does.
            // Liveness: the target must answer *something* — a positive read
            // or a negative response both prove it's on the bus; only a
            // timeout means it's absent.
            _ = await probe(c, did: 0xF190, timeout: 1.5)
            guard lastAnswered else {
                status = String(format: "ECU 0x%02X not answering on this bus", target)
                c.close(); engine.resumeTiming(); return
            }
            client = c
            connected = true
            status = String(format: "Connected to 0x%02X via %@", target, host)
        } catch {
            status = "Connect failed: \(error.localizedDescription)"
            c.close()
            engine.resumeTiming()
        }
    }

    func disconnect() {
        job?.cancel(); job = nil
        client?.close(); client = nil
        connected = false; scanning = false; watching = false
        status = "Not connected"
        engine?.resumeTiming()
    }

    // Per-probe flags: whether the ECU answered at all (positive or NRC),
    // and whether that answer was specifically a negative response.
    private var lastAnswered = false
    private var lastWasNegative = false

    /// Send UDS 0x22 <did> and return the payload if the ECU gave a positive
    /// (0x62) response. NRC and timeout both return nil but set the flags.
    private func probe(_ c: HsfzClient, did: UInt16, timeout: Double) async -> [UInt8]? {
        let uds = Data([0x22, UInt8(did >> 8), UInt8(did & 0xFF)])
        do {
            let resp = try await c.request(target: target, uds: uds, timeout: timeout)
            lastAnswered = true; lastWasNegative = false
            guard resp.count >= 3, resp[resp.startIndex] == 0x62 else { return nil }
            return Array(resp.dropFirst(3))
        } catch let e as HsfzError {
            if case .negativeResponse = e { lastAnswered = true; lastWasNegative = true }
            else { lastAnswered = false; lastWasNegative = false }   // timeout / socket
            return nil
        } catch {
            lastAnswered = false; lastWasNegative = false
            return nil
        }
    }

    // MARK: enumeration

    func scan() {
        guard connected, !scanning else { return }
        if engine?.demoMode == true { demoScan(); return }
        guard let c = client else { return }
        found.removeAll(); scanning = true; progress = 0
        let start = rangeStart, end = rangeEnd
        job = Task {
            let total = Double(Int(end) - Int(start) + 1)
            var did = start
            var absent = 0
            while !Task.isCancelled {
                if let bytes = await probe(c, did: did, timeout: 0.4), !bytes.isEmpty {
                    found.append(FoundDid(did: did, bytes: bytes))
                    absent = 0
                } else if !lastAnswered {
                    // No answer at all (not even a NRC) — the bus may have
                    // dropped; bail after a run of silence.
                    absent += 1
                    if absent > 40 {
                        status = "ECU went silent — stopping scan"
                        break
                    }
                } else {
                    absent = 0                       // NRC = ECU alive, DID absent
                }
                progress = Double(Int(did) - Int(start) + 1) / total
                if did == end { break }
                did &+= 1
            }
            scanning = false
            if !Task.isCancelled {
                status = "Found \(found.count) DIDs on 0x\(String(target, radix: 16))"
            }
        }
    }

    func stopScan() { job?.cancel(); scanning = false }

    // MARK: live watch + correlation

    func startWatch(dids: [UInt16]) {
        guard connected, !watching, !dids.isEmpty else { return }
        watching = true
        stats.removeAll()
        if engine?.demoMode == true { demoWatch(dids: dids); return }
        guard let c = client else { return }
        job = Task {
            while !Task.isCancelled {
                let gps = engine?.gps.mph
                gpsMph = gps
                for did in dids {
                    guard let bytes = await probe(c, did: did, timeout: 0.4) else { continue }
                    let f = FoundDid(did: did, bytes: bytes)
                    if let g = gps, engine?.gps.accuracyOK == true, g > 5 {
                        for (i, w) in f.words.enumerated() {
                            let key = String(format: "%04X.%d", did, i)
                            var s = stats[key] ?? ChannelStat(did: did, word: i)
                            s.add(raw: Double(w), gpsMph: g)
                            stats[key] = s
                        }
                    } else {
                        // still show live raw even without GPS lock
                        for (i, w) in f.words.enumerated() {
                            let key = String(format: "%04X.%d", did, i)
                            var s = stats[key] ?? ChannelStat(did: did, word: i)
                            s.lastRaw = Double(w)
                            stats[key] = s
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 40_000_000)   // ~25 Hz
            }
            watching = false
        }
    }

    func stopWatch() { job?.cancel(); watching = false }

    /// Channels ranked by how strongly they track GPS speed.
    var rankedChannels: [ChannelStat] {
        stats.values.filter { $0.n >= 10 }.sorted { $0.correlation > $1.correlation }
    }

    func exportFindings() -> URL? {
        var text = "# DID scan, target 0x\(String(target, radix: 16))\n"
        text += "did,length,hex\n"
        for f in found {
            text += "0x\(String(format: "%04X", f.did)),\(f.bytes.count),\(f.hex)\n"
        }
        text += "\n# watched channels (correlation vs GPS)\n"
        text += "channel,samples,correlation,scale_to_mph,last_raw,predicted_mph\n"
        for s in rankedChannels {
            text += String(format: "%@,%d,%.4f,%.5f,%.0f,%.1f\n",
                           s.id, s.n, s.correlation, s.scaleToMph, s.lastRaw, s.predictedMph)
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("did_scan_0x\(String(target, radix: 16)).csv")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: demo (simulator) paths

    private func demoScan() {
        found.removeAll(); scanning = true; progress = 0
        job = Task {
            for step in 0...20 {
                progress = Double(step) / 20
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            // A plausible-looking wheel-speed DID: 4× uint16, plus decoys.
            found = [
                FoundDid(did: 0xF190, bytes: Array("WBA".utf8)),
                FoundDid(did: 0xD100, bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
                FoundDid(did: 0xDD05, bytes: [0x05, 0x10, 0x05, 0x12, 0x05, 0x40, 0x05, 0x44]),
            ]
            scanning = false
            status = "Demo — found \(found.count) DIDs"
        }
    }

    private func demoWatch(dids: [UInt16]) {
        job = Task {
            var t = 0.0
            while !Task.isCancelled {
                t += 0.04
                let mph = 30 + 25 * (1 + sin(t / 3))          // roll 30–80 mph
                gpsMph = mph
                let kmh = mph * kmhPerMph
                let rear = kmh * 1.04                          // rear wheels spin ~4% faster
                let raws: [(UInt16, Double)] = [
                    (0xDD05, kmh / 0.0625),                    // FL
                    (0xDD05, (kmh + 0.3) / 0.0625),            // FR
                    (0xDD05, rear / 0.0625),                   // RL
                    (0xDD05, (rear + 0.4) / 0.0625),           // RR
                ]
                for (i, (did, raw)) in raws.enumerated() where dids.contains(did) {
                    let key = String(format: "%04X.%d", did, i)
                    var s = stats[key] ?? ChannelStat(did: did, word: i)
                    s.add(raw: raw, gpsMph: mph)
                    stats[key] = s
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }
}
