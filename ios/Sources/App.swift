import SwiftUI

@main
struct M240iTrackerApp: App {
    @StateObject private var engine = Engine()
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .onAppear { if hasOnboarded { engine.gps.start() } }
                .fullScreenCover(isPresented: Binding(
                    get: { !hasOnboarded },
                    set: { presented in if !presented { hasOnboarded = true } }
                )) {
                    OnboardingView {
                        hasOnboarded = true
                        engine.gps.start()   // request Location in context, on the final page
                    }
                    .preferredColorScheme(.dark)
                }
        }
    }
}
