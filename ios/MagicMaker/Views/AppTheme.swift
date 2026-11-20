import SwiftUI

enum MMTheme {
    static let navy = Color(red: 6 / 255, green: 13 / 255, blue: 24 / 255)
    static let panel = Color(red: 12 / 255, green: 30 / 255, blue: 54 / 255)
    static let panelLine = Color(red: 30 / 255, green: 58 / 255, blue: 95 / 255)
    static let cyan = Color(red: 92 / 255, green: 225 / 255, blue: 230 / 255)
    static let cyanDim = Color(red: 42 / 255, green: 143 / 255, blue: 160 / 255)
    static let amber = Color(red: 255 / 255, green: 184 / 255, blue: 28 / 255)
    static let textPrimary = Color(red: 232 / 255, green: 244 / 255, blue: 255 / 255)
    static let textDim = Color(red: 127 / 255, green: 163 / 255, blue: 196 / 255)
    static let error = Color(red: 255 / 255, green: 107 / 255, blue: 107 / 255)

    static func techLabel(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    static func techHeader(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

struct MMCompactButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(title.uppercased(), action: action)
            .font(MMTheme.techLabel())
            .buttonStyle(.bordered)
            .tint(MMTheme.cyan)
            .disabled(!enabled)
    }
}

struct MMPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(title.uppercased(), action: action)
            .font(MMTheme.techLabel())
            .buttonStyle(.borderedProminent)
            .tint(MMTheme.cyan)
            .disabled(!enabled)
    }
}

struct CollapsibleSectionHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MMTheme.textDim)
                Text(title.uppercased())
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                Spacer()
                Text(String(format: "%03d", count))
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

/// Port of Android `TelemetryLine`, from the iPhone's own state: its radio, its scan counters and
/// switches, the loops, and the relay link. Android ends with IPHONE:LINK (an iPhone uses that
/// phone as its relay); the iPhone shows RELAY:LINK when it has a relay to send through.
struct TelemetryBar: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var scan: ScanEngine
    @EnvironmentObject var tx: TxEngine

    var body: some View {
        VStack(spacing: 0) {
            Text(line)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            Rectangle()
                .fill(MMTheme.panelLine)
                .frame(height: 1)
        }
        .background(MMTheme.navy)
    }

    private var line: String {
        TelemetryBar.telemetryLine(vm: vm, scan: scan, tx: tx)
    }

    /// BLE:OFF while Bluetooth is not ready, BLE:SCAN while scanning, otherwise BLE:LINK.
    @MainActor
    private static func radioToken(scan: ScanEngine) -> String {
        if scan.bluetoothStatus != "Bluetooth ready" { return "BLE:OFF" }
        if scan.scanActive { return "BLE:SCAN" }
        return "BLE:LINK"
    }

    /// The telemetry line for the app state. The VFD theme draws the same text in its header.
    @MainActor
    static func telemetryLine(vm: AppViewModel, scan: ScanEngine, tx: TxEngine) -> String {
        var text: String = "MM/RF " + radioToken(scan: scan)
        text += " | RX:\(scan.packetsHeard)"
        text += " | TX-AUTO:\(scan.autoResponsesSent)"
        if scan.scanActive { text += " | SCAN:ON" }
        if scan.autoEnabled { text += " | AUTO:ARM" }
        if scan.recordSessionActive { text += " | LOG:REC" }
        if tx.starlightLoopEnabled { text += " | WAND:LOOP" }
        if tx.txLoopEnabled { text += " | TX:LOOP" }
        if vm.remoteLinkReady { text += " | RELAY:LINK" }
        // Two iPhone-only tokens go last: the band-lighting packets heard and a running replay.
        if scan.lightsHeard > 0 { text += " | LIGHTS:\(scan.lightsHeard)" }
        if tx.replayActive { text += " | REPLAY:\(tx.replayProgress)/\(tx.replayTotal)" }
        return text
    }
}

struct MMCompactTabBar<Tab: Hashable & Identifiable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String
    let icon: (Tab) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: icon(tab))
                            .font(.system(size: 13, weight: .medium))
                        Text(title(tab))
                            .font(MMTheme.techLabel(8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 5)
                    .padding(.bottom, 3)
                    .foregroundStyle(selection == tab ? MMTheme.cyan : MMTheme.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(tab))
            }
        }
        .background(MMTheme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(MMTheme.panelLine).frame(height: 0.5)
        }
    }
}
