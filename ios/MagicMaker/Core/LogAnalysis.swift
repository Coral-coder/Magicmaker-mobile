import Foundation

// Port of the filtering, grouping and counting behind Android `LogsTab` (the `remember` blocks
// and `AnalyzedPacket` in `ui/MagicMakerScreens.kt`).

/// A distinct packet from a log, with how many times it appeared (Android `AnalyzedPacket`).
struct AnalyzedPacket: Identifiable, Equatable {
    /// `MagicClassifier.groupKey` shared by every row counted here.
    let key: String
    /// Hex of the first row of the group, as it was logged.
    let hex: String
    let label: String
    /// Category column of the first row of the group.
    let category: String
    let count: Int

    var id: String { key }

    init(key: String, hex: String, label: String, category: String, count: Int) {
        self.key = key
        self.hex = hex
        self.label = label
        self.category = category
        self.count = count
    }
}

/// One open log seen through the Logs screen's filters.
struct LogSummary {
    /// Rows that pass the type / source / band filters, in file order.
    let filtered: [LoggedPacket]
    /// How many of `filtered` are band telemetry or pings (`MagicClassifier.isLibraryNoise`).
    let noiseCount: Int
    /// Distinct packets of `filtered` (noise left out when asked), most frequent first.
    let analyzed: [AnalyzedPacket]

    init(filtered: [LoggedPacket], noiseCount: Int, analyzed: [AnalyzedPacket]) {
        self.filtered = filtered
        self.noiseCount = noiseCount
        self.analyzed = analyzed
    }
}

enum LogAnalysis {
    /// Android lists at most this many analyzed packets ("…and N more (showing top 300)").
    static let analyzedRowLimit: Int = 300
    /// Android offers a filter chip for at most this many sources.
    static let sourceChipLimit: Int = 12

    /// Distinct non-empty categories of a log, sorted like Kotlin's `sorted()` (UTF-16 order).
    static func categories(_ packets: [LoggedPacket]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for packet in packets {
            let category = packet.category
            if category.isEmpty || seen.contains(category) { continue }
            seen.insert(category)
            out.append(category)
        }
        return out.sorted { (a: String, b: String) -> Bool in
            a.utf16.lexicographicallyPrecedes(b.utf16)
        }
    }

    /// Distinct non-empty source ids of a log, in the order they first appear.
    static func addresses(_ packets: [LoggedPacket]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for packet in packets {
            let address = packet.sourceAddress
            if address.isEmpty || seen.contains(address) { continue }
            seen.insert(address)
            out.append(address)
        }
        return out
    }

    /// Rows whose category is one of `categories` (an empty set passes all), whose source is
    /// `address` (empty passes all) and, with `bandOnly`, that came from a tagged band.
    static func filter(
        _ packets: [LoggedPacket],
        categories: Set<String>,
        address: String,
        bandOnly: Bool
    ) -> [LoggedPacket] {
        var out: [LoggedPacket] = []
        for packet in packets {
            if !categories.isEmpty && !categories.contains(packet.category) { continue }
            if !address.isEmpty && packet.sourceAddress != address { continue }
            if bandOnly && !packet.isBand { continue }
            out.append(packet)
        }
        return out
    }

    /// How many rows are band telemetry or pings.
    static func noiseCount(_ packets: [LoggedPacket]) -> Int {
        var cache: [String: Bool] = [:]
        var count = 0
        for packet in packets {
            if isNoise(packet.hex, &cache) { count += 1 }
        }
        return count
    }

    /// Rows grouped by `MagicClassifier.groupKey`, one entry per group with its count, most
    /// frequent first; groups with the same count keep the order they first appear in. The
    /// label is the classification of the group's first row, or its raw label.
    static func analyze(_ packets: [LoggedPacket], hideNoise: Bool) -> [AnalyzedPacket] {
        // A capture repeats the same few hexes thousands of times: classify each hex once.
        var noiseCache: [String: Bool] = [:]
        var keyCache: [String: String] = [:]
        var slotByKey: [String: Int] = [:]
        var keys: [String] = []
        var samples: [LoggedPacket] = []
        var counts: [Int] = []
        for packet in packets {
            if hideNoise && isNoise(packet.hex, &noiseCache) { continue }
            let key = groupKey(packet.hex, &keyCache)
            if let slot = slotByKey[key] {
                counts[slot] += 1
            } else {
                slotByKey[key] = samples.count
                keys.append(key)
                samples.append(packet)
                counts.append(1)
            }
        }

        let order: [Int] = Array(samples.indices).sorted { (a: Int, b: Int) -> Bool in
            let countA: Int = counts[a]
            let countB: Int = counts[b]
            if countA != countB { return countA > countB }
            return a < b
        }

        var out: [AnalyzedPacket] = []
        out.reserveCapacity(order.count)
        for slot in order {
            let sample = samples[slot]
            let classified: ClassifiedPacket? = MagicClassifier.classify(sample.hex)
            let label: String = classified?.label ?? MagicClassifier.rawLabel(sample.hex)
            out.append(AnalyzedPacket(
                key: keys[slot],
                hex: sample.hex,
                label: label,
                category: sample.category,
                count: counts[slot]
            ))
        }
        return out
    }

    /// Everything the screen shows for one set of filters, in one call so it can run off the
    /// main thread.
    static func summarize(
        _ packets: [LoggedPacket],
        categories: Set<String>,
        address: String,
        bandOnly: Bool,
        hideNoise: Bool
    ) -> LogSummary {
        let filtered = filter(packets, categories: categories, address: address, bandOnly: bandOnly)
        let noise = noiseCount(filtered)
        let analyzed = analyze(filtered, hideNoise: hideNoise)
        return LogSummary(filtered: filtered, noiseCount: noise, analyzed: analyzed)
    }

    // MARK: - Cached per-hex lookups

    private static func isNoise(_ hex: String, _ cache: inout [String: Bool]) -> Bool {
        if let known = cache[hex] { return known }
        let value = MagicClassifier.isLibraryNoise(hex)
        cache[hex] = value
        return value
    }

    private static func groupKey(_ hex: String, _ cache: inout [String: String]) -> String {
        if let known = cache[hex] { return known }
        let value = MagicClassifier.groupKey(hex)
        cache[hex] = value
        return value
    }
}
