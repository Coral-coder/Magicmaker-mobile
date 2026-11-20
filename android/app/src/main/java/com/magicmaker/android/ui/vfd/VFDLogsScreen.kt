package com.magicmaker.android.ui.vfd

import com.magicmaker.android.service.ServiceState

/**
 * LOGS tab in the VFD theme. Placeholder until the grid layout of tools/vfd/screens/logs.py is
 * ported: a panel with live readings and a button that opens the standard LOGS screen in a sheet.
 */
object VFDLogsScreen : VFDScreen {
    override val title: String = "CAPTURE LOGS"

    /** REFRESH, as the standard screen's header (redraws until the grid layout lands). */
    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = VFDHeaderRight("REFRESH") { ctx.redraw() }

    override fun draw(ctx: VFDContext): Int? {
        val s: ServiceState.UiState = ctx.state
        val readings: List<Pair<String, String>> = listOf(
            "LOG" to (if (s.recordSessionActive) "REC" else "OFF"),
            "SESSION" to VFDStub.value(s.activeSessionName),
        )
        return VFDStub.draw(ctx, tab = "logs", label = "LOGS", readings = readings)
    }
}
