package com.magicmaker.android.ui

import android.content.Context
import android.graphics.Color
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.graphics.drawable.Drawable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.magicmaker.android.MagicMakerApp
import com.magicmaker.android.data.MagicStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polygon
import java.io.File
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** A clustered capture (receiver) location — where we were standing when we heard packets. */
internal data class CapturePoint(
    val lat: Double,
    val lng: Double,
    val count: Int,
    val label: String,
    val category: String,
)

/** An estimated transmitter position derived from RSSI-weighted observations of one MAC. */
internal data class TxEstimate(
    val address: String,
    val lat: Double,
    val lng: Double,
    val count: Int,
    val bestRssi: Int,
    val radiusM: Double,
    val label: String,
)

internal data class MapData(val captures: List<CapturePoint>, val transmitters: List<TxEstimate>)

private enum class MapMode(val label: String) { CAPTURES("CAPTURES"), TRANSMITTERS("TRANSMITTERS"), BOTH("BOTH") }

private const val MAX_MARKERS = 1000

// A transmitter estimate is only meaningful with several observations from different spots.
private const val MIN_TX_OBSERVATIONS = 3
private const val CAPTURE_COLOR = Color.CYAN
private val TX_COLOR = Color.rgb(255, 140, 0)

/**
 * Plots capture locations (where we heard packets) and, optionally, estimated transmitter
 * positions triangulated from RSSI. OpenStreetMap tiles via osmdroid — no API key.
 */
@Composable
fun MapTab(app: MagicMakerApp, storeRev: Int) {
    var data by remember { mutableStateOf<MapData?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var mode by remember { mutableStateOf(MapMode.CAPTURES) }

    LaunchedEffect(storeRev) {
        data = null
        error = null
        // runCatching guarantees we always resolve out of the LOADING state, even on error.
        val result = withContext(Dispatchers.IO) { runCatching { loadMapData(app.store) } }
        result.onSuccess { data = it }
        result.onFailure { error = it.message ?: it.javaClass.simpleName }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = AppDimens.pad, vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("CAPTURE MAP", style = techHeader())
            Text(
                when {
                    error != null -> "ERROR"
                    data == null -> "LOADING…"
                    else -> "${data!!.captures.size} PTS · ${data!!.transmitters.size} TX"
                },
                style = techLabel(),
                color = AppColors.TextDim,
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = AppDimens.pad, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(AppDimens.gap),
        ) {
            MapMode.entries.forEach { m ->
                Text(
                    m.label,
                    style = techLabel(),
                    color = if (m == mode) AppColors.Cyan else AppColors.TextDim,
                    modifier = Modifier.clickable { mode = m }.padding(vertical = 2.dp),
                )
            }
        }
        HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)

        val current = data
        when {
            error != null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "MAP LOAD FAILED: $error",
                    style = techLabel(),
                    color = AppColors.Amber,
                    modifier = Modifier.padding(AppDimens.pad),
                )
            }
            current == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = AppColors.Cyan)
            }
            current.captures.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "NO GPS-TAGGED CAPTURES YET — RECORD A SESSION WITH LOCATION ON",
                    style = techLabel(),
                    color = AppColors.TextDim,
                    modifier = Modifier.padding(AppDimens.pad),
                )
            }
            else -> OsmMap(current, mode, Modifier.fillMaxSize())
        }
    }
}

@Composable
private fun OsmMap(data: MapData, mode: MapMode, modifier: Modifier = Modifier) {
    var centered by remember(data) { mutableStateOf(false) }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            Configuration.getInstance().apply {
                userAgentValue = context.packageName
                osmdroidBasePath = context.cacheDir
                osmdroidTileCache = File(context.cacheDir, "osmdroid-tiles")
            }
            MapView(context).apply {
                setTileSource(TileSourceFactory.MAPNIK)
                setMultiTouchControls(true)
                controller.setZoom(16.0)
            }
        },
        update = { map ->
            val ctx = map.context
            map.overlays.clear()

            if (mode != MapMode.TRANSMITTERS) {
                val icon = tintedPin(ctx, CAPTURE_COLOR)
                data.captures.forEach { p ->
                    map.overlays.add(
                        Marker(map).apply {
                            position = GeoPoint(p.lat, p.lng)
                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                            title = if (p.count > 1) "${p.label} ×${p.count}" else p.label
                            subDescription = p.category
                            icon?.let { setIcon(it) }
                        },
                    )
                }
            }

            if (mode != MapMode.CAPTURES) {
                val icon = tintedPin(ctx, TX_COLOR)
                data.transmitters.forEach { t ->
                    // Uncertainty halo first, so the pin draws on top.
                    map.overlays.add(
                        Polygon().apply {
                            points = Polygon.pointsAsCircle(GeoPoint(t.lat, t.lng), t.radiusM)
                            fillPaint.color = (0x33 shl 24) or (TX_COLOR and 0xFFFFFF)
                            outlinePaint.color = TX_COLOR
                            outlinePaint.strokeWidth = 2f
                        },
                    )
                    map.overlays.add(
                        Marker(map).apply {
                            position = GeoPoint(t.lat, t.lng)
                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                            title = "${t.address} · est. TX"
                            subDescription = "${t.count} obs · best ${t.bestRssi} dBm · ±${t.radiusM.roundToInt()}m · ${t.label}"
                            icon?.let { setIcon(it) }
                        },
                    )
                }
            }

            if (!centered) {
                val all = data.captures.map { it.lat to it.lng } + data.transmitters.map { it.lat to it.lng }
                if (all.isNotEmpty()) {
                    map.controller.setCenter(GeoPoint(all.sumOf { it.first } / all.size, all.sumOf { it.second } / all.size))
                    centered = true
                }
            }
            map.invalidate()
        },
        onRelease = { it.onDetach() },
    )
}

