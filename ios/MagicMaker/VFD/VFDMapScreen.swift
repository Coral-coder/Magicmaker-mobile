import SwiftUI

/// MAP tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/map.py
/// is ported: a panel with live readings and a button that opens the standard MAP screen in a
/// sheet.
@MainActor
enum VFDMapScreen: VFDScreen {
    static let title: String = "CAPTURE MAP"

    /// REFRESH, as the standard screen's header (redraws until the grid layout lands).
    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return (text: "REFRESH", action: { ctx.redraw() })
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let readings: [(key: String, value: String)] = [
            (key: "STATUS", value: VFDStub.value(ctx.vm.statusMessage)),
        ]
        return VFDStub.draw(ctx, tab: "map", label: "MAP", readings: readings)
    }
}
