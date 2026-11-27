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
            // Scrolls sideways like a ticker when the line is wider than the screen.
            TickerText(text: line, font: MMTheme.techLabel(), color: MMTheme.textDim)
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

    /// "ESP32:68% ~9H 40M", "ESP32:8% LOW ~25M" while the board warns of a low battery (firmware
    /// 1.5+), "ESP32:CHG" (charging or on USB power, as the Android app shows it), "ESP32:4.05V",
    /// or nil when no ESP32 status with a battery. Only while the link is up: the last status is
    /// kept until a poll reads none, and a skipped poll (firmware transfer, GATT work queued) would
    /// otherwise leave an unlinked board's old battery on the bar.
    @MainActor
    static func esp32BatteryToken(vm: AppViewModel) -> String? {
        guard vm.relayBackend == .esp32, vm.relayGattReady, let status = vm.androidRemote else { return nil }
        guard status.batteryMv != nil || status.batteryPercent != nil else { return nil }
        if status.charging { return "ESP32:CHG" }
        let low: String = status.batteryLow ? " LOW" : ""
        var token: String = "ESP32:"
        if let pct = status.batteryPercent {
            token += "\(pct)%" + low
            if let minutes = status.runtimeMinutes, minutes >= 0 {
                token += " " + AndroidRemoteStatus.runtimeText(minutes: minutes)
            }
        } else if let mv = status.batteryMv {
            token += String(format: "%.2fV", Double(mv) / 1000.0) + low
        }
        return token
    }

    /// The telemetry line for the app state. The VFD theme draws the same text in its header.
    @MainActor
    static func telemetryLine(vm: AppViewModel, scan: ScanEngine, tx: TxEngine) -> String {
        var text: String = "MM/RF " + radioToken(scan: scan)
        // The ESP32 transmitter's battery, right at the front, while it is the linked backend.
        if let battery = esp32BatteryToken(vm: vm) { text += " | " + battery }
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


// MARK: - Ticker

/// One line of text that stays put when it fits and otherwise scrolls sideways like a ticker,
/// endlessly, at a normal reading speed (`speed` points per second), with `gap` between copies.
struct TickerText: View {
    let text: String
    let font: Font
    let color: Color
    var speed: Double = 32
    var gap: CGFloat = 36

    @State private var textWidth: CGFloat = 0
    /// Where the scroll counts from. Moved when the text's width changes, so the line keeps its
    /// place instead of jumping (the offset is the time since this, modulo the cycle).
    @State private var epoch: Date = Date()

    var body: some View {
        // The hidden label sets the row's height; the visible one is drawn over it.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { (geo: GeometryProxy) in
                    content(boxWidth: geo.size.width)
                }
            }
            .clipped()
            .background(alignment: .leading) {
                // Natural width of the text, measured once per change.
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .background(GeometryReader { (g: GeometryProxy) in
                        Color.clear.preference(key: TickerWidthKey.self, value: g.size.width)
                    })
            }
            .onPreferenceChange(TickerWidthKey.self) { [widthBinding = $textWidth, epochBinding = $epoch,
                                                        gapWidth = gap, pointsPerSecond = speed] (w: CGFloat) in
                let old: CGFloat = widthBinding.wrappedValue
                if old == w { return }
                // A counter gaining a digit or a token coming or going changes only the cycle's
                // length: the epoch moves so the line stays where it is.
                let oldCycle: Double = Double(old + gapWidth)
                if old > 0 && oldCycle > 0 && pointsPerSecond > 0 {
                    let now: Date = Date()
                    let elapsed: Double = max(0, now.timeIntervalSince(epochBinding.wrappedValue))
                    let travelled: Double = (elapsed * pointsPerSecond).truncatingRemainder(dividingBy: oldCycle)
                    epochBinding.wrappedValue = now.addingTimeInterval(-travelled / pointsPerSecond)
                }
                widthBinding.wrappedValue = w
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    @ViewBuilder
    private func content(boxWidth: CGFloat) -> some View {
        if textWidth > boxWidth + 0.5 && boxWidth > 0 {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                let cycle: Double = Double(textWidth + gap)
                let seconds: Double = max(0, timeline.date.timeIntervalSince(epoch))
                let travelled: Double = (seconds * speed).truncatingRemainder(dividingBy: cycle)
                HStack(spacing: gap) {
                    label
                    label
                }
                .fixedSize()
                .offset(x: -CGFloat(travelled))
            }
        } else {
            label
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct TickerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
