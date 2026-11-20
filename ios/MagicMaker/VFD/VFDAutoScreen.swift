import SwiftUI

/// AUTO tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/auto.py
/// is ported: a panel with live readings and a button that opens the standard AUTO screen in a
/// sheet.
@MainActor
enum VFDAutoScreen: VFDScreen {
    static let title: String = "AUTO"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let scan: ScanEngine = ctx.scan
        let readings: [(key: String, value: String)] = [
            (key: "AUTO", value: scan.autoEnabled ? "ARMED" : "OFF"),
            (key: "SENT", value: "\(scan.autoResponsesSent)"),
        ]
        return VFDStub.draw(ctx, tab: "auto", label: "AUTO", readings: readings)
    }
}
