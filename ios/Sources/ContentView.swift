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
    @State private var startMph: Double = 60
    @State private var endMph: Double = 130
    @State private var showSettings = false

    private var active: Bool { engine.phase == .armed || engine.phase == .recording }

    private var selectedRange: SpeedRange {
        SpeedRange(key: "\(Int(startMph))–\(Int(endMph))", start: startMph, end: endMph)
    }

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
                    if !active {
                        customRange.padding(.bottom, 14)
                        rangePicker.padding(.bottom, 14)
                    }
                    goButton
                    resultsList
                    footnote
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
            if engine.calibrated {
                Text(String(format: "GPS-calibrated %+.1f%%", (engine.speedFactor - 1) * 100))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.go.opacity(0.7))
                    .padding(.top, 2)
            }
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

    private var customRange: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("\(Int(startMph))–\(Int(endMph))")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("MPH")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2)
                    .foregroundColor(.dim)
            }
            RangeSlider(start: $startMph, end: $endMph)
            HStack {
                Text("0")
                Spacer()
                Text("drag both ends to set any range")
                Spacer()
                Text("160")
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundColor(.dim)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 4) {
            ForEach(SpeedRange.all) { range in
                let isSelected = startMph == range.start && endMph == range.end
                Button {
                    startMph = range.start
                    endMph = range.end
                } label: {
                    Text(range.key)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(isSelected ? Color.cardBorder : .clear)
                        .foregroundColor(isSelected ? .white : Color(white: 0.55))
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

    private var footnote: some View {
        VStack(spacing: 8) {
            GpsAccuracyChip(gps: engine.gps)
            Text(engine.calibrated
                 ? "Continuously GPS-calibrated in real time — every run stays locked to true ground speed."
                 : "Speed is cross-checked against GPS and fine-tuned in real time for true-ground-speed accuracy.")
                .font(.system(size: 11))
                .foregroundColor(.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 24)
        }
        .padding(.top, 28)
        .padding(.bottom, 8)
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

/// Dual-handle slider: drag either end of the line to set the run's start
/// and end speeds (0-160 mph, 5 mph steps, minimum 10 mph window).
struct RangeSlider: View {
    @Binding var start: Double
    @Binding var end: Double
    var bounds: ClosedRange<Double> = 0...160
    var step: Double = 5
    var minGap: Double = 10

    private let handleSize: CGFloat = 26
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - handleSize
            let startX = position(of: start, usable: usable)
            let endX = position(of: end, usable: usable)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.card)
                    .frame(height: trackHeight)
                    .padding(.horizontal, handleSize / 2 - 2)
                Capsule()
                    .fill(Color.go)
                    .frame(width: max(endX - startX, trackHeight), height: trackHeight)
                    .offset(x: startX + handleSize / 2)
                handle(atX: startX, label: Int(start)) { x in
                    start = snapped(value(atX: x, usable: usable),
                                    low: bounds.lowerBound, high: end - minGap)
                }
                handle(atX: endX, label: Int(end)) { x in
                    end = snapped(value(atX: x, usable: usable),
                                  low: start + minGap, high: bounds.upperBound)
                }
            }
            .coordinateSpace(name: "rangeslider")
        }
        .frame(height: handleSize + 4)
    }

    private func position(of v: Double, usable: CGFloat) -> CGFloat {
        CGFloat((v - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)) * usable
    }

    private func value(atX x: CGFloat, usable: CGFloat) -> Double {
        Double(x / max(usable, 1)) * (bounds.upperBound - bounds.lowerBound) + bounds.lowerBound
    }

    private func snapped(_ v: Double, low: Double, high: Double) -> Double {
        min(max((v / step).rounded() * step, low), high)
    }

    private func handle(atX x: CGFloat, label: Int,
                        onDrag: @escaping (CGFloat) -> Void) -> some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Text("\(label)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.black)
                .minimumScaleFactor(0.7)
        }
        .frame(width: handleSize, height: handleSize)
        .offset(x: x)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("rangeslider"))
                .onChanged { drag in onDrag(drag.location.x - handleSize / 2) }
        )
    }
}

/// Small live GPS accuracy line on the main screen — a quiet legitimacy signal.
struct GpsAccuracyChip: View {
    @ObservedObject var gps: GpsSpeed

