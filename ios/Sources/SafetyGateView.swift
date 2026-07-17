import SwiftUI

/// One-time safety acknowledgment shown before the app can be used. Framing
/// the app around closed-course use and requiring explicit agreement is both
/// the responsible thing and what App Review expects of a speed-timing app.
struct SafetyGateView: View {
    var onAccept: () -> Void

    private let points: [(String, String, String)] = [
        ("flag.checkered", "Closed course only",
         "Time runs on a track, closed course, or private property — never on public roads."),
        ("person.2.fill", "A passenger runs the app",
         "Never look at or tap your phone while driving. A passenger operates it."),
        ("checkmark.shield.fill", "Obey all laws",
         "Follow every traffic law and speed limit. You alone are responsible for safe, legal use."),
        ("gauge.with.dots.needle.bottom.50percent", "Times are estimates",
         "Results are for entertainment and may not be exact. Don't rely on them for anything critical."),
    ]

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 22) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.amber)
                            .padding(.top, 28)
                        Text("Drive responsibly")
                            .font(.system(size: 26, weight: .bold))
                        VStack(spacing: 16) {
                            ForEach(points, id: \.0) { p in
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: p.0)
                                        .font(.system(size: 20))
                                        .foregroundColor(.go)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(p.1).font(.system(size: 16, weight: .semibold))
                                        Text(p.2).font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                    }
                    .padding(.bottom, 16)
                }

                Button("I understand and agree") { onAccept() }
                    .font(.system(size: 18, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.go)
                    .foregroundColor(.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                Text("By continuing you accept these terms and assume all risk.")
                    .font(.system(size: 11))
                    .foregroundColor(.dim)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
            }
        }
    }
}
