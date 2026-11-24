import Combine
import SwiftUI

/// The ten tabs, in Android's order (`AppTab` in `MagicMakerScreens.kt`). LINK is the iPhone side
/// of Android's RELAY tab. The raw values are the ids `AppViewModel.requestedTab` uses
/// (`AppViewModel.labTabId` is "lab"). Shared with the VFD theme, whose tab bar uses the same keys.
enum MainTab: String, CaseIterable, Identifiable {
    case scan, tx, wand, auto, link, logs, map, diag, lab, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "SCAN"
        case .tx: return "TX"
        case .wand: return "WAND"
        case .auto: return "AUTO"
        case .link: return "LINK"
        case .logs: return "LOGS"
        case .map: return "MAP"
        case .diag: return "DIAG"
        case .lab: return "LAB"
        case .settings: return "SETTINGS"
        }
    }

    var icon: String {
        switch self {
        case .scan: return "dot.radiowaves.left.and.right"
        case .tx: return "paperplane.fill"
        case .wand: return "sparkles"
        case .auto: return "bolt.circle"
        case .link: return "link"
        case .logs: return "clock.arrow.circlepath"
        case .map: return "mappin.and.ellipse"
        case .diag: return "waveform.path.ecg"
        case .lab: return "flask"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    /// The theme: the standard screens below, or the VFD display.
    @ObservedObject private var vfdSettings: VFDSettings = VFDSettings.shared
    /// Opens like Android, on SCAN. Both themes show and change this tab.
    @State private var tab: MainTab = .scan

    /// The relay link and status poll. Kept here, not built in `body`, so a redraw does not
    /// start the 2 s wait again.
    private let relayPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            themedContent
        }
        .onAppear {
            startRelayLink()
            followRequestedTab(vm.requestedTab)
        }
        .onReceive(relayPoll) { _ in
            pollRelay()
        }
        .onChange(of: vm.relayCommandReady) { _, ready in
            if ready { vm.refreshAndroidCatalog() }
        }
        .onChange(of: vm.remoteLinkReady) { _, ready in
            if ready { vm.refreshAndroidCatalog() }
        }
        .onChange(of: vm.androidRemote?.storeRevision) { _, _ in
            vm.refreshAndroidCatalog()
        }
        .onChange(of: vm.requestedTab) { _, requested in
            followRequestedTab(requested)
        }
    }

    /// Only the content changes with the theme; the relay poll and the hooks above stay.
    @ViewBuilder
    private var themedContent: some View {
        if vfdSettings.theme == .vfd {
            VFDRootView(tab: $tab)
                .preferredColorScheme(.dark)
        } else {
            standardContent
        }
    }

    private var standardContent: some View {
        VStack(spacing: 0) {
            TelemetryBar()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MMTheme.navy)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MMScrollTabBar(
                selection: $tab,
                tabs: MainTab.allCases,
                title: { $0.title },
                icon: { $0.icon }
            )
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .scan: ScanScreen()
        case .tx: TxScreen()
        case .wand: WandScreen()
        case .auto: AutoScreen()
        case .link: LinkScreen()
        case .logs: LogsScreen()
        case .map: MapScreen()
        case .diag: DiagScreen()
        case .lab: LabScreen()
        case .settings: SettingsScreen()
        }
    }

    private func startRelayLink() {
        if !vm.relayCommandReady {
            vm.reconnectRelay()
        }
        vm.refreshRelayStatus()
        vm.refreshAndroidCatalog()
    }

    /// Every 2 s: keep the relay link up and read its status. On the WiFi relay the link state
    /// itself (`remoteLinkReady`) comes from this status read. "Keep running in background"
    /// follows the work this iPhone runs (its own loops, the show, replays) from here too.
    private func pollRelay() {
        if !vm.relayCommandReady {
            vm.ensureRelayLink()
        }
        if !vm.isCatalogSyncInFlight {
            vm.refreshAndroidRemote()
        }
        vm.refreshRelayStatus()
        if vm.relayCommandReady, !vm.isCatalogSyncInFlight, catalogMissing {
            vm.refreshAndroidCatalog()
        }
        vm.updateBackgroundKeepAlive()
    }

    private var catalogMissing: Bool {
        guard let catalog = vm.androidCatalog else { return true }
        return catalog.transmitPresets.isEmpty
    }

    /// Another screen asked for a tab (Load in Lab asks for the Lab): show it, then clear the ask.
    private func followRequestedTab(_ requested: String?) {
        guard let requested else { return }
        if let wanted = MainTab(rawValue: requested) {
            tab = wanted
        }
        vm.requestedTab = nil
    }
}
