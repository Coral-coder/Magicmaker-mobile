package com.magicmaker.android.ui.vfd

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.magicmaker.android.core.RelayControlMode
import com.magicmaker.android.relay.RelayPairingPayload
import com.magicmaker.android.relay.RelayProtocol
import com.magicmaker.android.service.BatteryOptimization
import com.magicmaker.android.service.MagicMakerForegroundService
import com.magicmaker.android.service.ServiceState
import com.magicmaker.android.ui.AppColors
import com.magicmaker.android.ui.RelayQrImage
import com.magicmaker.android.ui.techHeader
import com.magicmaker.android.ui.techLabel

/**
 * RELAY tab in the VFD theme: the Android RelayTab (the counterpart of the iPhone LINK tab) in the
 * layout language of tools/vfd/screens/link.py.
 *
 * RELAY / REMOTE, the STANDALONE note, the MODE selectors (STANDALONE, WIFI / IPHONE, BLE GATT /
 * IPHONE; a pick saves relay_mode and sends ACTION_SET_RELAY, as the FilterChips do), then per
 * mode: the standalone note; the GATT panel (permission / service warnings in alarm ink, the link
 * dot and state, ADV TAG and STATUS info rows, the local-use note); or the WiFi hotspot panel
 * (NEARBY permission warning with GRANT NEARBY, SSID / PASS / GW, the pairing QR drawn on the grid
 * as true black and white cells in a "SCAN WITH IPHONE REMOTE" panel — a tap shows it full size in
 * a sheet — or the expected AP, the HTTP endpoints, then the GATT panel). BATTERY OPT-OUT opens the
 * system battery-optimisation request.
 */
object VFDRelayScreen : VFDScreen {
    override val title: String = "RELAY"

    override fun headerRight(ctx: VFDContext): VFDHeaderRight? = null

    override fun draw(ctx: VFDContext): Int? {
        val fb: VFDFrameBuffer = ctx.fb
        val L: VFDLayout = ctx.L
        val s: ServiceState.UiState = ctx.state
        val c: Int = L.left
        val w: Int = L.width
        var y: Int = L.contentTop
        y = VFDW.section(fb, L, c, y, w, "RELAY / REMOTE")
        y = note(fb, L, c, y + 1, w, INTRO)
        val modes: List<RelayControlMode> = RelayControlMode.entries
        val labels: List<String> = modes.map { modeLabel(it) }
        val selected: Int = modes.indexOf(s.relayMode)
        y = VFDW.options(fb, L, c, y, w, labels, selected = if (selected >= 0) selected else null, label = "Mode",
                         onSelect = { index ->
                             if (index in modes.indices) setMode(ctx, modes[index])
                         })
        y = when (s.relayMode) {
            RelayControlMode.STANDALONE -> note(fb, L, c, y + 3, w, STANDALONE_NOTE)
            RelayControlMode.BLE_GATT -> gattPanel(ctx, fb, L, s, c, y + 2, w)
            RelayControlMode.WIFI_HOTSPOT -> {
                val next: Int = wifiPanel(ctx, fb, L, s, c, y + 2, w)
                gattPanel(ctx, fb, L, s, c, next + 4, w)
            }
        }
        y = VFDW.button(fb, L, c, y + 4, null, "Battery opt-out", action = {
            startActivity(ctx, BatteryOptimization.requestIgnoreIntent(ctx.context))
        })
        return y
    }

    // MARK: - Texts (RelayTab / GattRelayPanel wording)

