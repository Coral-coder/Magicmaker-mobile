import MapKit
import SwiftUI

// MAP tab: where packets were heard (every logged packet carries the phone's position) and where
// their transmitters probably are, from RSSI-weighted observations. Port of Android `MapTab.kt`,
// with MapKit in place of osmdroid; the bucketing and estimates live in `Core/MapMath.swift`.

private enum MapScreenMode: CaseIterable, Identifiable {
    case captures
    case transmitters
    case both

    var id: String { label }

    var label: String {
        switch self {
        case .captures: return "CAPTURES"
        case .transmitters: return "TRANSMITTERS"
        case .both: return "BOTH"
        }
    }
}

/// Android `Color.CYAN`.
private let mapCaptureColor: Color = Color(red: 0, green: 1, blue: 1)
/// Android `Color.rgb(255, 140, 0)`.
private let mapTxColor: Color = Color(red: 1, green: 140.0 / 255.0, blue: 0)
/// About what osmdroid's zoom 16 shows across a phone screen.
private let mapInitialSpanMeters: Double = 1000
private let mapCaptureTagPrefix: String = "c|"
private let mapTxTagPrefix: String = "t|"
private let mapEmptyText: String = "NO GPS-TAGGED CAPTURES YET — RECORD A SESSION WITH LOCATION ON"

/// Streams every logged position off the main thread and turns them into map points. The
/// store's own `forEachLoggedLocation` is tied to the main actor, so this uses the file helper
/// behind it, after the rows still queued for the session file have been written.
private func mapScreenLoadData() -> CaptureMapData {
    SessionLogFiles.flushPendingRows()
    var builder = MapMath.Builder()
    SessionLogFiles.forEachLoggedLocation { lat, lng, rssi, address, label, category in
        builder.add(lat: lat, lng: lng, rssi: rssi, address: address, label: label, category: category)
    }
    return builder.build()
}

private func mapCoordinate(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat, longitude: lng)
}

// What Android's marker info window shows.

private func mapCaptureTitle(_ point: CapturePoint) -> String {
    if point.count > 1 { return "\(point.label) ×\(point.count)" }
    return point.label
}

private func mapTxTitle(_ estimate: TxEstimate) -> String {
    shortAddress(estimate.address) + " · est. TX"
}

private func mapTxDetail(_ estimate: TxEstimate) -> String {
    // The label falls back to the source id when the strongest row had none.
    let label: String = estimate.label == estimate.address ? shortAddress(estimate.address) : estimate.label
    let radius: Int = MapMath.roundToInt(estimate.radiusM)
    return "\(estimate.count) obs · best \(estimate.bestRssi) dBm · ±\(radius)m · \(label)"
}

private struct MapScreenInfo {
    let title: String
    let detail: String
}

struct MapScreen: View {
    @EnvironmentObject var vm: AppViewModel

