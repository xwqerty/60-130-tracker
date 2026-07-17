import SwiftUI

@main
struct M240iTrackerApp: App {
    @StateObject private var engine = Engine()
    @AppStorage("acceptedSafety") private var acceptedSafety = false
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !acceptedSafety {
                    SafetyGateView { acceptedSafety = true }
                } else if !hasOnboarded {
                    OnboardingView(engine: engine) { mode in
                        engine.connMode = mode   // GPS / demo / adapter — the user's pick
                        engine.gps.start()
                        engine.start()           // reconnect using the chosen mode
                        hasOnboarded = true
                    }
                } else {
                    ContentView()
                        .environmentObject(engine)
                        .onAppear { engine.gps.start(); engine.start() }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
