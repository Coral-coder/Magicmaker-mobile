package com.magicmaker.android.ui.vfd

import com.magicmaker.android.service.ServiceState

/**
 * LAB tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/lab.py is
 * ported: a panel with live readings and a button that opens the standard LAB screen in a sheet.
 */
object VFDLabScreen : VFDScreen {
    override val title: String = "LAB"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val s: ServiceState.UiState = ctx.state
        val readings: List<Pair<String, String>> = listOf(
            "STATUS" to VFDStub.value(s.status),
            "LAST TX" to VFDStub.value(s.lastTransmitHex),
        )
        return VFDStub.draw(ctx, tab = "lab", label = "LAB", readings = readings)
    }
}
