package com.magicmaker.android.ui.vfd

/**
 * SETTINGS tab in the VFD theme: the screen note and the APPEARANCE section exactly as
 * tools/vfd/screens/settings.py draws them (THEME, then BASE COLOUR with the stored colour's hex
 * on its label row and a true-colour swatch in every chip; CUSTOM opens the colour picker), then
 * a button to the standard SETTINGS screen for transmission tuning.
 * Port of ios/MagicMaker/VFD/VFDSettingsScreen.swift.
 */
object VFDSettingsScreen : VFDScreen {
    override val title: String = "SETTINGS"

    const val headerNote: String = "Global transmission tuning — applies to every TX."
    val themes: List<String> = listOf("STANDARD", "VFD")

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val c: Int = L.left
        val w: Int = L.width
        var y: Int = L.contentTop
        y = VFDW.textBlock(fb, L, c, y, w, headerNote, color = VFDInk.dim)
        y = appearance(ctx, c, y, w)
        y += VFDW.sectionGap - VFDW.gap
        y = VFDW.button(fb, L, c, y, null, "OPEN STANDARD SETTINGS", action = {
            ctx.openStandard("settings")
        })
        return y
    }

    /** APPEARANCE: THEME [STANDARD] [VFD]; under VFD, BASE COLOUR (#RRGGBB right-aligned in
     *  highlight) and the chips, left-flowing like THEME. */
    fun appearance(ctx: VFDContext, c: Int, top: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val settings: VFDSettings = ctx.settings
        var y: Int = VFDW.section(fb, L, c, top, w, "APPEARANCE")
        val themeIndex: Int = if (settings.theme == VFDTheme.vfd) 1 else 0
        y = VFDW.options(fb, L, c, y, w, themes, selected = themeIndex, label = "THEME", onSelect = { index ->
            settings.theme = if (index == 0) VFDTheme.standard else VFDTheme.vfd
        })
        if (settings.theme != VFDTheme.vfd) {
            return y
        }
        val r: Int = VFDW.groupTop(L, y)
        val hx: String = settings.base.rgb.hex
        val vw: Int = VFDText.width(hx)
        fb.text(c + w - vw, r, hx, VFDSize.small, VFDInk.highlight)
        fb.textFit(c, r, "BASE COLOUR", w - vw - 6, VFDSize.small, VFDInk.dim)
        return baseChips(ctx, c, r + VFDW.labelH, w)
    }

    /** The BASE COLOUR chips: VFDW.options geometry with one extra glyph slot after "[" holding a
     *  5 x 5 swatch of the chip's own colour (CUSTOM: the stored custom colour). The selected chip
     *  is the solid block with its name cut out and an unlit ring around the swatch. Taps
     *  "option:BASE COLOUR:<ITEM>". */
    fun baseChips(ctx: VFDContext, c: Int, top: Int, w: Int): Int {
        val fb: VFDFrameBuffer = ctx.fb
        val settings: VFDSettings = ctx.settings
        val items: List<String> = VFDSettings.baseItems
        val selected: Int = settings.baseIndex
        val adv: Int = VFDW.adv
        var x: Int = c
        var y: Int = top
        for ((i, item) in items.withIndex()) {
            var ow: Int = VFDText.width(count = VFDText.length(item) + 3)
            if (x > c && x + ow > c + w) {
                x = c
                y += VFDW.ctrlH + VFDW.gap
            }
            ow = minOf(ow, c + w - x)
            val shown: String = VFDText.fit(item, ow - 3 * adv)
            val fw: Int = VFDText.width(count = VFDText.length(shown) + 3)
            val ty: Int = y + VFDW.ctrlText
            if (i == selected) {
                fb.fill(x, y + 1, fw, VFDW.ctrlH - 2, VFDInk.highlight)
                fb.fill(x + adv - 1, ty, 7, 7, VFDInk.unlit)
                fb.text(x + 2 * adv, ty, shown, VFDSize.small, VFDInk.unlit)
            } else {
                fb.text(x, ty, "[", VFDSize.small, VFDInk.dim)
                fb.text(x + 2 * adv, ty, shown, VFDSize.small, VFDInk.text)
                fb.text(x + fw - 5, ty, "]", VFDSize.small, VFDInk.dim)
            }
            val swatch: Int = fb.rgb(settings.itemRGB(i))
            fb.fill(x + adv, ty + 1, 5, 5, swatch)
            val index: Int = i
            VFDW.tap(fb, x - VFDW.optGap / 2, y, ow + VFDW.optGap, VFDW.ctrlH, "option:BASE COLOUR:$item",
                     action = {
                         chooseBase(ctx, index)
                     })
            x += ow + VFDW.optGap
        }
        return y + VFDW.ctrlH + VFDW.gap
    }

    /** A preset applies at once; CUSTOM selects the stored custom colour and opens the picker. */
    fun chooseBase(ctx: VFDContext, index: Int) {
        val settings: VFDSettings = ctx.settings
        settings.selectBase(index)
        if (index >= VFDBase.presets.size) {
            ctx.pickColor("BASE COLOUR · CUSTOM", settings.customRGB) { rgb ->
                settings.selectCustom(rgb)
            }
        }
    }
}
