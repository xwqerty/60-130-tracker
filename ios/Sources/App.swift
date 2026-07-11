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
                    OnboardingView(engine: engine) { mode in
                        engine.connMode = mode   // GPS / demo / adapter — the user's pick
                        engine.gps.start()
                        engine.start()           // reconnect using the chosen mode
                        hasOnboarded = true
                    }
                    .preferredColorScheme(.dark)
                }
        }
    }
}
