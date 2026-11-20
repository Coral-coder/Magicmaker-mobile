import SwiftUI

/// SCAN tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/scan.py
/// is ported: a panel with live readings and a button that opens the standard SCAN screen in a
/// sheet.
@MainActor
enum VFDScanScreen: VFDScreen {
    static let title: String = "SCAN"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let scan: ScanEngine = ctx.scan
        let readings: [(key: String, value: String)] = [
            (key: "RX", value: "\(scan.packetsHeard)"),
            (key: "LIGHTS", value: "\(scan.lightsHeard)"),
            (key: "LAST", value: VFDStub.value(scan.lastHeardLabel)),
        ]
        return VFDStub.draw(ctx, tab: "scan", label: "SCAN", readings: readings)
    }
}
