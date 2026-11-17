import Foundation
// `cos` comes from the C library; on Linux it is not guaranteed to come in with Foundation.
#if canImport(Glibc)
import Glibc
#endif

// Port of the capture bucketing and transmitter estimates in Android `ui/MapTab.kt`
// (`CapturePoint`, `TxEstimate`, `TxAccum`, `loadMapData`).

/// A clustered capture (receiver) location — where the phone was when it heard packets.
struct CapturePoint: Identifiable, Equatable {
    /// The ~1.1 m cell this point stands for (`MapMath.bucketKey`).
    let key: String
    /// Position, label and category of the first row heard in the cell.
    let lat: Double
    let lng: Double
    let count: Int
    let label: String
    let category: String

    var id: String { key }

    init(key: String, lat: Double, lng: Double, count: Int, label: String, category: String) {
        self.key = key
        self.lat = lat
        self.lng = lng
        self.count = count
        self.label = label
        self.category = category
    }
}

/// An estimated transmitter position derived from RSSI-weighted observations of one source.
struct TxEstimate: Identifiable, Equatable {
    let address: String
    let lat: Double
    let lng: Double
    let count: Int
    let bestRssi: Int
    /// Uncertainty radius in metres, 5…500.
    let radiusM: Double
    /// Label of the strongest observation; the address when that label was blank.
    let label: String

    var id: String { address }

    init(address: String, lat: Double, lng: Double, count: Int, bestRssi: Int, radiusM: Double, label: String) {
        self.address = address
        self.lat = lat
        self.lng = lng
        self.count = count
        self.bestRssi = bestRssi
        self.radiusM = radiusM
        self.label = label
    }
}

/// Everything the map plots (Android `MapData`).
struct CaptureMapData: Equatable {
    let captures: [CapturePoint]
    let transmitters: [TxEstimate]

    init(captures: [CapturePoint], transmitters: [TxEstimate]) {
        self.captures = captures
        self.transmitters = transmitters
    }
}

enum MapMath {
    /// At most this many capture points and this many transmitters are plotted.
    static let maxMarkers: Int = 1000
    /// A transmitter estimate is only meaningful with several observations from different spots.
    static let minTxObservations: Int = 3
    /// Metres per degree of latitude (and of longitude at the equator).
    static let metersPerDegree: Double = 111_320.0
    static let minRadiusM: Double = 5.0
    static let maxRadiusM: Double = 500.0
    /// Coordinates are bucketed to 1e-5 degree (about 1.1 m).
    static let bucketScale: Double = 1e5

    /// Kotlin `Double.roundToInt()`: nearest integer with halves rounded up, clamped to the
    /// 32-bit range. NaN (which Kotlin rejects) gives 0.
    static func roundToInt(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= 2_147_483_647.0 { return Int(Int32.max) }
        if value <= -2_147_483_648.0 { return Int(Int32.min) }
        let floor: Double = value.rounded(.down)
        let rounded: Double = (value - floor) >= 0.5 ? floor + 1 : floor
        return Int(rounded)
    }

    /// The capture cell of a position: both coordinates scaled by 1e5 and rounded.
    static func bucketKey(lat: Double, lng: Double) -> String {
        let latCell: Int = roundToInt(lat * bucketScale)
        let lngCell: Int = roundToInt(lng * bucketScale)
        return "\(latCell),\(lngCell)"
    }

    /// False for NaN, the (0, 0) no-fix placeholder and anything off the globe.
    static func isPlottable(lat: Double, lng: Double) -> Bool {
        if lat.isNaN || lng.isNaN { return false }
        if lat == 0.0 && lng == 0.0 { return false }
        if lat < -90.0 || lat > 90.0 { return false }
        if lng < -180.0 || lng > 180.0 { return false }
        return true
    }

    /// An RSSI as a Kotlin `Int`: a value outside 32 bits would not have parsed there and reads 0.
    static func kotlinRssi(_ rssi: Int) -> Int {
        guard let narrow = Int32(exactly: rssi) else { return 0 }
        return Int(narrow)
    }

    /// Observation weight: (rssi + 100), at least 1, squared — stronger means closer, so it
    /// counts more. The sum wraps at 32 bits as Kotlin's does.
    static func rssiWeight(_ rssi: Int) -> Double {
        let narrow: Int32 = Int32(exactly: rssi) ?? 0
        let shifted: Int32 = narrow &+ 100
        let base = Double(max(shifted, 1))
        return base * base
    }

