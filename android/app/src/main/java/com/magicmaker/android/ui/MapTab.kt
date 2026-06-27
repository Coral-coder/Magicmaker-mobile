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
private data class CapturePoint(
    val lat: Double,
    val lng: Double,
    val count: Int,
    val label: String,
    val category: String,
)

/** An estimated transmitter position derived from RSSI-weighted observations of one MAC. */
private data class TxEstimate(
    val address: String,
    val lat: Double,
    val lng: Double,
    val count: Int,
    val bestRssi: Int,
    val radiusM: Double,
    val label: String,
)

private data class MapData(val captures: List<CapturePoint>, val transmitters: List<TxEstimate>)

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
    var mode by remember { mutableStateOf(MapMode.CAPTURES) }

    LaunchedEffect(storeRev) {
        data = withContext(Dispatchers.IO) { loadMapData(app.store) }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = AppDimens.pad, vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("CAPTURE MAP", style = techHeader())
            Text(
                when (val d = data) {
                    null -> "LOADING…"
                    else -> "${d.captures.size} PTS · ${d.transmitters.size} TX"
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

private class Obs(val lat: Double, val lng: Double, val rssi: Int, val label: String)

private fun loadMapData(store: MagicStore): MapData {
    val captureAgg = HashMap<String, CapturePoint>()
    val byAddress = HashMap<String, MutableList<Obs>>()

    for (log in store.listLogs()) {
        for (rec in store.readLog(log.path)) {
            val lat = rec.lat
            val lng = rec.lng
            if (lat.isNaN() || lng.isNaN()) continue
            if (lat == 0.0 && lng == 0.0) continue
            if (lat !in -90.0..90.0 || lng !in -180.0..180.0) continue

            val key = "${(lat * 1e5).roundToInt()},${(lng * 1e5).roundToInt()}"
            val existing = captureAgg[key]
            captureAgg[key] = existing?.copy(count = existing.count + 1)
                ?: CapturePoint(lat, lng, 1, rec.label.ifBlank { "Capture" }, rec.category)

            if (rec.sourceAddress.isNotBlank()) {
                byAddress.getOrPut(rec.sourceAddress) { mutableListOf() }
                    .add(Obs(lat, lng, rec.rssi, rec.label.ifBlank { rec.category }))
            }
        }
    }

    val captures = captureAgg.values.sortedByDescending { it.count }.take(MAX_MARKERS)
    val transmitters = byAddress.entries
        .filter { it.value.size >= MIN_TX_OBSERVATIONS }
        .mapNotNull { (address, obs) -> estimateTransmitter(address, obs) }
        .sortedByDescending { it.count }
        .take(MAX_MARKERS)

    return MapData(captures, transmitters)
}

/**
 * RSSI-weighted centroid localization: weight each receiver position by signal strength
 * (stronger ⇒ we were closer ⇒ counts more), then report the weighted spread as the
 * uncertainty radius. Approximate — phone RSSI is noisy — but it points at the source.
 */
private fun estimateTransmitter(address: String, obs: List<Obs>): TxEstimate? {
    var sumW = 0.0
    var sumLat = 0.0
    var sumLng = 0.0
    for (o in obs) {
        val w = (o.rssi + 100).coerceAtLeast(1).toDouble().let { it * it }
        sumW += w
        sumLat += w * o.lat
        sumLng += w * o.lng
    }
    if (sumW <= 0.0) return null
    val lat = sumLat / sumW
    val lng = sumLng / sumW

    val metersPerDegLng = 111_320.0 * cos(Math.toRadians(lat))
    var varW = 0.0
    for (o in obs) {
        val w = (o.rssi + 100).coerceAtLeast(1).toDouble().let { it * it }
        val dLat = (o.lat - lat) * 111_320.0
        val dLng = (o.lng - lng) * metersPerDegLng
        varW += w * (dLat * dLat + dLng * dLng)
    }
    val radius = sqrt(varW / sumW).coerceIn(5.0, 500.0)
    val best = obs.maxByOrNull { it.rssi } ?: return null
    return TxEstimate(address, lat, lng, obs.size, best.rssi, radius, best.label)
}