    var body: some View {
        if gps.authorized, let acc = gps.accuracyMph {
            HStack(spacing: 6) {
                Image(systemName: "location.fill").font(.system(size: 10))
                Text(String(format: "GPS locked · ±%.1f mph", acc)).monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(gps.accuracyOK ? .go : .dim)
        }
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
        case .searching: return "Connecting…"
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

struct GpsCalRows: View {
    @ObservedObject var gps: GpsSpeed
    @ObservedObject var engine: Engine

    var body: some View {
        HStack {
            Text("Correction")
            Spacer()
            Text(engine.speedFactorSamples == 0
                 ? "—"
                 : String(format: "%+.2f%% · %d fixes", (engine.speedFactor - 1) * 100,
                          engine.speedFactorSamples))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        HStack {
            Text("GPS speed now")
            Spacer()
            Text(!gps.authorized ? "no permission"
                 : gps.mph.map { String(format: "%.1f mph", $0) } ?? "no fix")
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    private var sourceFooter: String {
        switch engine.connMode {
        case .bmw: "Reads high-rate speed from the ECU via the MHD/ENET adapter — "
            + "the most precise mode. Join the adapter's Wi-Fi."
        case .obd: "Works on any 2008+ car with a Wi-Fi ELM327 adapter. Join the "
            + "adapter's Wi-Fi; its default IP is 192.168.0.10."
        case .gps: "Uses your phone's GPS — no adapter, works in any car. Lower "
            + "sample rate than an adapter, so timing is a little coarser."
        case .demo: "A simulated car for trying the app out. No hardware needed."
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Speed source", selection: Binding(
                        get: { engine.connMode },
                        set: { engine.connMode = $0; engine.start() })) {
                        ForEach(ConnectionMode.allCases) { m in Text(m.label).tag(m) }
                    }
                    if engine.connMode == .bmw {
                        TextField("BMW adapter IP (blank = auto)", text: engine.$customHost)
                            .keyboardType(.decimalPad).autocorrectionDisabled()
                    }
                    if engine.connMode == .obd {
                        TextField("OBD adapter IP", text: engine.$obdHost)
                            .keyboardType(.decimalPad).autocorrectionDisabled()
                    }
                } header: {
                    Text("Speed source")
                } footer: {
                    Text(sourceFooter)
                }
                if engine.connMode.isECU {
                    Section {
                        Toggle("GPS speed calibration", isOn: engine.$gpsCalEnabled)
                        GpsCalRows(gps: engine.gps, engine: engine)
                        Button("Reset calibration") { engine.resetCalibration() }
                    } header: {
                        Text("GPS calibration")
                    } footer: {
                        Text("Compares GPS speed to the car's reported speed while you "
                             + "cruise and corrects for tire size. Drive steadily above "
                             + "30 mph for ~30 seconds to calibrate; the factor is "
                             + "remembered between drives.")
                    }
                }
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About & how accuracy works", systemImage: "info.circle")
                    }
                }
                if engine.connMode == .bmw {
                    Section("Advanced") {
                        NavigationLink {
                            DidScannerView(scanner: engine.scanner)
                        } label: {
                            Label("Wheel-speed finder", systemImage: "scope")
                        }
                    }
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

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                block(title: "Why I built this",
                      body: "I'm an enthusiast, not a big company. I wanted a dead-simple "
                          + "way to see real roll-on times — 60–130 and anything else — "
                          + "without a $250 box or a subscription, using the phone that's "
                          + "already in the car. So I built it, use it on my own car, and "
                          + "keep improving it. If it helps you chase a number, that's the "
                          + "whole point.")

                block(title: "How the accuracy works",
                      body: "Two signals, each covering the other's weakness:\n\n"
                          + "• Speed — from the car's ECU (via an adapter) or your phone's "
                          + "GPS. The ECU feed is fast (dozens of samples a second), which "
                          + "is what catches the exact instant you cross a threshold.\n\n"
                          + "• GPS truth — GPS speed is absolutely accurate but updates "
                          + "about once a second. The app continuously compares it to the "
                          + "car's reading and corrects for tire size and speedo error, so "
                          + "the fast signal stays locked to true ground speed.\n\n"
                          + "Threshold crossings (60, 100, 130…) are interpolated between "
                          + "samples, so timing resolution is finer than the raw sample "
                          + "rate. It's the same GPS-referenced principle dedicated "
                          + "performance meters use.")

                block(title: "How accurate is it, really?",
                      body: "With an adapter + GPS calibration, times land within a few "
                          + "hundredths of true. Phone-GPS-only mode is rougher (GPS is "
                          + "~1 Hz) — great for a quick read, but the adapter is the "
                          + "precision upgrade. Every run is saved as a full CSV trace you "
                          + "can inspect yourself — no black box.")
            }
            .padding(20)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func block(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 18, weight: .bold))
            Text(body)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