private fun tintedPin(ctx: Context, color: Int): Drawable? {
    val d = ContextCompat.getDrawable(ctx, org.osmdroid.library.R.drawable.marker_default)?.mutate() ?: return null
    d.colorFilter = PorterDuffColorFilter(color, PorterDuff.Mode.SRC_IN)
    return d
}

/** Single-pass weighted accumulator for one transmitter — O(1) memory regardless of obs count. */
private class TxAccum {
    var n = 0
    var sumW = 0.0
    var sumWLat = 0.0
    var sumWLng = 0.0
    var sumWLat2 = 0.0
    var sumWLng2 = 0.0
    var bestRssi = -999
    var bestLabel = ""

    fun add(lat: Double, lng: Double, rssi: Int, label: String) {
        val w = (rssi + 100).coerceAtLeast(1).toDouble().let { it * it }
        n++
        sumW += w
        sumWLat += w * lat
        sumWLng += w * lng
        sumWLat2 += w * lat * lat
        sumWLng2 += w * lng * lng
        if (rssi > bestRssi) { bestRssi = rssi; bestLabel = label }
    }

    fun estimate(address: String): TxEstimate? {
        if (sumW <= 0.0) return null
        val lat = sumWLat / sumW
        val lng = sumWLng / sumW
        val mLat = 111_320.0
        val mLng = 111_320.0 * cos(Math.toRadians(lat))
        val varLat = (sumWLat2 / sumW - lat * lat).coerceAtLeast(0.0)
        val varLng = (sumWLng2 / sumW - lng * lng).coerceAtLeast(0.0)
        val radius = sqrt(varLat * mLat * mLat + varLng * mLng * mLng).coerceIn(5.0, 500.0)
        return TxEstimate(address, lat, lng, n, bestRssi, radius, bestLabel.ifBlank { address })
    }
}

/**
 * RSSI-weighted centroid localization: weight each receiver position by signal strength
 * (stronger ⇒ we were closer ⇒ counts more), report the weighted spread as the uncertainty
 * radius. Approximate — phone RSSI is noisy — but it points at the source. Streams the logs
 * in one pass with bounded memory so even a flood of pings can't stall or OOM the load.
 */
internal fun loadMapData(store: MagicStore): MapData {
    val captureAgg = HashMap<String, CapturePoint>()
    val byAddress = HashMap<String, TxAccum>()

    store.forEachLoggedLocation { lat, lng, rssi, address, label, category ->
        if (lat.isNaN() || lng.isNaN()) return@forEachLoggedLocation
        if (lat == 0.0 && lng == 0.0) return@forEachLoggedLocation
        if (lat !in -90.0..90.0 || lng !in -180.0..180.0) return@forEachLoggedLocation

        val key = "${(lat * 1e5).roundToInt()},${(lng * 1e5).roundToInt()}"
        val existing = captureAgg[key]
        captureAgg[key] = existing?.copy(count = existing.count + 1)
            ?: CapturePoint(lat, lng, 1, label.ifBlank { "Capture" }, category)

        if (address.isNotBlank()) {
            byAddress.getOrPut(address) { TxAccum() }.add(lat, lng, rssi, label.ifBlank { category })
        }
    }

    val captures = captureAgg.values.sortedByDescending { it.count }.take(MAX_MARKERS)
    val transmitters = byAddress.entries
        .filter { it.value.n >= MIN_TX_OBSERVATIONS }
        .mapNotNull { (address, acc) -> acc.estimate(address) }
        .sortedByDescending { it.count }
        .take(MAX_MARKERS)

    return MapData(captures, transmitters)
}
