import SwiftUI

/// LAB tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/lab.py
/// is ported: a panel with live readings and a button that opens the standard LAB screen in a
/// sheet.
@MainActor
enum VFDLabScreen: VFDScreen {
    static let title: String = "LAB"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let tx: TxEngine = ctx.tx
        let readings: [(key: String, value: String)] = [
            (key: "STATUS", value: VFDStub.value(tx.status)),
            (key: "LAST TX", value: VFDStub.value(tx.lastTransmitLabel)),
        ]
        return VFDStub.draw(ctx, tab: "lab", label: "LAB", readings: readings)
    }
}
