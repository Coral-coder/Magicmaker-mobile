import SwiftUI

/// WAND tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/wand.py
/// is ported: a panel with live readings and a button that opens the standard WAND screen in a
/// sheet.
@MainActor
enum VFDWandScreen: VFDScreen {
    static let title: String = "WAND"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let tx: TxEngine = ctx.tx
        let readings: [(key: String, value: String)] = [
            (key: "COLOUR", value: VFDStub.value(StarlightColors.nameFor(ctx.vm.wandDisplayColorIndex))),
            (key: "WAND LOOP", value: tx.starlightLoopEnabled ? "ON" : "OFF"),
            (key: "STATUS", value: VFDStub.value(tx.status)),
        ]
        return VFDStub.draw(ctx, tab: "wand", label: "WAND", readings: readings)
    }
}