    /// Kotlin `isBlank`: empty or only whitespace.
    static func isBlank(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace }
    }

    /// Mean position of every capture point and transmitter, where the map is first centred.
    /// Nil when there is nothing to plot.
    static func center(of data: CaptureMapData) -> (lat: Double, lng: Double)? {
        let count: Int = data.captures.count + data.transmitters.count
        if count == 0 { return nil }
        var sumLat: Double = 0
        var sumLng: Double = 0
        for point in data.captures {
            sumLat += point.lat
            sumLng += point.lng
        }
        for estimate in data.transmitters {
            sumLat += estimate.lat
            sumLng += estimate.lng
        }
        let n = Double(count)
        return (lat: sumLat / n, lng: sumLng / n)
    }

    // MARK: - Transmitter accumulator

    /// Single-pass weighted accumulator for one transmitter (Android `TxAccum`): constant memory
    /// however many observations there are.
    struct TxAccumulator {
        private(set) var n: Int = 0
        private var sumW: Double = 0
        private var sumWLat: Double = 0
        private var sumWLng: Double = 0
        private var sumWLat2: Double = 0
        private var sumWLng2: Double = 0
        private(set) var bestRssi: Int = -999
        private var bestLabel: String = ""

        init() {}

        mutating func add(lat: Double, lng: Double, rssi: Int, label: String) {
            let w: Double = MapMath.rssiWeight(rssi)
            n += 1
            sumW += w
            sumWLat += w * lat
            sumWLng += w * lng
            sumWLat2 += w * lat * lat
            sumWLng2 += w * lng * lng
            if rssi > bestRssi {
                bestRssi = rssi
                bestLabel = label
            }
        }

        /// RSSI-weighted centroid, with the weighted spread as the uncertainty radius.
        func estimate(address: String) -> TxEstimate? {
            if sumW <= 0.0 { return nil }
            let lat: Double = sumWLat / sumW
            let lng: Double = sumWLng / sumW
            let mLat: Double = MapMath.metersPerDegree
            let mLng: Double = MapMath.metersPerDegree * cos(lat / 180.0 * Double.pi)
            let varLat: Double = max(sumWLat2 / sumW - lat * lat, 0.0)
            let varLng: Double = max(sumWLng2 / sumW - lng * lng, 0.0)
            let spread: Double = (varLat * mLat * mLat + varLng * mLng * mLng).squareRoot()
            let radius: Double = min(max(spread, MapMath.minRadiusM), MapMath.maxRadiusM)
            let label: String = MapMath.isBlank(bestLabel) ? address : bestLabel
            return TxEstimate(
                address: address,
                lat: lat,
                lng: lng,
                count: n,
                bestRssi: bestRssi,
                radiusM: radius,
                label: label
            )
        }
    }

    // MARK: - Builder

    /// Collects logged positions one at a time (Android `loadMapData`). Feed it every row from
    /// `forEachLoggedLocation`, then call `build()`.
    struct Builder {
        private var captureSlots: [String: Int] = [:]
        private var captureFirsts: [CapturePoint] = []
        private var captureCounts: [Int] = []
        private var txSlots: [String: Int] = [:]
        private var txAddresses: [String] = []
        private var txAccumulators: [TxAccumulator] = []

        init() {}

        mutating func add(lat: Double, lng: Double, rssi: Int, address: String, label: String, category: String) {
            if !MapMath.isPlottable(lat: lat, lng: lng) { return }

            let key = MapMath.bucketKey(lat: lat, lng: lng)
            if let slot = captureSlots[key] {
                captureCounts[slot] += 1
            } else {
                captureSlots[key] = captureFirsts.count
                let pointLabel: String = MapMath.isBlank(label) ? "Capture" : label
                captureFirsts.append(CapturePoint(
                    key: key,
                    lat: lat,
                    lng: lng,
                    count: 1,
                    label: pointLabel,
                    category: category
                ))
                captureCounts.append(1)
            }

            if MapMath.isBlank(address) { return }
            let txLabel: String = MapMath.isBlank(label) ? category : label
            let signal: Int = MapMath.kotlinRssi(rssi)
            if let slot = txSlots[address] {
                txAccumulators[slot].add(lat: lat, lng: lng, rssi: signal, label: txLabel)
            } else {
                txSlots[address] = txAccumulators.count
                var accumulator = TxAccumulator()
                accumulator.add(lat: lat, lng: lng, rssi: signal, label: txLabel)
                txAccumulators.append(accumulator)
                txAddresses.append(address)
            }
        }

        /// Capture points by count, most first, and transmitters with enough observations by
        /// count, most first; each list capped at `MapMath.maxMarkers`. Equal counts keep the
        /// order they were first heard in.
        func build() -> CaptureMapData {
            return CaptureMapData(captures: sortedCaptures(), transmitters: sortedTransmitters())
        }

        private func sortedCaptures() -> [CapturePoint] {
            let counts: [Int] = captureCounts
            let order: [Int] = Array(captureFirsts.indices).sorted { (a: Int, b: Int) -> Bool in
                let countA: Int = counts[a]
                let countB: Int = counts[b]
                if countA != countB { return countA > countB }
                return a < b
            }
            var out: [CapturePoint] = []
            out.reserveCapacity(min(order.count, MapMath.maxMarkers))
            for slot in order.prefix(MapMath.maxMarkers) {
                let first = captureFirsts[slot]
                out.append(CapturePoint(
                    key: first.key,
                    lat: first.lat,
                    lng: first.lng,
                    count: counts[slot],
                    label: first.label,
                    category: first.category
                ))
            }
            return out
        }

        private func sortedTransmitters() -> [TxEstimate] {
            var estimates: [TxEstimate] = []
            for slot in txAccumulators.indices {
                let accumulator = txAccumulators[slot]
                if accumulator.n < MapMath.minTxObservations { continue }
                if let estimate = accumulator.estimate(address: txAddresses[slot]) {
                    estimates.append(estimate)
                }
            }
            let order: [Int] = Array(estimates.indices).sorted { (a: Int, b: Int) -> Bool in
                let countA: Int = estimates[a].count
                let countB: Int = estimates[b].count
                if countA != countB { return countA > countB }
                return a < b
            }
            var out: [TxEstimate] = []
            out.reserveCapacity(min(order.count, MapMath.maxMarkers))
            for index in order.prefix(MapMath.maxMarkers) {
                out.append(estimates[index])
            }
            return out
        }
    }
}