    private const val INTRO: String =
        "STANDALONE keeps this phone off the air as a relay (no BLE GATT advertising) so an " +
            "iPhone can target the ESP32. Pick BLE GATT or WiFi only when relaying for an iPhone."
    private const val STANDALONE_NOTE: String = "Standalone: transmitting directly, not advertising as an iPhone relay."
    private const val BLE_PERMS: String = "Bluetooth permissions required for GATT remote."
    private const val NOT_RUNNING: String = "Service not running — grant permissions and reopen app."
    private const val LOCAL_NOTE: String = "Local scan/TX/wand keep working — iPhone connects as remote."
    private const val NEARBY_PERMS: String = "NEARBY DEVICES permission required for WiFi hotspot."
    private const val QR_TITLE: String = "SCAN WITH IPHONE REMOTE"
    private const val QR_NOTE: String = "Or join WiFi manually, then open iPhone LINK tab."
    private const val QR_HINT: String = "TAP QR TO ENLARGE"
    private const val EXPECTED_AP: String = "Expected AP: MagicMaker / magic123"
    private const val ENDPOINTS: String = "POST /control  POST /transmit  GET /status  GET /live"

    /** LinkInfoRow key column: 10 character cells. */
    private const val keyCols: Int = 60
    /** LinkInfoRow value lineLimit. */
    private const val valueLines: Int = 3
    /** White modules around the code (the grid around it is near black). */
    private const val qrQuiet: Int = 2

    private fun modeLabel(mode: RelayControlMode): String = when (mode) {
        RelayControlMode.STANDALONE -> "STANDALONE"
        RelayControlMode.WIFI_HOTSPOT -> "WIFI / IPHONE"
        RelayControlMode.BLE_GATT -> "BLE GATT / IPHONE"
    }

    /** The link colour dot: linked, listening, down. */
    private enum class Dot { ok, wait, down }

    /** The pairing QR as a module matrix (no quiet zone). */
    private class QrMatrix(val n: Int, val dark: BooleanArray)

    // MARK: - Small helpers (link.py)

    /** noteText: wrapped small dim text, drawn as given. */
    private fun note(fb: VFDFrameBuffer, L: VFDLayout, c: Int, y: Int, w: Int, s: String): Int =
        VFDW.textBlock(fb, L, c, y, w, s, color = VFDInk.dim)

    /** A warning (amber on the standard screen) as wrapped alarm lines. Returns the next row. */
    private fun warning(fb: VFDFrameBuffer, c: Int, y: Int, w: Int, s: String): Int {
        var r: Int = y
        for (ln in VFDText.wrap(VFDW.upper(s), w - 4)) {
            VFDW.alarmText(fb, c, r, ln)
            r += VFDW.line
        }
        return r + VFDW.gap
    }

    private fun head(a: IntArray, count: Int): String {
        val n: Int = maxOf(0, minOf(count, a.size))
        return VFDText.string(a.copyOfRange(0, n))
    }

    /** Word-wrap s into at most [lines] lines of maxCols cells, cut with … past the last one
     *  (link.py wrap_value). */
    private fun wrapValue(s: String, maxCols: Int, lines: Int): List<String> {
        val out: MutableList<String> = VFDText.wrap(s, maxCols).toMutableList()
        val n: Int = VFDText.maxChars(maxCols)
        if (out.size > lines && out.size > 1 && out[out.size - 1] == VFDText.ellipsis) {
            out.removeAt(out.size - 1)
            out[out.size - 1] = head(VFDText.scalars(out[out.size - 1]), n - 1) + VFDText.ellipsis
        }
        if (out.size > lines && lines > 0) {
            val last: String = out[lines - 1]
            val tail: String = if (VFDText.length(last) + 2 <= n) {
                VFDText.fit(last + " " + VFDText.ellipsis, maxCols)
            } else {
                head(VFDText.scalars(last), n - 1) + VFDText.ellipsis
            }
            return out.subList(0, lines - 1) + tail
        }
        return out
    }

