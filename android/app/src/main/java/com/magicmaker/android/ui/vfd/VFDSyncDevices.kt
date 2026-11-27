package com.magicmaker.android.ui.vfd

import com.magicmaker.android.sync.DeviceRow
import com.magicmaker.android.sync.RowTone
import com.magicmaker.android.sync.SyncDashboard
import com.magicmaker.android.sync.SyncEngine
import com.magicmaker.android.sync.SyncStatus

/**
 * SYNC / DEVICES in the VFD theme (docs/SYNC_P3_ANDROID_PLAN.md §5.8): a section with the header
 * (ALL IN SYNC or the first problem, the group short id on the right), then a two-line block per
 * device. Line 1: name, battery, heartbeat age. Line 2: the status dot, the path and the badge
 * (problems in alarm ink). DETAILS toggles the per-session diagnostics; LEAVE SYNC GROUP confirms
 * first. VFDRelayScreen draws it right after its intro note.
 */
object VFDSyncDevices {
    private var details = false

    fun draw(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, c: Int, y0: Int, w: Int,
             d: SyncDashboard = SyncStatus.state.value): Int {
        var y: Int = VFDW.section(fb, L, c, y0, w, "SYNC / DEVICES")
        // Header: the state on the left, the group on the right.
        val headInk: Int = inkOf(d.headerTone)
        val group: String = VFDW.upper(d.group)
        val gStart: Int = fb.textRight(c + w - 1, y, group, VFDSize.small, if (d.grouped) VFDInk.dim else VFDInk.dim)
        val headCols: Int = maxOf(6, gStart - c - 6)
        if (headInk == VFDInk.alarm) VFDW.alarmText(fb, c, y, VFDText.fit(VFDW.upper(d.header), headCols))
        else fb.textFit(c, y, VFDW.upper(d.header), headCols, VFDSize.small, headInk)
        y += VFDW.line + 3
        for (r in d.rows) y = block(fb, c, y, w, r)
        val labels: List<String> = if (d.grouped) listOf(if (details) "Hide" else "Details", "Leave group") else listOf(if (details) "Hide" else "Details")
        y = VFDW.buttons(fb, L, c, y + 2, w, labels, alarm = if (d.grouped) 1 else null, onSelect = { index ->
            when (index) {
                0 -> {
                    details = !details
                    ctx.redraw()
                }
                1 -> ctx.confirm("Leave sync group?", "THIS PHONE FORGETS THE KEY; IT REJOINS AT THE NEXT GROUPED DEVICE",
                    confirmLabel = "LEAVE", destructive = true) {
                    SyncEngine.current?.leaveGroup()
                }
            }
        })
        if (details) {
            val lines: List<String> = d.diag.ifEmpty { listOf("No sync sessions.") }
            for (ln in lines) y = VFDW.textBlock(fb, L, c, y + 1, w, VFDW.upper(ln), color = VFDInk.dim)
        }
        return y
    }

    private fun inkOf(t: RowTone): Int = when (t) {
        RowTone.OK -> VFDInk.highlight
        RowTone.BUSY -> VFDInk.text
        RowTone.PROBLEM -> VFDInk.alarm
        RowTone.IDLE -> VFDInk.dim
    }

    /** Two lines per device; returns the next row. */
    private fun block(fb: VFDFrameBuffer, c: Int, y: Int, w: Int, r: DeviceRow): Int {
        val nameInk: Int = if (r.seen) VFDInk.highlight else VFDInk.dim
        val ink: Int = if (r.seen) VFDInk.text else VFDInk.dim
        val nameCols: Int = minOf(w / 3, 60)
        fb.textFit(c, y, VFDW.upper(r.label), nameCols - 4, VFDSize.small, nameInk)
        val ageStart: Int = if (r.age.isNotEmpty()) fb.textRight(c + w - 1, y, r.age, VFDSize.small, ink) else c + w
        fb.textFit(c + nameCols, y, VFDW.upper(r.battery), maxOf(6, ageStart - c - nameCols - 6), VFDSize.small, ink)
        val y2: Int = y + VFDW.line
        dot(fb, c + 1, y2 + 1, r.tone)
        val badge: String = VFDW.upper(r.badge)
        val bInk: Int = inkOf(r.tone)
        val bStart: Int = if (bInk == VFDInk.alarm) {
            val start: Int = c + w - VFDText.width(badge)
            VFDW.alarmText(fb, start, y2, badge)
            start
        } else {
            fb.textRight(c + w - 1, y2, badge, VFDSize.small, bInk)
        }
        fb.textFit(c + 10, y2, VFDW.upper(r.path), maxOf(4, bStart - c - 16), VFDSize.small, VFDInk.dim)
        return y2 + VFDW.line + 3
    }

    /** A 5 x 5 status LED: solid highlight = in sync, ring = busy, solid alarm = a problem, dim ring = idle. */
    private fun dot(fb: VFDFrameBuffer, x: Int, y: Int, t: RowTone) {
        for (j in 0 until 5) {
            for (i in 0 until 5) {
                val corner: Boolean = (i == 0 || i == 4) && (j == 0 || j == 4)
                if (corner) continue
                val edge: Boolean = i == 0 || i == 4 || j == 0 || j == 4
                when (t) {
                    RowTone.OK -> fb.set(x + i, y + j, VFDInk.highlight)
                    RowTone.PROBLEM -> fb.set(x + i, y + j, if (fb.alarmInverted) VFDInk.highlight else VFDInk.alarm)
                    RowTone.BUSY -> if (edge) fb.set(x + i, y + j, VFDInk.highlight)
                    RowTone.IDLE -> if (edge) fb.set(x + i, y + j, VFDInk.dim)
                }
            }
        }
    }
}
