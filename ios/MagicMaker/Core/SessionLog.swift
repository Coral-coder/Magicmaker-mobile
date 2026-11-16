import Foundation

/// A capture log on disk (chronological session file), for the Logs tab.
struct LogFile: Identifiable, Equatable {
    let path: String
    let name: String
    let sizeBytes: Int64
    let modifiedMs: Int64
    let packetCount: Int

    var id: String { path }
}

/// A single recorded packet parsed from a chronological log file.
struct LoggedPacket: Equatable {
    let timestampMs: Int64
    let hex: String
    let rssi: Int
    let label: String
    let category: String
    let typeInfo: String
    let sourceAddress: String
    let isBand: Bool
    /// Where the packet was heard. Nil when the row has no fix (Android keeps NaN / -1 there).
    let lat: Double?
    let lng: Double?
    let accuracy: Double?

    init(
        timestampMs: Int64,
        hex: String,
        rssi: Int,
        label: String,
        category: String,
        typeInfo: String,
        sourceAddress: String,
        isBand: Bool,
        lat: Double? = nil,
        lng: Double? = nil,
        accuracy: Double? = nil
    ) {
        self.timestampMs = timestampMs
        self.hex = hex
        self.rssi = rssi
        self.label = label
        self.category = category
        self.typeInfo = typeInfo
        self.sourceAddress = sourceAddress
        self.isBand = isBand
        self.lat = lat
        self.lng = lng
        self.accuracy = accuracy
    }
}

/// The capture-log CSV format, the same one Android writes (`data/MagicStore.kt`).
enum SessionLog {
    /// Header line of a session log and of its band-only sidecar, newline included.
    static let header =
        "timestamp_ms,hex,rssi,label,category,type_info,colors,note,source_address,is_band,lat,lng,accuracy\n"
    /// Header line of the per-session unique-packet export, newline included.
    static let uniqueHeader = "hex,count,first_ms,last_ms,label,category,addresses\n"

    static let bandSuffix = "_band.csv"
    static let uniqueSuffix = "_unique.csv"

    // MARK: - File names

