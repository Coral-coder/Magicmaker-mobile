package com.magicmaker.android.ui.vfd

import com.magicmaker.android.core.StarlightColors
import com.magicmaker.android.service.ServiceState

/**
 * WAND tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/wand.py is
 * ported: a panel with live readings and a button that opens the standard WAND screen in a sheet.
 */
object VFDWandScreen : VFDScreen {
    override val title: String = "WAND"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val s: ServiceState.UiState = ctx.state
        val readings: List<Pair<String, String>> = listOf(
            "COLOUR" to VFDStub.value(StarlightColors.nameFor(s.wandDisplayColorIndex)),
            "WAND LOOP" to (if (s.starlightLoopEnabled) "ON" else "OFF"),
            "STATUS" to VFDStub.value(s.status),
        )
        return VFDStub.draw(ctx, tab = "wand", label = "WAND", readings = readings)
    }
}
