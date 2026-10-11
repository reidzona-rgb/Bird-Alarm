import SwiftUI

@main
struct BirdsongAlarmApp: App {
    @StateObject private var store = AlarmStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

/// Swaps between the setup state and the Active Alarm Display.
struct RootView: View {
    @EnvironmentObject private var store: AlarmStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let bird = store.activeBird {
                WakingView(bird: bird)
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: store.activeBird)
        .onChange(of: scenePhase) { phase in
            if phase == .active { store.appBecameActive() }
        }
    }
}

extension Color {
    /// High-contrast accent used on the waking screen.
    static let dawnYellow = Color(red: 1.0, green: 0.84, blue: 0.04)
    static let cardGray = Color(white: 0.13)
}
