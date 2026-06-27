package com.magicmaker.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.magicmaker.android.MagicMakerApp
import com.magicmaker.android.data.MagicStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import java.io.File
import kotlin.math.roundToInt

/** A clustered capture location — one pin on the map. */
private data class MapPoint(
    val lat: Double,
    val lng: Double,
    val count: Int,
    val label: String,
    val category: String,
)

private const val MAX_MARKERS = 1000

/**
 * Plots where packets were captured, using the lat/lng tagged into the session logs.
 * OpenStreetMap tiles via osmdroid — no API key. Tiles load when online and are cached
 * for offline review afterward.
 */
@Composable
fun MapTab(app: MagicMakerApp, storeRev: Int) {
    var points by remember { mutableStateOf<List<MapPoint>?>(null) }

    LaunchedEffect(storeRev) {
        points = withContext(Dispatchers.IO) { loadMapPoints(app.store) }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = AppDimens.pad, vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("CAPTURE MAP", style = techHeader())
            Text(
                when (val p = points) {
                    null -> "LOADING…"
                    else -> "${p.size} LOCATIONS"
                },
                style = techLabel(),
                color = AppColors.TextDim,
            )
        }
        HorizontalDivider(color = AppColors.PanelLine, thickness = 0.5.dp)

        val current = points
        when {
            current == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = AppColors.Cyan)
            }
            current.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "NO GPS-TAGGED CAPTURES YET — RECORD A SESSION WITH LOCATION ON",
                    style = techLabel(),
                    color = AppColors.TextDim,
                    modifier = Modifier.padding(AppDimens.pad),
                )
            }
            else -> OsmMap(current, Modifier.fillMaxSize())
        }
    }
}

@Composable
private fun OsmMap(points: List<MapPoint>, modifier: Modifier = Modifier) {
    var centered by remember(points) { mutableStateOf(false) }

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
            map.overlays.clear()
            points.forEach { p ->
                val marker = Marker(map)
                marker.position = GeoPoint(p.lat, p.lng)
                marker.setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM)
                marker.title = if (p.count > 1) "${p.label} ×${p.count}" else p.label
                marker.subDescription = p.category
                map.overlays.add(marker)
            }
            if (!centered && points.isNotEmpty()) {
                val avgLat = points.sumOf { it.lat } / points.size
                val avgLng = points.sumOf { it.lng } / points.size
                map.controller.setCenter(GeoPoint(avgLat, avgLng))
                centered = true
            }
            map.invalidate()
        },
        onRelease = { it.onDetach() },
    )
}

private fun loadMapPoints(store: MagicStore): List<MapPoint> {
    // hash by ~1m grid (5 decimal places) so a stationary session collapses to one pin.
    val agg = HashMap<String, MapPoint>()
    for (log in store.listLogs()) {
        for (rec in store.readLog(log.path)) {
            val lat = rec.lat
            val lng = rec.lng
            if (lat.isNaN() || lng.isNaN()) continue
            if (lat == 0.0 && lng == 0.0) continue
            if (lat !in -90.0..90.0 || lng !in -180.0..180.0) continue
            val key = "${(lat * 1e5).roundToInt()},${(lng * 1e5).roundToInt()}"
            val existing = agg[key]
            if (existing == null) {
                agg[key] = MapPoint(lat, lng, 1, rec.label.ifBlank { "Capture" }, rec.category)
            } else {
                agg[key] = existing.copy(count = existing.count + 1)
            }
        }
    }
    return agg.values.sortedByDescending { it.count }.take(MAX_MARKERS)
}
