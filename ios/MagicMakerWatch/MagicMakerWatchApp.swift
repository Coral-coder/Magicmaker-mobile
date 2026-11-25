import SwiftUI

// MagicMaker for Apple Watch (docs/WATCH_APP.md 5): a remote for the iPhone app. Three pages:
// FAVORITES (tap sends through the iPhone and its relay), STATUS (the cluster as the iPhone knows
// it) and STOP PROGRAMS.

@main
struct MagicMakerWatchApp: App {
    @StateObject private var model: WatchModel = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
        }
    }
}

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    @State private var page: Int = 0

    var body: some View {
        // Horizontal pages, not watchOS 10's vertical ones: a 24-row list inside a vertical pager
        // would have to be scrolled to its end to reach STATUS.
        TabView(selection: $page) {
            FavoritesPage()
                .containerBackground(Color.black, for: .tabView)
                .tag(0)
            StatusPage()
                .containerBackground(Color.black, for: .tabView)
                .tag(1)
            StopPage()
                .containerBackground(Color.black, for: .tabView)
                .tag(2)
        }
        .tabViewStyle(.page)
        .tint(WatchInk(model.theme).highlight)
        .onChange(of: scenePhase) { _, phase in
            model.setActive(phase == .active)
        }
        .task(id: page) {
            // STATUS and STOP stay fresh while shown; FAVORITES gets the iPhone's pushes.
            if page == 0 { return }
            while !Task.isCancelled {
                if model.active { await model.refresh() }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }
}
