import SwiftUI

/// LOGS tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/logs.py
/// is ported: a panel with live readings and a button that opens the standard LOGS screen in a
/// sheet.
@MainActor
enum VFDLogsScreen: VFDScreen {
    static let title: String = "CAPTURE LOGS"

    /// REFRESH, as the standard screen's header (redraws until the grid layout lands).
    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return (text: "REFRESH", action: { ctx.redraw() })
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let scan: ScanEngine = ctx.scan
        let readings: [(key: String, value: String)] = [
            (key: "LOG", value: scan.recordSessionActive ? "REC" : "OFF"),
            (key: "SESSION", value: VFDStub.value(scan.activeSessionName)),
        ]
        return VFDStub.draw(ctx, tab: "logs", label: "LOGS", readings: readings)
    }
}
