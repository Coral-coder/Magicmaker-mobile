import SwiftUI

/// TX tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/tx.py
/// is ported: a panel with live readings and a button that opens the standard TX screen in a
/// sheet.
@MainActor
enum VFDTxScreen: VFDScreen {
    static let title: String = "TX"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let tx: TxEngine = ctx.tx
        let readings: [(key: String, value: String)] = [
            (key: "STATUS", value: VFDStub.value(tx.status)),
            (key: "LAST TX", value: VFDStub.value(tx.lastTransmitLabel)),
            (key: "LOOP", value: tx.txLoopEnabled ? "ON" : "OFF"),
        ]
        return VFDStub.draw(ctx, tab: "tx", label: "TX", readings: readings)
    }
}