    /// `scan_<yyyy-MM-dd'T'HH-mm-ss>.csv` in local time.
    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return "scan_" + formatter.string(from: date) + ".csv"
    }

    /// The band-only log that goes with a session file; it shares the stamp so they sort together.
    static func bandFileName(for sessionName: String) -> String {
        baseName(sessionName) + bandSuffix
    }

    /// The deduped export written when the session ends.
    static func uniqueFileName(for sessionName: String) -> String {
        baseName(sessionName) + uniqueSuffix
    }

    static func isSidecar(_ name: String) -> Bool {
        name.hasSuffix(bandSuffix) || name.hasSuffix(uniqueSuffix)
    }

    /// A chronological session log: a csv file that is not one of the two sidecars.
    static func isChronologicalLog(_ name: String) -> Bool {
        name.hasSuffix(".csv") && !isSidecar(name)
    }

    private static func baseName(_ name: String) -> String {
        if name.hasSuffix(".csv") {
            return String(name.dropLast(4))
        }
        return name
    }

    // MARK: - Writing

    /// Commas and newlines would break the row, so they become spaces.
    static func csvField(_ value: String) -> String {
        var needsScrub = false
        for byte in value.utf8 where byte == 0x2C || byte == 0x0A {
            needsScrub = true
            break
        }
        if !needsScrub { return value }
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalar.value == 0x2C || scalar.value == 0x0A {
                out.append(Unicode.Scalar(0x20 as UInt8))
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// One session row, newline included. Missing location fields are left empty.
    static func row(_ rec: Recording) -> String {
        var lat = ""
        if let value = rec.lat { lat = plainDecimal(value) }
        var lng = ""
        if let value = rec.lng { lng = plainDecimal(value) }
        var accuracy = ""
        if let value = rec.accuracy { accuracy = oneDecimal(value) }
        let band: String = rec.isBand ? "true" : "false"
        let fields: [String] = [
            "\(rec.timestampMs)",
            rec.hex,
            "\(rec.rssi)",
            csvField(rec.label),
            rec.category.rawValue,
            rec.typeInfo,
            csvField(rec.colors),
            csvField(rec.libraryNote),
            rec.sourceAddress,
            band,
            lat,
            lng,
            accuracy,
        ]
        return fields.joined(separator: ",") + "\n"
    }

    /// Shortest decimal text that reads back as the same number, never in exponent form for a
    /// coordinate. Empty for NaN and infinity.
    static func plainDecimal(_ value: Double) -> String {
        if !value.isFinite { return "" }
        let shortest = "\(value)"
        if !shortest.contains("e") && !shortest.contains("E") { return shortest }
        // Swift switches to an exponent below 1e-4; a coordinate that close to zero is written
        // out in fixed form. (Nothing as large as the upper switch-over is a coordinate.)
        let magnitude: Double = abs(value)
        if magnitude >= 1 { return shortest }
        let scaled = Int64((magnitude * 1e12).rounded())
        var digits = String(scaled)
        if digits.count < 12 {
            digits = String(repeating: "0", count: 12 - digits.count) + digits
        }
        while digits.count > 1 && digits.hasSuffix("0") {
            digits.removeLast()
        }
        let sign: String = value < 0 ? "-" : ""
        return sign + "0." + digits
    }

    /// A non-negative value with one decimal, half rounded up. Empty when negative or not finite.
    static func oneDecimal(_ value: Double) -> String {
        if !value.isFinite || value < 0 { return "" }
        let tenths: Double = (value * 10).rounded()
        if tenths >= 9e15 { return "\(value)" }
        let scaled = Int64(tenths)
        return "\(scaled / 10).\(scaled % 10)"
    }

    /// One row of the unique-packet export, newline included.
    static func uniqueRow(
        hex: String,
        count: Int,
        firstMs: Int64,
        lastMs: Int64,
        label: String,
        category: MagicCategory,
        addresses: [String]
    ) -> String {
        let fields: [String] = [
            hex,
            "\(count)",
            "\(firstMs)",
            "\(lastMs)",
            csvField(label),
            category.rawValue,
            addresses.joined(separator: " "),
        ]
        return fields.joined(separator: ",") + "\n"
    }

    // MARK: - Reading

    /// Parses one data row. Accepts the 13-column format, the older 8-column iPhone format
    /// (no source, band or location) and the 3-column iPhone backup format
    /// (`timestamp_ms,hex,rssi`), whose label, category and type are filled in by classifying
    /// the hex. Nil for a header, a blank line or a row without a numeric timestamp.
    static func parseRow(_ line: String) -> LoggedPacket? {
        var text = line
        // "\r\n" is a single Character, so all three line endings are checked.
        let lineBreaks: [Character] = [Character("\n"), Character("\r"), Character("\r\n")]
        while let last = text.last, lineBreaks.contains(last) {
            text.removeLast()
        }
        let c: [Substring] = text.split(separator: Character(","), omittingEmptySubsequences: false)
        if c.count < 3 { return nil }
        guard let timestamp = Int64(c[0]) else { return nil }
        let hex = String(c[1])
        let rssi: Int = Int(c[2]) ?? 0

        if c.count < 6 {
            let classified: ClassifiedPacket? = MagicClassifier.classify(hex)
            let label: String = classified?.label ?? MagicClassifier.rawLabel(hex)
            let category: MagicCategory = classified?.category ?? .unknown
            let typeInfo: String = classified?.typeInfo ?? "raw"
            return LoggedPacket(
                timestampMs: timestamp,
                hex: hex,
                rssi: rssi,
                label: label,
                category: category.rawValue,
                typeInfo: typeInfo,
                sourceAddress: "",
                isBand: false
            )
        }

        let address: String = c.count > 8 ? String(c[8]) : ""
        let band: Bool = c.count > 9 && c[9].lowercased() == "true"
        let lat: Double? = c.count > 10 ? finiteDouble(c[10]) : nil
        let lng: Double? = c.count > 11 ? finiteDouble(c[11]) : nil
        var accuracy: Double? = c.count > 12 ? finiteDouble(c[12]) : nil
        if let value = accuracy, value < 0 { accuracy = nil }
        return LoggedPacket(
            timestampMs: timestamp,
            hex: hex,
            rssi: rssi,
            label: String(c[3]),
            category: String(c[4]),
            typeInfo: String(c[5]),
            sourceAddress: address,
            isBand: band,
            lat: lat,
            lng: lng,
            accuracy: accuracy
        )
    }

    /// Every readable data row of a log file. The first line is the header and is dropped.
    static func parseLog(_ data: Data) -> [LoggedPacket] {
        let bytes = [UInt8](data)
        var out: [LoggedPacket] = []
        var start = 0
        var isHeader = true
        while start < bytes.count {
            let end = lineEnd(bytes, from: start)
            if isHeader {
                isHeader = false
            } else {
                var stop = end
                if stop > start && bytes[stop - 1] == 0x0D { stop -= 1 }
                let line = String(decoding: bytes[start..<stop], as: UTF8.self)
                if let packet = parseRow(line) { out.append(packet) }
            }
            start = end + 1
        }
        return out
    }

    /// Number of data rows in a log file: its line count less the header.
    static func rowCount(_ data: Data) -> Int {
        if data.isEmpty { return 0 }
        var newlines = 0
        var lastByte: UInt8 = 0x0A
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            for byte in raw where byte == 0x0A {
                newlines += 1
            }
            if let tail = raw.last { lastByte = tail }
        }
        let lines: Int = lastByte == 0x0A ? newlines : newlines + 1
        return max(lines - 1, 0)
    }

    /// Calls `action` for every row of a log that carries a position, without building packet
    /// values — the map only needs these six fields. Rows with fewer than 12 columns or an
    /// unreadable latitude / longitude are skipped.
    static func forEachLocation(
        in bytes: [UInt8],
        _ action: (_ lat: Double, _ lng: Double, _ rssi: Int, _ address: String, _ label: String, _ category: String) -> Void
    ) {
        // Start offset of each of the first 13 fields of the current line.
        var fieldStart = [Int](repeating: 0, count: 13)
        var start = 0
        var isHeader = true
        while start < bytes.count {
            let end = lineEnd(bytes, from: start)
            let lineStart = start
            start = end + 1
            if isHeader {
                isHeader = false
                continue
            }
            var stop = end
            if stop > lineStart && bytes[stop - 1] == 0x0D { stop -= 1 }

            var fields = 1
            fieldStart[0] = lineStart
            var i = lineStart
            while i < stop {
                if bytes[i] == 0x2C {
                    if fields < 13 { fieldStart[fields] = i + 1 }
                    fields += 1
                }
                i += 1
            }
            if fields < 12 { continue }

            let latText = fieldText(bytes, fieldStart, fields, stop, 10)
            guard let lat = finiteDouble(Substring(latText)) else { continue }
            let lngText = fieldText(bytes, fieldStart, fields, stop, 11)
            guard let lng = finiteDouble(Substring(lngText)) else { continue }
            let rssi: Int = Int(fieldText(bytes, fieldStart, fields, stop, 2)) ?? 0
            let address = fieldText(bytes, fieldStart, fields, stop, 8)
            let label = fieldText(bytes, fieldStart, fields, stop, 3)
            let category = fieldText(bytes, fieldStart, fields, stop, 4)
            action(lat, lng, rssi, address, label, category)
        }
    }

    /// Offset of the newline that ends the line starting at `start`, or the end of the bytes.
    private static func lineEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        let n = bytes.count
        while i < n && bytes[i] != 0x0A { i += 1 }
        return i
    }

    /// Text of field `index` (0...12) of a line that has `fields` fields and ends at `stop`.
    private static func fieldText(
        _ bytes: [UInt8], _ fieldStart: [Int], _ fields: Int, _ stop: Int, _ index: Int
    ) -> String {
        if index < 0 || index >= fields || index >= fieldStart.count { return "" }
        let from = fieldStart[index]
        var to = stop
        if index + 1 < fields && index + 1 < fieldStart.count {
            to = fieldStart[index + 1] - 1
        }
        if from < 0 || to < from || to > bytes.count { return "" }
        return String(decoding: bytes[from..<to], as: UTF8.self)
    }

    private static func finiteDouble(_ text: Substring) -> Double? {
        let trimmed: String = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    // MARK: - Unique tally

    /// Per-session tally behind the `_unique.csv` export: one row per distinct canonical hex,
    /// in the order each was first heard.
    struct UniqueTally {
        private struct Entry {
            var count: Int
            let firstMs: Int64
            var lastMs: Int64
            let label: String
            let category: MagicCategory
            var addresses: [String]
            var seenAddresses: Set<String>

            mutating func note(_ rec: Recording) {
                count += 1
                lastMs = rec.timestampMs
                let address = rec.sourceAddress
                if !address.isEmpty && !seenAddresses.contains(address) {
                    seenAddresses.insert(address)
                    addresses.append(address)
                }
            }
        }

        private var order: [String] = []
        private var entries: [String: Entry] = [:]

        init() {}

        var isEmpty: Bool { order.isEmpty }

        /// Number of distinct packets seen so far.
        var count: Int { order.count }

        mutating func add(_ rec: Recording) {
            let key = HexUtils.canonicalHex(rec.hex)
            if entries[key] != nil {
                entries[key]?.note(rec)
                return
            }
            var addresses: [String] = []
            var seen = Set<String>()
            if !rec.sourceAddress.isEmpty {
                addresses.append(rec.sourceAddress)
                seen.insert(rec.sourceAddress)
            }
            entries[key] = Entry(
                count: 1,
                firstMs: rec.timestampMs,
                lastMs: rec.timestampMs,
                label: rec.label,
                category: rec.category,
                addresses: addresses,
                seenAddresses: seen
            )
            order.append(key)
        }

        mutating func removeAll() {
            order.removeAll()
            entries.removeAll()
        }

        /// The whole export: header, then one row per distinct packet.
        func csv() -> String {
            var out = SessionLog.uniqueHeader
            for hex in order {
                guard let entry = entries[hex] else { continue }
                out += SessionLog.uniqueRow(
                    hex: hex,
                    count: entry.count,
                    firstMs: entry.firstMs,
                    lastMs: entry.lastMs,
                    label: entry.label,
                    category: entry.category,
                    addresses: entry.addresses
                )
            }
            return out
        }
    }
}
