package com.magicmaker.android.ui.vfd

import com.magicmaker.android.service.ServiceState

/**
 * SCAN tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/scan.py is
 * ported: a panel with live readings and a button that opens the standard SCAN screen in a sheet.
 */
object VFDScanScreen : VFDScreen {
    override val title: String = "SCAN"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val s: ServiceState.UiState = ctx.state
        val readings: List<Pair<String, String>> = listOf(
            "RX" to s.packetsHeard.toString(),
            "LIGHTS" to s.lightsHeard.toString(),
            "LAST" to VFDStub.value(s.lastHeardLabel),
        )
        return VFDStub.draw(ctx, tab = "scan", label = "SCAN", readings = readings)
    }
}
