import SwiftUI

private enum MainTab: String, CaseIterable, Identifiable {
    case tx, wand, auto, lab, scan, link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tx: return "TX"
        case .wand: return "WAND"
        case .auto: return "AUTO"
        case .lab: return "LAB"
        case .scan: return "SCAN"
        case .link: return "LINK"
        }
    }

    var icon: String {
        switch self {
        case .tx: return "paperplane.fill"
        case .wand: return "sparkles"
        case .auto: return "bolt.circle"
        case .lab: return "flask"
        case .scan: return "dot.radiowaves.left.and.right"
        case .link: return "link"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @StateObject private var remoteUI = RemoteUIState()
    @State private var tab: MainTab = .tx

    var body: some View {
        VStack(spacing: 0) {
            TelemetryBar()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MMTheme.navy)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MMCompactTabBar(
                selection: $tab,
                tabs: MainTab.allCases,
                title: { $0.title },
                icon: { $0.icon }
            )
        }
        .environmentObject(remoteUI)
        .onAppear {
            if !vm.relayCommandReady {
                vm.reconnectRelay()
            }
            vm.refreshRelayStatus()
            vm.refreshAndroidCatalog()
            remoteUI.sync(from: vm)
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if !vm.relayCommandReady {
                vm.ensureRelayLink()
            }
            if !vm.isCatalogSyncInFlight {
                vm.refreshAndroidRemote()
            }
            vm.refreshRelayStatus()
            if vm.relayCommandReady,
               !vm.isCatalogSyncInFlight,
               vm.androidCatalog == nil || vm.androidCatalog?.transmitPresets.isEmpty == true {
                vm.refreshAndroidCatalog()
            }
        }
        .onChange(of: vm.relayCommandReady) { _, ready in
            if ready { vm.refreshAndroidCatalog() }
        }
        .onChange(of: vm.remoteLinkReady) { _, ready in
            if ready { vm.refreshAndroidCatalog() }
        }
        .onChange(of: vm.androidRemote?.storeRevision) { _, _ in
            vm.refreshAndroidCatalog()
            remoteUI.sync(from: vm)
        }
        .onChange(of: vm.androidCatalog?.wakeupPreambleMs) { _, ms in
            if let ms, !remoteUI.sliderDragging { remoteUI.preambleMs = Double(ms) }
        }
        .onChange(of: vm.androidCatalog?.commandBurstMs) { _, ms in
            if let ms, !remoteUI.sliderDragging { remoteUI.commandBurstMs = Double(ms) }
        }
        .onChange(of: vm.androidCatalog?.starlightBurstMs) { _, ms in
            if let ms, !remoteUI.sliderDragging { remoteUI.starlightBurstMs = Double(ms) }
        }
        .onChange(of: vm.androidRemote) { _, _ in
            if !remoteUI.sliderDragging { remoteUI.sync(from: vm) }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .tx: RemoteTxView()
        case .wand: RemoteWandView()
        case .auto: RemoteAutoView()
        case .lab: RemoteLabView()
        case .scan: RemoteScanTabView()
        case .link: RemoteLinkTabView()
        }
    }
}

@MainActor
final class RemoteUIState: ObservableObject {
    @Published var sliderDragging = false
    @Published var wandIntervalSec: Double = 3
    @Published var preambleMs: Double = 520
    @Published var commandBurstMs: Double = 2000
    @Published var starlightBurstMs: Double = 500
    @Published var selectedWandId: Int64 = -1
    @Published var selectedTxId: Int64 = -1
    @Published var txIntervalSec: Double = 3
    @Published var txSettingsExpanded = false
    @Published var txLoopSettingsExpanded = false
    @Published var collapsedTxSections: Set<LivePacketSection> = []
    @Published var collapsedScanSections: Set<LivePacketSection> = []
    @Published var collapsedLocalSections: Set<LivePacketSection> = []
    @Published var scanControlsExpanded = false

    func sync(from vm: AppViewModel) {
        if let s = vm.androidRemote {
            if s.starlightLoopPacketId >= 0 { selectedWandId = s.starlightLoopPacketId }
            wandIntervalSec = Double(s.starlightIntervalMs) / 1000.0
            if s.txLoopPacketId >= 0 { selectedTxId = s.txLoopPacketId }
            txIntervalSec = Double(s.txLoopIntervalMs) / 1000.0
            if !sliderDragging {
                preambleMs = Double(s.wakeupPreambleMs)
                commandBurstMs = Double(s.commandBurstMs)
                starlightBurstMs = Double(s.starlightBurstMs)
            }
        }
        if let cat = vm.androidCatalog, !sliderDragging {
            preambleMs = Double(cat.wakeupPreambleMs)
            commandBurstMs = Double(cat.commandBurstMs)
            starlightBurstMs = Double(cat.starlightBurstMs)
        }
    }

    func toggleTxSection(_ section: LivePacketSection) {
        if collapsedTxSections.contains(section) {
            collapsedTxSections.remove(section)
        } else {
            collapsedTxSections.insert(section)
        }
    }

    func toggleScanSection(_ section: LivePacketSection) {
        if collapsedScanSections.contains(section) {
            collapsedScanSections.remove(section)
        } else {
            collapsedScanSections.insert(section)
        }
    }

    func toggleLocalSection(_ section: LivePacketSection) {
        if collapsedLocalSections.contains(section) {
            collapsedLocalSections.remove(section)
        } else {
            collapsedLocalSections.insert(section)
        }
    }
}