    /** LinkInfoRow: the key (dim) in a keyCols-wide column, the value (uppercased unless it is a
     *  name or credential that must be read exactly) wrapped beside it, up to 3 lines. */
    private fun infoRow(fb: VFDFrameBuffer, c: Int, y: Int, w: Int, key: String, value: String,
                        color: Int = VFDInk.text, upper: Boolean = true): Int {
        fb.textFit(c, y, key, keyCols - 6, VFDSize.small, VFDInk.dim)
        val vx: Int = c + keyCols
        val vw: Int = w - keyCols
        val lines: List<String> = wrapValue(if (upper) VFDW.upper(value) else value, vw, valueLines)
        val shown: List<String> = lines.ifEmpty { listOf("") }
        for ((i, ln) in shown.withIndex()) {
            val r: Int = y + i * VFDW.line
            if (color == VFDInk.alarm) {
                VFDW.alarmText(fb, vx, r, ln)
            } else {
                fb.text(vx, r, ln, VFDSize.small, color)
            }
        }
        return y + maxOf(1, lines.size) * VFDW.line
    }

    private val dotRows: List<String> = listOf(
        "..###..", ".#####.", "#######", "#######", "#######", ".#####.", "..###..",
    )

    private fun dotCell(i: Int, j: Int): Boolean {
        if (j < 0 || j >= dotRows.size) return false
        val line: String = dotRows[j]
        if (i < 0 || i >= line.length) return false
        return line[i] == '#'
    }

    /** The link colour dot as a 7 x 7 pixel LED on caps row y: ok = solid highlight, wait = a
     *  hollow highlight ring, down = solid alarm (on a red-ish base a 9 x 9 highlight block with
     *  the dot cut out). */
    private fun statusDot(fb: VFDFrameBuffer, x: Int, y: Int, state: Dot) {
        if (state == Dot.down && fb.alarmInverted) {
            fb.fill(x - 1, y - 1, 9, 9, VFDInk.highlight)
        }
        for (j in 0 until 7) {
            for (i in 0 until 7) {
                if (!dotCell(i, j)) continue
                val inner: Boolean = i in 1..5 && j in 1..5 && dotCell(i, j - 1) && dotCell(i, j + 1) &&
                    dotCell(i - 1, j) && dotCell(i + 1, j)
                when (state) {
                    Dot.ok -> fb.set(x + i, y + j, VFDInk.highlight)
                    Dot.wait -> if (!inner) fb.set(x + i, y + j, VFDInk.highlight)
                    Dot.down -> fb.set(x + i, y + j, if (fb.alarmInverted) VFDInk.unlit else VFDInk.alarm)
                }
            }
        }
    }

    /** RelayTab's pairing payload (RelayPairingPayload.json) for the current hotspot. */
    private fun pairingJson(s: ServiceState.UiState): String =
        RelayPairingPayload.json(
            ssid = s.hotspotSsid,
            password = s.hotspotPassword,
            gatewayIp = s.relayIp,
            httpPort = s.httpPort,
        ).toString()

