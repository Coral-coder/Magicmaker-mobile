import SwiftUI

/// SETTINGS tab in the VFD theme: the screen note and the APPEARANCE section exactly as
/// tools/vfd/screens/settings.py draws them (THEME, then BASE COLOUR with the stored colour's hex on
/// its label row and a true-colour swatch in every chip; CUSTOM opens the system colour picker in a
/// sheet), then a button to the standard SETTINGS screen for transmission, scan filter and about.
@MainActor
enum VFDSettingsScreen: VFDScreen {
    static let title: String = "SETTINGS"

    static let headerNote: String = "Global transmission tuning — applies to every TX."
    static let themes: [String] = ["STANDARD", "VFD"]

    static func headerRight(_ ctx: VFDContext) -> (text: String, action: () -> Void)? {
        return nil
    }

    static func draw(_ ctx: VFDContext) -> Int? {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let c: Int = L.left
        let w: Int = L.width
        var y: Int = L.contentTop
        y = VFDW.textBlock(fb, L, c, y, w, headerNote, color: VFDInk.dim)
        y = appearance(ctx, c, y, w)
        y += VFDW.sectionGap - VFDW.gap
        y = VFDW.button(fb, L, c, y, nil, "OPEN STANDARD SETTINGS", action: {
            ctx.openStandard("settings")
        })
        return y
    }

    /// APPEARANCE: THEME [STANDARD] [VFD]; under VFD, BASE COLOUR (#RRGGBB right-aligned in
    /// highlight) and the chips, left-flowing like THEME.
    static func appearance(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let L: VFDLayout = ctx.L
        let settings: VFDSettings = ctx.settings
        var y: Int = VFDW.section(fb, L, c, top, w, "APPEARANCE")
        let themeIndex: Int = settings.theme == .vfd ? 1 : 0
        y = VFDW.options(fb, L, c, y, w, themes, selected: themeIndex, label: "THEME", onSelect: { index in
            let next: VFDTheme = index == 0 ? VFDTheme.standard : VFDTheme.vfd
            settings.theme = next
        })
        if settings.theme != .vfd {
            return y
        }
        let r: Int = VFDW.groupTop(L, y)
        let hx: String = settings.base.rgb.hex
        let vw: Int = VFDText.width(hx)
        fb.text(c + w - vw, r, hx, .small, VFDInk.highlight)
        fb.textFit(c, r, "BASE COLOUR", w - vw - 6, .small, VFDInk.dim)
        return baseChips(ctx, c, r + VFDW.labelH, w)
    }

    /// The BASE COLOUR chips: VFDW.options geometry with one extra glyph slot after "[" holding a
    /// 5 x 5 swatch of the chip's own colour (CUSTOM: the stored custom colour). The selected chip
    /// is the solid block with its name cut out and an unlit ring around the swatch. Taps
    /// "option:BASE COLOUR:<ITEM>".
    static func baseChips(_ ctx: VFDContext, _ c: Int, _ top: Int, _ w: Int) -> Int {
        let fb: VFDFrameBuffer = ctx.fb
        let settings: VFDSettings = ctx.settings
        let items: [String] = VFDSettings.baseItems
        let selected: Int = settings.baseIndex
        let adv: Int = VFDW.adv
        var x: Int = c
        var y: Int = top
        var i: Int = 0
        for item in items {
            var ow: Int = VFDText.width(count: VFDText.length(item) + 3)
            if x > c && x + ow > c + w {
                x = c
                y += VFDW.ctrlH + VFDW.gap
            }
            ow = min(ow, c + w - x)
            let shown: String = VFDText.fit(item, ow - 3 * adv)
            let fw: Int = VFDText.width(count: VFDText.length(shown) + 3)
            let ty: Int = y + VFDW.ctrlText
            if i == selected {
                fb.fill(x, y + 1, fw, VFDW.ctrlH - 2, VFDInk.highlight)
                fb.fill(x + adv - 1, ty, 7, 7, VFDInk.unlit)
                fb.text(x + 2 * adv, ty, shown, .small, VFDInk.unlit)
            } else {
                fb.text(x, ty, "[", .small, VFDInk.dim)
                fb.text(x + 2 * adv, ty, shown, .small, VFDInk.text)
                fb.text(x + fw - 5, ty, "]", .small, VFDInk.dim)
            }
            let swatch: UInt8 = fb.rgb(settings.itemRGB(i))
            fb.fill(x + adv, ty + 1, 5, 5, swatch)
            let index: Int = i
            VFDW.tap(fb, x - VFDW.optGap / 2, y, ow + VFDW.optGap, VFDW.ctrlH, "option:BASE COLOUR:" + item,
                     action: {
                         VFDSettingsScreen.chooseBase(ctx, index)
                     })
            x += ow + VFDW.optGap
            i += 1
        }
        return y + VFDW.ctrlH + VFDW.gap
    }

    /// A preset applies at once; CUSTOM selects the stored custom colour and opens the picker.
    static func chooseBase(_ ctx: VFDContext, _ index: Int) {
        ctx.settings.selectBase(index: index)
        if index >= VFDBase.presets.count {
            ctx.sheet(id: "vfd.customBase") {
                VFDCustomColorSheet()
            }
        }
    }
}
