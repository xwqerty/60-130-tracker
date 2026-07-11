import SwiftUI

struct OnboardingView: View {
    @ObservedObject var engine: Engine
    /// The connection mode the user chose to start with.
    var onFinish: (_ mode: ConnectionMode) -> Void
    @State private var page = 0

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    valuePage.tag(0)
                    accuracyPage.tag(1)
                    tryPage.tag(2)
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .onChange(of: page) { p in
                    if p >= 1 { engine.gps.start() }   // request Location in context, on the accuracy page
                }

                controls
            }
        }
    }

    // MARK: pages

    private var valuePage: some View {
        pageChrome(icon: "stopwatch", title: "Your times, in your pocket") {
            Text("Time 0–60, 60–130, or any range you set — with accuracy you can "
                 + "actually trust, right from your phone.")
                .modifier(BodyText())
        }
    }

    private var accuracyPage: some View {
        pageChrome(icon: "scope", title: "Accurate — and it proves it") {
            VStack(spacing: 18) {
                Text("The app locks onto GPS and continuously corrects for real-world "
                     + "conditions — no spinner, no guessing. You can watch it work:")
                    .modifier(BodyText())
                AccuracyReadout(gps: engine.gps)
                Text("Want the sharpest, highest-rate numbers? Serious users add an OBD "
                     + "adapter — but you don't need one to start.")
                    .font(.system(size: 13))
                    .foregroundColor(.dim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 4)
            }
        }
    }

    private var tryPage: some View {
        pageChrome(icon: "play.circle", title: "Start timing — right now") {
            Text("Begin with just your phone's GPS. Add an adapter later for the "
                 + "sharpest numbers — you can switch anytime in Settings.")
                .modifier(BodyText())
        }
    }

    // MARK: chrome

    private var controls: some View {
        VStack(spacing: 12) {
            if page < 2 {
                Button("Next") { withAnimation { page += 1 } }
                    .buttonStyle(PrimaryButton())
            } else {
                Button("Start with my phone") { onFinish(.gps) }
                    .buttonStyle(PrimaryButton())
                HStack(spacing: 20) {
                    Button("Try a demo") { onFinish(.demo) }
                    Button("I have an adapter") { onFinish(.bmw) }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.dim)
            }

            Text("Behind the scenes your speed is cross-checked against GPS and "
                 + "fine-tuned in real time, keeping every run locked to true ground "
                 + "speed — the same GPS-referenced approach the best performance "
                 + "meters are built on.")
                .font(.system(size: 11))
                .foregroundColor(.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
    }

    private func pageChrome<Content: View>(icon: String, title: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 52, weight: .light))
                .foregroundColor(.go)
            Text(title)
                .font(.system(size: 25, weight: .bold))
                .multilineTextAlignment(.center)
            content()
            Spacer()
            Spacer()
        }
    }
}

private struct BodyText: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 16))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.horizontal, 32)
    }
}

private struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.go)
            .foregroundColor(.black.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Live, honest GPS accuracy chip — shows the real speed-accuracy figure as it
/// resolves, so the app visibly proves it's working rather than spinning.
struct AccuracyReadout: View {
    @ObservedObject var gps: GpsSpeed

    var body: some View {
        HStack(spacing: 10) {
            if !gps.authorized {
                Image(systemName: "location.slash").foregroundColor(.dim)
                Text("Allow Location to calibrate").foregroundColor(.dim)
            } else if let acc = gps.accuracyMph {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.go)
                Text(String(format: "GPS accuracy ±%.1f mph", acc))
                    .foregroundColor(.go)
                    .monospacedDigit()
            } else {
                ProgressView().tint(.dim)
                Text("Acquiring GPS…").foregroundColor(.dim)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.card)
        .clipShape(Capsule())
    }
}
