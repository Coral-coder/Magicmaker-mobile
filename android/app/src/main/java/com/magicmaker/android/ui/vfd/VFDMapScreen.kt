package com.magicmaker.android.ui.vfd

import com.magicmaker.android.service.ServiceState

/**
 * MAP tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/map.py is
 * ported: a panel with live readings and a button that opens the standard MAP screen in a sheet.
 */
object VFDMapScreen : VFDScreen {
    override val title: String = "CAPTURE MAP"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val s: ServiceState.UiState = ctx.state
        val readings: List<Pair<String, String>> = listOf(
            "STATUS" to VFDStub.value(s.status),
        )
        return VFDStub.draw(ctx, tab = "map", label = "MAP", readings = readings)
    }
}
