import SwiftUI

@main
struct MagicMakerApp: App {
    init() {
        // First thing at launch, so a crash anywhere after this leaves a trail.
        CrashLog.install()
    }

    var body: some Scene {
        WindowGroup {
            LaunchBootstrapView()
        }
    }
}
