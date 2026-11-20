package com.magicmaker.android.ui.vfd

import com.magicmaker.android.service.ServiceState

/**
 * AUTO tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/auto.py is
 * ported: a panel with live readings and a button that opens the standard AUTO screen in a sheet.
 */
object VFDAutoScreen : VFDScreen {
    override val title: String = "AUTO"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val s: ServiceState.UiState = ctx.state
        val readings: List<Pair<String, String>> = listOf(
            "AUTO" to (if (s.autoEnabled) "ARMED" else "OFF"),
            "SENT" to s.autoResponsesSent.toString(),
        )
        return VFDStub.draw(ctx, tab = "auto", label = "AUTO", readings = readings)
    }
}