    @State private var data: CaptureMapData? = nil
    @State private var mode: MapScreenMode = .captures
    @State private var camera: MapCameraPosition = .automatic
    /// Tag of the tapped marker ("c|<cell>" or "t|<source>").
    @State private var selection: String? = nil
    @State private var loadTick: Int = 0
    /// Bumped on every load, so the map redraws with the new points and camera.
    @State private var loadVersion: Int = 0
    /// Nothing to plot, so the map was centred on the phone instead.
    @State private var centeredOnPhone: Bool = false

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            header
            modeBar
            hairline
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MMTheme.navy)
        .task(id: loadTick) {
            await load()
        }
        .onChange(of: mode) { _, _ in
            selection = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            MMSectionTitle("CAPTURE MAP")
            Spacer(minLength: 8)
            Text(countsText)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .lineLimit(1)
            Button {
                loadTick += 1
            } label: {
                Text("REFRESH")
                    .font(MMTheme.techLabel())
                    .foregroundStyle(data == nil ? MMTheme.textDim : MMTheme.cyan)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .disabled(data == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var countsText: String {
        guard let current = data else { return "LOADING…" }
        return "\(current.captures.count) PTS · \(current.transmitters.count) TX"
    }

    private var modeBar: some View {
        HStack(spacing: 12) {
            ForEach(MapScreenMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    Text(option.label)
                        .font(MMTheme.techLabel())
                        .foregroundStyle(option == mode ? MMTheme.cyan : MMTheme.textDim)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private var hairline: some View {
        Rectangle()
            .fill(MMTheme.panelLine)
            .frame(height: 0.5)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let current = data {
            if !current.captures.isEmpty || centeredOnPhone {
                MapScreenCanvas(
                    data: current,
                    mode: mode,
                    selectedTag: selection,
                    version: loadVersion,
                    camera: $camera,
                    selection: $selection
                )
                .equatable()
            } else {
                Text(mapEmptyText)
                    .font(MMTheme.techLabel())
                    .foregroundStyle(MMTheme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(16)
            }
        } else {
            ProgressView()
                .tint(MMTheme.cyan)
        }
    }

    // MARK: Loading

    @MainActor
    private func load() async {
        data = nil
        selection = nil
        let result: CaptureMapData = await Task.detached(priority: .userInitiated) { () -> CaptureMapData in
            mapScreenLoadData()
        }.value
        if Task.isCancelled { return }
        recenter(on: result)
        data = result
        loadVersion += 1
    }

    /// Centres once per load on the mean of everything plotted; with nothing to plot, on the
    /// phone's last fix when there is one.
    private func recenter(on result: CaptureMapData) {
        if let center = MapMath.center(of: result) {
            camera = mapRegion(lat: center.lat, lng: center.lng)
            centeredOnPhone = false
            return
        }
        if let here = vm.location.latest {
            camera = mapRegion(lat: here.lat, lng: here.lng)
            centeredOnPhone = true
            return
        }
        centeredOnPhone = false
    }

    private func mapRegion(lat: Double, lng: Double) -> MapCameraPosition {
        let region = MKCoordinateRegion(
            center: mapCoordinate(lat, lng),
            latitudinalMeters: mapInitialSpanMeters,
            longitudinalMeters: mapInitialSpanMeters
        )
        return MapCameraPosition.region(region)
    }
}

/// The map itself, with the tapped marker's details and the empty-state note. It redraws only
/// when the points, the mode, the selection or the load change, not on every update of the
/// screen around it.
private struct MapScreenCanvas: View, Equatable {
    let data: CaptureMapData
    let mode: MapScreenMode
    let selectedTag: String?
    let version: Int
    let camera: Binding<MapCameraPosition>
    let selection: Binding<String?>

    nonisolated static func == (lhs: MapScreenCanvas, rhs: MapScreenCanvas) -> Bool {
        lhs.version == rhs.version && lhs.mode == rhs.mode && lhs.selectedTag == rhs.selectedTag
    }

    var body: some View {
        mapView
            .overlay(alignment: .top) {
                emptyBanner
            }
            .overlay(alignment: .bottom) {
                selectionPanel
            }
    }

    private var mapView: some View {
        let showCaptures: Bool = mode != .transmitters
        let showTransmitters: Bool = mode != .captures
        return Map(position: camera, selection: selection) {
            if showCaptures {
                ForEach(data.captures, id: \.key) { point in
                    captureMarker(point)
                }
                .annotationTitles(.hidden)
            }
            if showTransmitters {
                ForEach(data.transmitters, id: \.address) { estimate in
                    // The uncertainty halo is an overlay, so it always draws under the pin.
                    transmitterHalo(estimate)
                    transmitterMarker(estimate)
                }
                .annotationTitles(.hidden)
            }
        }
    }

    private func captureMarker(_ point: CapturePoint) -> some MapContent {
        Marker(mapCaptureTitle(point), coordinate: mapCoordinate(point.lat, point.lng))
            .tint(mapCaptureColor)
            .tag(mapCaptureTagPrefix + point.key)
    }

    private func transmitterHalo(_ estimate: TxEstimate) -> some MapContent {
        MapCircle(center: mapCoordinate(estimate.lat, estimate.lng), radius: estimate.radiusM)
            .foregroundStyle(mapTxColor.opacity(0.2))
            .stroke(mapTxColor, lineWidth: 2)
    }

    private func transmitterMarker(_ estimate: TxEstimate) -> some MapContent {
        Marker(mapTxTitle(estimate), coordinate: mapCoordinate(estimate.lat, estimate.lng))
            .tint(mapTxColor)
            .tag(mapTxTagPrefix + estimate.address)
    }

    @ViewBuilder
    private var emptyBanner: some View {
        if data.captures.isEmpty {
            Text(mapEmptyText)
                .font(MMTheme.techLabel())
                .foregroundStyle(MMTheme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(MMTheme.panel.opacity(0.92))
                .overlay(Rectangle().stroke(MMTheme.panelLine, lineWidth: 0.5))
                .padding(10)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var selectionPanel: some View {
        if let info = selectedInfo {
            MapScreenInfoPanel(title: info.title, detail: info.detail) {
                selection.wrappedValue = nil
            }
            .padding(10)
        }
    }

    /// What Android's info window shows for the tapped marker.
    private var selectedInfo: MapScreenInfo? {
        guard let tag = selectedTag else { return nil }
        if tag.hasPrefix(mapCaptureTagPrefix) {
            let key = String(tag.dropFirst(mapCaptureTagPrefix.count))
            guard let point = data.captures.first(where: { $0.key == key }) else { return nil }
            return MapScreenInfo(title: mapCaptureTitle(point), detail: point.category)
        }
        if tag.hasPrefix(mapTxTagPrefix) {
            let address = String(tag.dropFirst(mapTxTagPrefix.count))
            guard let estimate = data.transmitters.first(where: { $0.address == address }) else { return nil }
            return MapScreenInfo(title: mapTxTitle(estimate), detail: mapTxDetail(estimate))
        }
        return nil
    }
}

/// The tapped marker's title and description over the bottom of the map (osmdroid's info window).
private struct MapScreenInfoPanel: View {
    let title: String
    let detail: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MMTheme.techHeader())
                    .foregroundStyle(MMTheme.cyan)
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(MMTheme.techLabel())
                        .foregroundStyle(MMTheme.textDim)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MMTheme.textDim)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(10)
        .background(MMTheme.panel.opacity(0.95))
        .overlay(Rectangle().stroke(MMTheme.panelLine, lineWidth: 0.5))
    }
}