    /** The QR modules of [content] (RelayQrImage's QRCodeWriter, one cell per module), null when
     *  it cannot be encoded. */
    private fun qrMatrix(content: String): QrMatrix? {
        return try {
            val hints = mapOf(EncodeHintType.MARGIN to 0)
            val m = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, 0, 0, hints)
            val n: Int = minOf(m.width, m.height)
            val dark = BooleanArray(n * n)
            for (yy in 0 until n) {
                for (xx in 0 until n) {
                    dark[yy * n + xx] = m[xx, yy]
                }
            }
            QrMatrix(n, dark)
        } catch (_: Exception) {
            null
        }
    }

    // MARK: - Panels

    /** GattRelayPanel: the permission / service warning, the link dot and state, ADV TAG,
     *  STATUS (when there is one) and the local-use note. Returns the next free row. */
    private fun gattPanel(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: ServiceState.UiState, c: Int,
                          top: Int, w: Int): Int {
        var y: Int = top
        val bleGranted: Boolean = ctx.coreGranted
        if (!bleGranted) {
            y = warning(fb, c, y + 1, w, BLE_PERMS)
        } else if (!s.running) {
            y = warning(fb, c, y + 1, w, NOT_RUNNING)
        }
        val dot: Dot = when {
            s.relayLinked -> Dot.ok
            !bleGranted || !s.running -> Dot.down
            else -> Dot.wait
        }
        val label: String = if (s.relayLinked) "IPHONE CONNECTED (remote active)" else "GATT LISTENING (local OK)"
        val r: Int = y + 1
        statusDot(fb, c, r, dot)
        fb.textFit(c + 7 + 5, r, VFDW.upper(label), w - 12, VFDSize.small, VFDInk.text)
        y = r + VFDW.line + 1
        // The relay advertises no name (the phone's Bluetooth name is left alone), only this tag.
        y = infoRow(fb, c, y + 2, w, "ADV TAG", RelayProtocol.RELAY_TAG + "  (phone name unchanged)")
        if (s.status.isNotEmpty()) {
            y = infoRow(fb, c, y, w, "STATUS", s.status, color = VFDInk.dim)
        }
        return note(fb, L, c, y + 3, w, LOCAL_NOTE)
    }

    /** The WiFi hotspot part of RelayTab: the NEARBY permission warning and GRANT NEARBY, then the
     *  hotspot (SSID, PASS, GW and the pairing QR panel) or the expected AP, then the HTTP
     *  endpoints. Returns the next free row. */
    private fun wifiPanel(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: ServiceState.UiState, c: Int,
                          top: Int, w: Int): Int {
        var y: Int = top
        if (!ctx.wifiGranted) {
            y = warning(fb, c, y + 1, w, NEARBY_PERMS)
            y = VFDW.button(fb, L, c, y, null, "Grant nearby", action = {
                ctx.requestWifiPermission()
            })
        }
        if (s.hotspotSsid.isNotEmpty()) {
            y = infoRow(fb, c, y + 2, w, "SSID", s.hotspotSsid, color = VFDInk.highlight, upper = false)
            if (s.hotspotPassword.isNotEmpty()) {
                y = infoRow(fb, c, y, w, "PASS", s.hotspotPassword, color = VFDInk.highlight, upper = false)
            }
            y = infoRow(fb, c, y, w, "GW", s.relayIp + ":" + s.httpPort, upper = false)
            y = qrPanel(ctx, fb, L, s, c, y + 4, w)
        } else {
            y = note(fb, L, c, y + 3, w, EXPECTED_AP)
        }
        y += 2
        for (ln in VFDW.tokenLines(ENDPOINTS, w, sep = "  ")) {
            fb.text(c, y, ln, VFDSize.small, VFDInk.dim)
            y += VFDW.line
        }
        return y
    }

    /** SCAN WITH IPHONE REMOTE: a dim panel with the title in its top border holding the pairing
     *  QR as true black and white cells (whole cells per module, a white quiet zone, centred), the
     *  enlarge hint and the manual-join note. A tap on the code shows RelayQrImage full size. */
    private fun qrPanel(ctx: VFDContext, fb: VFDFrameBuffer, L: VFDLayout, s: ServiceState.UiState, c: Int,
                        top: Int, w: Int): Int {
        val inner: VFDPanelInner = VFDW.panelInner(c, top, w, title = true)
        val ic: Int = inner.c
        val iw: Int = inner.w
        var y: Int = inner.r + 2
        val json: String = pairingJson(s)
        val qr: QrMatrix? = ctx.cached("relay.qr", json) { qrMatrix(json) }
        if (qr != null) {
            val modules: Int = qr.n + 2 * qrQuiet
            var scale: Int = minOf(4, (iw * 3 / 5) / modules)
            if (scale < 1) scale = if (modules <= iw) 1 else 0
            if (scale > 0) {
                val side: Int = modules * scale
                val x0: Int = ic + (iw - side) / 2
                drawQr(fb, qr, x0, y, scale)
                VFDW.tap(fb, x0, y, side, side, "qr:PAIRING", action = { showQrSheet(ctx) })
                y += side + 3
                fb.text(VFDW.cx(ic, iw, QR_HINT), y, QR_HINT, VFDSize.small, VFDInk.dim)
                y += VFDW.line + VFDW.gap
            } else {
                y = VFDW.button(fb, L, ic, y, null, "Show QR", primary = true, action = { showQrSheet(ctx) })
            }
        } else {
            y = VFDW.button(fb, L, ic, y, null, "Show QR", primary = true, action = { showQrSheet(ctx) })
        }
        y = note(fb, L, ic, y + 1, iw, QR_NOTE)
        return VFDW.panel(fb, L, c, top, w, y + 2 - top, title = QR_TITLE)
    }

    /** The code with its quiet zone at (x0, y0), [scale] x [scale] cells per module: a white block,
     *  then the dark modules in black. Skipped when the clip shows none of it. */
    private fun drawQr(fb: VFDFrameBuffer, qr: QrMatrix, x0: Int, y0: Int, scale: Int) {
        val side: Int = (qr.n + 2 * qrQuiet) * scale
        val clip: VFDRect = fb.clipRect
        val viewTop: Int = clip.r - fb.originY
        val viewBottom: Int = clip.r + clip.h - fb.originY
        if (y0 + side <= viewTop || y0 >= viewBottom) return
        fb.fill(x0, y0, side, side, fb.rgb(VFDRGB(255, 255, 255)))
        val black: Int = fb.rgb(VFDRGB(0, 0, 0))
        val ox: Int = x0 + qrQuiet * scale
        val oy: Int = y0 + qrQuiet * scale
        for (j in 0 until qr.n) {
            val ry: Int = oy + j * scale
            if (ry + scale <= viewTop || ry >= viewBottom) continue
            for (i in 0 until qr.n) {
                if (qr.dark[j * qr.n + i]) {
                    fb.fill(ox + i * scale, ry, scale, scale, black)
                }
            }
        }
    }

    // MARK: - Actions (run from taps, never from draw)

    /** A mode FilterChip: save relay_mode in "magicmaker" and send ACTION_SET_RELAY. */
    private fun setMode(ctx: VFDContext, mode: RelayControlMode) {
        ctx.context.getSharedPreferences("magicmaker", Context.MODE_PRIVATE)
            .edit().putString("relay_mode", mode.name).apply()
        MagicMakerForegroundService.send(ctx.context, MagicMakerForegroundService.ACTION_SET_RELAY) {
            putExtra(MagicMakerForegroundService.EXTRA_RELAY_MODE, mode.name)
        }
    }

    /** Starts a system screen (RelayTab's ctx.startActivity from the Activity context). */
    private fun startActivity(ctx: VFDContext, intent: Intent) {
        val context: Context = ctx.context
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            ctx.toast("This settings screen is not available on this device")
        } catch (e: SecurityException) {
            // Some builds guard their settings screens (not exported to other apps).
            ctx.toast("This settings screen is not available on this device")
        }
    }

    /** The pairing QR full size (RelayQrImage, as the standard tab draws it) in a sheet; it follows
     *  the live hotspot state. */
    private fun showQrSheet(ctx: VFDContext) {
        ctx.sheet("relay.qr") { scope ->
            val st: ServiceState.UiState = scope.state
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(QR_TITLE, style = techHeader(), color = AppColors.Cyan)
                if (st.hotspotSsid.isNotEmpty()) {
                    RelayQrImage(content = pairingJson(st), sizeDp = 300)
                    Text("SSID: ${st.hotspotSsid}", style = techLabel(), color = AppColors.Cyan)
                    if (st.hotspotPassword.isNotEmpty()) {
                        Text("PASS: ${st.hotspotPassword}", style = techLabel(), color = AppColors.Amber)
                    }
                } else {
                    Text(EXPECTED_AP, style = techLabel(), color = AppColors.TextDim)
                }
            }
        }
    }
}
