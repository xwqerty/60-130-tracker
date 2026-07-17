#if DEBUG
import SwiftUI

struct DidScannerView: View {
    @ObservedObject var scanner: DidScanner
    @State private var selected: Set<UInt16> = []
    @State private var targetHex = "29"
    @State private var share: ShareBundle?

    var body: some View {
        Form {
            connectionSection
            if scanner.connected {
                if !scanner.watching { enumerationSection }
                if !scanner.found.isEmpty { resultsSection }
                if scanner.watching || !scanner.stats.isEmpty { watchSection }
            }
            helpSection
        }
        .navigationTitle("Wheel-speed finder")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { scanner.disconnect() }
        .sheet(item: $share) { bundle in ShareSheet(items: bundle.urls) }
    }

    // MARK: sections

    private var connectionSection: some View {
        Section {
            HStack {
                Text("Target ECU")
                Spacer()
                Text("0x").foregroundColor(.secondary)
                TextField("29", text: $targetHex)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .onChange(of: targetHex) { new in
                        if let v = UInt8(new, radix: 16) { scanner.target = v }
                    }
            }
            HStack {
                ForEach(DidScanner.Preset.allCases) { p in
                    Button(p.rawValue) {
                        scanner.target = p.addr
                        targetHex = String(p.addr, radix: 16)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
            if scanner.connected {
                Button("Disconnect", role: .destructive) { scanner.disconnect(); selected.removeAll() }
            } else {
                Button("Connect to ECU") { Task { await scanner.connect() } }
            }
            Text(scanner.status).font(.footnote).foregroundColor(.secondary)
        } header: {
            Text("Connection")
        } footer: {
            Text("Timing is paused while the finder holds the diagnostic session. "
                 + "The finder only reads data — it never changes the module's mode. "
                 + "If warning lights ever appear, stop, and cycle the ignition; "
                 + "they clear once the car sleeps.")
        }
    }

    private var enumerationSection: some View {
        Section("Find DIDs") {
            if scanner.scanning {
                ProgressView(value: scanner.progress)
                Text("Scanning… \(scanner.found.count) found")
                    .font(.footnote).foregroundColor(.secondary)
                Button("Stop", role: .destructive) { scanner.stopScan() }
            } else {
                Button("Scan for responding DIDs") { scanner.scan() }
                Text("Do this parked. Enumerates every DID the ECU answers "
                     + "(~1–2 min for the full range).")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    private var resultsSection: some View {
        Section {
            ForEach(scanner.found) { f in
                Button {
                    if selected.contains(f.did) { selected.remove(f.did) } else { selected.insert(f.did) }
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: selected.contains(f.did) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selected.contains(f.did) ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "0x%04X · %d bytes", f.did, f.bytes.count))
                                .font(.system(.body, design: .monospaced))
                            Text(f.hex).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            if f.words.count >= 2 {
                                Text("words: " + f.words.map(String.init).joined(separator: " "))
                                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("\(scanner.found.count) responding")
                Spacer()
                Button(selected.isEmpty ? "Watch 4×uint16 DIDs" : "Watch \(selected.count)") {
                    if selected.isEmpty {
                        selected = Set(scanner.found.filter { $0.bytes.count >= 8 }.map(\.did))
                    }
                    scanner.startWatch(dids: Array(selected))
                }
                .disabled(scanner.found.isEmpty)
            }
        } footer: {
            Text("Wheel speeds are usually four 16-bit values (8 bytes). "
                 + "Select likely DIDs, then drive to see which track your speed.")
        }
    }

    private var spreadColor: Color {
        scanner.speedSpread >= 20 ? .green : (scanner.speedSpread >= 10 ? .orange : .red)
    }

    private var watchSection: some View {
        Section {
            HStack {
                Text("ECU reads").foregroundColor(.secondary)
                Spacer()
                Circle().fill(scanner.readsLive ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(scanner.readsLive ? "live" : "stopped")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(scanner.readsLive ? .green : .red)
            }
            if let note = scanner.dropoutNote {
                Text(note).font(.footnote).foregroundColor(.red)
            }
            HStack {
                Text("GPS speed").foregroundColor(.secondary)
                Spacer()
                Text(scanner.gpsMph.map { String(format: "%.1f mph", $0) } ?? "no fix")
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("Speed spread").foregroundColor(.secondary)
                Spacer()
                Text("\(Int(scanner.speedSpread)) mph")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(spreadColor)
                Text(scanner.speedSpread >= 20 ? "enough" : "keep sweeping")
                    .font(.footnote)
                    .foregroundColor(spreadColor)
            }
            ForEach(scanner.rankedChannels) { s in
                HStack {
                    Text(String(format: "0x%04X w%d", s.did, s.word))
                        .font(.system(.footnote, design: .monospaced))
                    Spacer()
                    Text(String(format: "r=%.3f", s.correlation))
                        .foregroundColor(s.correlation > 0.98 ? .green : .secondary)
                        .font(.system(.footnote, design: .monospaced))
                    Text(String(format: "→ %.1f mph", s.predictedMph))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(width: 90, alignment: .trailing)
                }
            }
        } header: {
            HStack {
                Text("Live — channels vs GPS")
                Spacer()
                if scanner.watching {
                    Button("Stop") { scanner.stopWatch() }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sweep your speed up and down (e.g. 15 ↔ 50 mph) until the "
                     + "spread shows green — correlations mean nothing at constant "
                     + "speed. Then one firm pull: the four channels at r≈1.000 are "
                     + "wheels, and the pair reading lower under power are the "
                     + "fronts. A brief stationary wheelspin also helps — in the "
                     + "saved time-series log the rears move while fronts and GPS "
                     + "stay at zero.")
                Text("Every sample is auto-saved to a time-series CSV, including "
                     + "below-5-mph data the live ranking ignores.")
                Button("Export findings + time-series log") {
                    var urls: [URL] = []
                    if let f = scanner.exportFindings() { urls.append(f) }
                    if let w = scanner.exportWatchLog() { urls.append(w) }
                    if !urls.isEmpty { share = ShareBundle(urls: urls) }
                }
            }
        }
    }

    private var helpSection: some View {
        Section {
            Text("This finds the DSC module's wheel-speed identifiers so runs "
                 + "can be timed on front-wheel speed (immune to rear wheelspin). "
                 + "Once we know the DID and channel offsets, they get wired in "
                 + "as a speed source.")
                .font(.footnote).foregroundColor(.secondary)
        }
    }
}

struct ShareBundle: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.absoluteString).joined() }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#endif
