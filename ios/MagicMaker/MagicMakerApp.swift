import SwiftUI

@main
struct MagicMakerApp: App {
    init() {
        // First thing at launch, so a crash anywhere after this leaves a trail.
        CrashLog.install()
        // A VFD launch that crashed before settling starts in the standard theme instead.
        VFDSettings.shared.armLaunchGuard()
    }

    var body: some Scene {
        WindowGroup {
            LaunchBootstrapView()
        }
    }
}
