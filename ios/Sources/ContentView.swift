import SwiftUI

extension Color {
    static let bg = Color(red: 0.051, green: 0.051, blue: 0.059)
    static let card = Color(red: 0.09, green: 0.09, blue: 0.106)
    static let cardBorder = Color(red: 0.137, green: 0.137, blue: 0.16)
    static let dim = Color(red: 0.33, green: 0.33, blue: 0.35)
    static let go = Color(red: 0.18, green: 0.8, blue: 0.443)
    static let stop = Color(red: 0.906, green: 0.298, blue: 0.235)
    static let amber = Color(red: 0.902, green: 0.658, blue: 0.09)
}

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @State private var selectedRange = SpeedRange.all[0]
    @State private var showSettings = false

    private var active: Bool { engine.phase == .armed || engine.phase == .recording }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    StatusPill(phase: engine.phase, detail: engine.detail)
                        .padding(.bottom, 18)
                    speedometer
                    runZone
                    if !active { rangePicker.padding(.bottom, 14) }
                    goButton
                    resultsList
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.phase)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(engine) }
    }

    private var header: some View {
        HStack {
            Spacer().frame(width: 28)
            Spacer()
            Text("60–130 TRACKER")
                .font(.system(size: 13, weight: .semibold))
                .tracking(5)
                .foregroundColor(.dim)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.dim)
            }
            .frame(width: 28)
        }
        .padding(.vertical, 14)
    }

    private var speedometer: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.1f", engine.mph))
                .font(.system(size: 88, weight: .heavy, design: .rounded))
                .monospacedDigit()
            Text("MPH")
                .font(.system(size: 12, weight: .semibold))
                .tracking(6)
                .foregroundColor(.dim)
        }
        .padding(.bottom, 16)
    }

    private var runZone: some View {
        VStack(spacing: 10) {
            Text(engine.elapsed.map { String(format: "+%.2f s", $0) } ?? " ")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.stop)
                .opacity(engine.elapsed == nil ? 0 : 1)

            if let range = engine.armedRange {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.card)
                        Capsule().fill(Color.stop)
                            .frame(width: geo.size.width * progress(in: range))
                            .animation(.linear(duration: 0.15), value: engine.mph)
                    }
                }
                .frame(height: 7)
                HStack {
                    Text("\(Int(range.start))")
                    Spacer()
                    Text("\(Int(range.end))")
                }
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.dim)
            }
        }
        .frame(minHeight: 84)
        .padding(.bottom, 6)
    }

    private func progress(in range: SpeedRange) -> CGFloat {
        let p = (engine.mph - range.start) / (range.end - range.start)
        return CGFloat(min(max(p, 0), 1))
    }

    private var rangePicker: some View {
        HStack(spacing: 4) {
            ForEach(SpeedRange.all) { range in
                Button {
                    selectedRange = range
                } label: {
                    Text(range.key)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selectedRange == range ? Color.cardBorder : .clear)
                        .foregroundColor(selectedRange == range ? .white : Color(white: 0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(4)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var goButton: some View {
        Button {
            if active { engine.cancel() } else { engine.arm(selectedRange) }
        } label: {
            Text(active ? "CANCEL" : "START LOG")
                .font(.system(size: 22, weight: .heavy))
                .tracking(2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(engine.phase == .searching ? Color.card : (active ? Color.stop : Color.go))
                .foregroundColor(engine.phase == .searching ? .dim : .black.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .disabled(engine.phase == .searching)
    }

    private var resultsList: some View {
        let bests = Dictionary(grouping: engine.results.filter(\.complete), by: \.range)
            .compactMapValues { rs in rs.count > 1 ? rs.compactMap(\.total).min() : nil }
        return VStack(spacing: 10) {
            ForEach(engine.results) { r in
                ResultCard(result: r, isBest: r.complete && r.total != nil && r.total == bests[r.range])
            }
        }
        .padding(.top, 24)
    }
}

struct StatusPill: View {
    let phase: Phase
    let detail: String
    @State private var pulse = false

    private var color: Color {
        switch phase {
        case .searching: return .amber
        case .ready: return .go
        case .armed, .recording: return .stop
        }
    }

    private var text: String {
        switch phase {
        case .searching: return "Searching for MHD adapter…"
        case .ready: return "Connected — ready to log"
        case .armed: return "Armed — waiting for start speed"
        case .recording: return "Recording…"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                    .opacity(pulse && (phase == .searching || phase == .recording) ? 0.25 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(), value: pulse)
                Text(text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(color)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            Text(detail.isEmpty ? " " : detail)
                .font(.system(size: 11, weight: .medium))
                .tracking(1)
                .foregroundColor(.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .onAppear { pulse = true }
    }
}

struct ResultCard: View {
    let result: RunResult
    let isBest: Bool

    private var subtitle: String {
        var bits: [String] = []
        if let v = result.split1 { bits.append("\(result.splitLabels[0]) \(String(format: "%.2f", v))s") }
        if let v = result.split2 { bits.append("\(result.splitLabels[1]) \(String(format: "%.2f", v))s") }
        bits.append("vmax \(String(format: "%.1f", result.vmaxMph))")
        bits.append(result.when.formatted(date: .omitted, time: .standard))
        return bits.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                if result.complete, let total = result.total {
                    Text("\(result.range) · \(String(format: "%.2f", total)) s")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text("\(result.range) · lifted early")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.amber)
                }
                if isBest {
                    Text("BEST")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundColor(.go)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.go.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            Text(subtitle)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundColor(Color(white: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.card)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Connection") {
                    TextField("Adapter IP (blank = auto)", text: engine.$customHost)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    Toggle("Demo mode (simulated car)", isOn: engine.$demoMode)
                }
                Section {
                    Button("Clear results", role: .destructive) { engine.clearResults() }
                } footer: {
                    Text("Run CSVs are saved to On My iPhone › 60-130 › logs, "
                         + "openable from the Files app.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") {
                    dismiss()
                    engine.start()   // reconnect with new settings
                }
            }
        }
    }
}
