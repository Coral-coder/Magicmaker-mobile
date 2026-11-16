import SwiftUI

@MainActor
final class BootstrapController: ObservableObject {
    @Published private(set) var viewModel: AppViewModel?

    func start() {
        guard viewModel == nil else { return }
        let vm = AppViewModel()
        vm.bootstrapAfterLaunch()
        viewModel = vm
    }
}

/// Shows a blank shell first, then constructs AppViewModel off the critical launch path.
struct LaunchBootstrapView: View {
    @StateObject private var bootstrap = BootstrapController()

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
            bootstrap.start()
        }
    }
}
