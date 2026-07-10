import SwiftUI

struct DidScannerView: View {
    @ObservedObject var scanner: DidScanner
    @State private var selected: Set<UInt16> = []
    @State private var targetHex = "29"
    @State private var shareURL: IdentifiableURL?

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
        .sheet(item: $shareURL) { wrap in ShareSheet(items: [wrap.url]) }
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

    private var watchSection: some View {
        Section {
            HStack {
                Text("GPS speed").foregroundColor(.secondary)
                Spacer()
                Text(scanner.gpsMph.map { String(format: "%.1f mph", $0) } ?? "no fix")
                    .font(.system(.body, design: .monospaced))
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
                Text("Drive above ~10 mph. The four channels with r≈1.000 and "
                     + "matching mph are your wheel speeds; the pair reading "
                     + "lower under acceleration are the fronts.")
                Button("Export findings (CSV)") {
                    if let url = scanner.exportFindings() { shareURL = IdentifiableURL(url: url) }
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

struct IdentifiableURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
