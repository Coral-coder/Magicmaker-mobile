import SwiftUI

/// STATUS (docs/WATCH_APP.md 5.3): the cluster as the iPhone knows it today. The ESP32
/// transmitter, the Android phone (relay backend and scanner) and the iPhone itself. Pull to
/// refresh; the root view also refreshes every 10 s while this page is open.
struct StatusPage: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.isLuminanceReduced) private var reduced: Bool

    var body: some View {
        let ink: WatchInk = WatchInk(model.theme, reduced: reduced)
        List {
            if !model.reachable {
                line(model.companionInstalled ? "IPHONE NOT REACHABLE" : "INSTALL MAGICMAKER ON IPHONE", .alarm, ink)
            }
            if let status: WatchStatus = model.status {
                esp32Section(status.esp32, ink)
                androidSection(status.android, ink)
                phoneSection(status.phone, ink)
            } else {
                line("NO DATA YET — OPEN MAGICMAKER ON IPHONE", .dim, ink)
            }
            footer(ink)
        }
        .listStyle(.plain)
        .refreshable {
            await model.refresh()
        }
    }

    // MARK: - Sections

    private func esp32Section(_ e: WatchEsp32Status, _ ink: WatchInk) -> some View {
        Section {
            let state: (text: String, tone: WatchTone) = StatusPage.linkState(e.state)
            line(state.text, state.tone, ink, font: WatchFont.title)
            if e.batteryPct != nil || e.batteryMv != nil {
                esp32Battery(e, ink)
            }
            if let program: String = e.program, !program.isEmpty {
                line(program, program == "IDLE" ? .dim : .text, ink)
            }
            let device: String = StatusPage.deviceText(e)
            if !device.isEmpty {
                line(device, .dim, ink, font: WatchFont.small)
            }
            if e.outdated && e.state != "NOT SELECTED" {
                line("REFLASH — FIRMWARE TOO OLD", .alarm, ink, font: WatchFont.small)
            }
        } header: {
            header("ESP32", ink)
        }
    }

    /// "68% ~9H 40M" (alarm when low), "CHARGING · 4.18V" or "4.05V".
    @ViewBuilder
    private func esp32Battery(_ e: WatchEsp32Status, _ ink: WatchInk) -> some View {
        let lowVolts: Bool = (e.batteryMv ?? Int.max) <= 3550
        if e.charging {
            line(e.batteryMv.map { "CHARGING · " + watchVoltsText(mv: $0) } ?? "CHARGING", .text, ink)
        } else if let pct: Int = e.batteryPct {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(pct)%")
                    .font(WatchFont.hero)
                    .watchTone(pct <= 20 || lowVolts ? .alarm : .highlight, ink)
                if let minutes: Int = e.runtimeMin, minutes >= 0 {
                    Text(watchRuntimeText(minutes: minutes))
                        .font(WatchFont.body)
                        .watchTone(.text, ink)
                        .watchLine()
                }
            }
            .listRowBackground(Color.clear)
        } else if let mv: Int = e.batteryMv {
            line(watchVoltsText(mv: mv), lowVolts ? .alarm : .highlight, ink, font: WatchFont.hero)
        }
    }

    private func androidSection(_ a: WatchAndroidStatus, _ ink: WatchInk) -> some View {
        Section {
            let state: (text: String, tone: WatchTone) = StatusPage.linkState(a.state)
            let transport: String = a.transport.isEmpty || a.state == "NOT SELECTED" ? "" : " · " + a.transport
            line(state.text + transport, state.tone, ink, font: WatchFont.title)
            if a.scanning != nil || a.autoArmed != nil {
                let scan: String = a.scanning == true ? "SCAN ON" : "SCAN OFF"
                let auto: String = a.autoArmed == true ? "AUTO ON" : "AUTO OFF"
                line(scan + " · " + auto, a.scanning == true ? .text : .dim, ink)
            }
            if let program: String = a.program, !program.isEmpty {
                line(program, program == "IDLE" ? .dim : .text, ink)
            }
            if let heard: String = a.lastHeardLabel, !heard.isEmpty {
                line("HEARD " + heard.uppercased(), .dim, ink, font: WatchFont.small)
            }
        } header: {
            header("ANDROID", ink)
        }
    }

    private func phoneSection(_ p: WatchPhoneStatus, _ ink: WatchInk) -> some View {
        Section {
            if let pct: Int = p.batteryPct {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "\(pct)%")
                        .font(WatchFont.hero)
                        .watchTone(pct <= 20 && !p.charging ? .alarm : .highlight, ink)
                    if p.charging {
                        Text("CHG")
                            .font(WatchFont.body)
                            .watchTone(.text, ink)
                    }
                }
                .listRowBackground(Color.clear)
            }
            let scan: (text: String, tone: WatchTone) = StatusPage.phoneScanLine(p)
            line(scan.text, scan.tone, ink)
            if !p.lastHeardLabel.isEmpty {
                lastHeard(p, ink)
            }
            if !p.txStatus.isEmpty {
                // TxEngine.status, uppercased: "TX…", "TX LOOP…", "SCANNING", "<LABEL>…".
                let tx: String = p.txStatus.hasPrefix("TX") ? p.txStatus : "TX · " + p.txStatus
                line(tx, p.transmitting ? .highlight : .dim, ink, font: WatchFont.small)
            }
            ForEach(Array(p.programs.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                line(item.element, .text, ink)
            }
        } header: {
            header("IPHONE", ink)
        }
    }

    /// "LAST HEARD <label> · 12S AGO", ticking.
    private func lastHeard(_ p: WatchPhoneStatus, _ ink: WatchInk) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            Text(StatusPage.lastHeardText(p, now: context.date))
                .font(WatchFont.small)
                .watchTone(.dim, ink)
                .lineLimit(2)
        }
        .listRowBackground(Color.clear)
    }

    private func footer(_ ink: WatchInk) -> some View {
        let updatedAt: Double = model.updatedAt
        return Section {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(StatusPage.updatedText(updatedAt, now: context.date))
                    .font(WatchFont.small)
                    .watchTone(.dim, ink)
                    .watchLine()
            }
            .listRowBackground(Color.clear)
            line("PULL TO REFRESH", .dim, ink, font: WatchFont.small)
            Button {
                Task {
                    await model.refresh()
                }
            } label: {
                Text(refreshLabel)
                    .font(WatchFont.smallBold)
                    .watchTone(.highlight, ink)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ink.dim, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(model.refreshing)
            .listRowBackground(Color.clear)
        }
    }

    private var refreshLabel: String {
        model.refreshing ? "REFRESHING…" : "REFRESH"
    }

    // MARK: - Rows

    private func line(_ text: String, _ tone: WatchTone, _ ink: WatchInk, font: Font = WatchFont.body) -> some View {
        Text(text)
            .font(font)
            .watchTone(tone, ink)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
            .listRowBackground(Color.clear)
    }

    private func header(_ title: String, _ ink: WatchInk) -> some View {
        Text(title)
            .font(WatchFont.smallBold)
            .watchTone(.dim, ink)
    }

    // MARK: - Text

    /// LINKED (highlight), LINKING… (dim), NOT LINKED (alarm), NOT SELECTED (dim).
    private static func linkState(_ state: String) -> (text: String, tone: WatchTone) {
        switch state {
        case "LINKED": return ("LINKED", .highlight)
        case "LINKING": return ("LINKING…", .dim)
        case "NOT LINKED": return ("NOT LINKED", .alarm)
        case "NOT SELECTED": return ("NOT SELECTED", .dim)
        default: return (state.uppercased(), .dim)
        }
    }

    /// "FW 1.2 · HELTEC V3 · UP 2H 14M" (missing parts left out); "" when none.
    private static func deviceText(_ e: WatchEsp32Status) -> String {
        var parts: [String] = []
        if let firmware: String = e.firmware, !firmware.isEmpty { parts.append("FW " + firmware) }
        if let board: String = e.board, !board.isEmpty { parts.append(board.uppercased()) }
        if let uptime: Int = e.uptimeS, uptime >= 0 { parts.append(watchUptimeText(seconds: uptime)) }
        return parts.joined(separator: " · ")
    }

    /// "LAST HEARD <label> · 12S AGO"; without a time, no age.
    private static func lastHeardText(_ p: WatchPhoneStatus, now: Date) -> String {
        let label: String = "LAST HEARD " + p.lastHeardLabel.uppercased()
        guard let at: Double = p.lastHeardAt else { return label }
        return label + " · " + watchAgeText(watchSecondsSince(at, now: now)) + " AGO"
    }

    /// "UPDATED 12S AGO" from the newest snapshot's iPhone time; "NOT UPDATED YET" before one.
    private static func updatedText(_ updatedAt: Double, now: Date) -> String {
        guard updatedAt > 0 else { return "NOT UPDATED YET" }
        return "UPDATED " + watchAgeText(watchSecondsSince(updatedAt, now: now)) + " AGO"
    }

    /// The iPhone's scanner. iOS passes band packets to the app only while it is frontmost.
    private static func phoneScanLine(_ p: WatchPhoneStatus) -> (text: String, tone: WatchTone) {
        if p.bluetooth != "BLUETOOTH READY" {
            return (p.bluetooth.isEmpty ? "BLUETOOTH OFF" : p.bluetooth, .alarm)
        }
        if p.scanning && !p.foreground {
            return ("SCAN ON · PAUSED (IPHONE APP IN BACKGROUND)", .dim)
        }
        var text: String = p.scanning ? "SCAN ON" : "SCAN OFF"
        if p.autoArmed { text += " · AUTO ARMED" }
        return (text, p.scanning ? .text : .dim)
    }
}
