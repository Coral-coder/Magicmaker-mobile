import SwiftUI

/// DIAG tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/diag.py
/// is ported: a panel with live readings and a button that opens the standard DIAG screen in a
/// sheet.
@MainActor
enum VFDDiagScreen: VFDScreen {
    static let title: String = "DIAG"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let scan: ScanEngine = ctx.scan
        let readings: [(key: String, value: String)] = [
            (key: "BLUETOOTH", value: VFDStub.value(scan.bluetoothStatus)),
            (key: "RX", value: "\(scan.packetsHeard)"),
        ]
        return VFDStub.draw(ctx, tab: "diag", label: "DIAG", readings: readings)
    }
}
