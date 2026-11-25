import SwiftUI

@MainActor
final class BootstrapController: ObservableObject {
    /// One per process: the launch view shows it, and the watch bridge starts it when a watch
    /// message wakes the app in the background with no screen (docs/WATCH_APP.md 4.1).
    static let shared: BootstrapController = BootstrapController()

    @Published private(set) var viewModel: AppViewModel?

    /// Builds the app's engines once; later calls return the same model.
    @discardableResult
    func start() -> AppViewModel {
        if let existing = viewModel { return existing }
        let vm = AppViewModel()
        vm.bootstrapAfterLaunch()
        viewModel = vm
        WatchBridge.shared.attach(vm)
        return vm
    }
}

/// Shows a blank shell first, then constructs AppViewModel off the critical launch path. When a
/// watch message already built it (a background wake), ContentView shows at once.
struct LaunchBootstrapView: View {
    @StateObject private var bootstrap: BootstrapController = BootstrapController.shared

    var body: some View {
        Group {
            if let viewModel = bootstrap.viewModel {
                ContentView()
                    .environmentObject(viewModel)
                    .environmentObject(viewModel.store)
                    .environmentObject(viewModel.scan)
                    .environmentObject(viewModel.tx)
            } else {
                ZStack {
                    MMTheme.navy.ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(MMTheme.cyan)
                        Text("MagicMaker")
                            .font(MMTheme.techLabel())
                            .foregroundStyle(MMTheme.textDim)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(MMTheme.cyan)
        .task {
            _ = bootstrap.start()
        }
    }
}
