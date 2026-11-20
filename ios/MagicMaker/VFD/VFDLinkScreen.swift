import SwiftUI

/// LINK tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/link.py
/// is ported: a panel with live readings and a button that opens the standard LINK screen in a
/// sheet.
@MainActor
enum VFDLinkScreen: VFDScreen {
    static let title: String = "LINK"

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let vm: AppViewModel = ctx.vm
        let readings: [(key: String, value: String)] = [
            (key: "BACKEND", value: VFDStub.value(vm.relayBackend.label)),
            (key: "RELAY", value: VFDStub.value(vm.relayStatus)),
            (key: "LINK", value: vm.remoteLinkReady ? "READY" : "DOWN"),
        ]
        return VFDStub.draw(ctx, tab: "link", label: "LINK", readings: readings)
    }
}
