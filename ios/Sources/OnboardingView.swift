import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let body: String
    }

    private let pages = [
        Page(icon: "stopwatch",
             title: "Times you can trust",
             body: "Measure 60–130 — or any range you choose — as accurately as a "
                 + "dedicated GPS performance meter, straight from the car you're driving."),
        Page(icon: "antenna.radiowaves.left.and.right",
             title: "Your car and GPS, together",
             body: "The MHD adapter streams speed from your ECU dozens of times a "
                 + "second — fast enough to catch the exact instant you cross a "
                 + "threshold. GPS then continuously calibrates that signal to true "
                 + "ground speed, correcting for your exact tires and setup instead "
                 + "of trusting a factory estimate."),
        Page(icon: "checkmark.seal",
             title: "Set it and drive",
             body: "Calibration runs automatically in the background — there's nothing "
                 + "to configure. Join your adapter's Wi-Fi, allow Location so GPS can "
                 + "do its job, then press START LOG and go."),
    ]

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        pageView(pages[i]).tag(i)
                    }
                }
                .tabViewStyle(.page)
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button(page < pages.count - 1 ? "Next" : "Start driving") {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                }
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.go)
                .foregroundColor(.black.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)

                Text("Behind the scenes your speed is cross-checked against GPS and "
                     + "fine-tuned in real time, keeping every run locked to true "
                     + "ground speed — the same GPS-referenced approach the best "
                     + "performance meters are built on.")
                    .font(.system(size: 11))
                    .foregroundColor(.dim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
        }
    }

    private func pageView(_ p: Page) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: p.icon)
                .font(.system(size: 54, weight: .light))
                .foregroundColor(.go)
            Text(p.title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
            Text(p.body)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}
