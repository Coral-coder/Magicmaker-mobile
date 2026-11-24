import Foundation

/// Starlight wand + MagicBand+ 5-bit colour palette. Port of Android `core/StarlightColors.kt`.
enum StarlightColors {
    struct Entry: Equatable {
        let index: Int
        let name: String
        let hex: String
    }

    /// Full EMCOT 5-bit palette (0x00–0x1F).
    static var palette: [Int: String] { PresetCatalog.starlightColorNames }

    static func nameFor(_ index: Int) -> String {
        let idx = index & 0x1F
        return palette[idx] ?? "Unknown (#\(String(format: "%02X", idx)))"
    }

    static func broadcastHex(_ colorIndex: Int, serial: String = StarlightSerial.defaultSerial) -> String {
        StarlightSerial.buildHex(serial: serial, colorIndex: colorIndex)
    }

    /// All wand colours for UI — uses the stored serial when looping.
    static func entries(serial: String = StarlightSerial.defaultSerial) -> [Entry] {
        palette.keys.sorted().map { idx in
            Entry(index: idx, name: nameFor(idx), hex: broadcastHex(idx, serial: serial))
        }
    }

    // MARK: - Starlight wand colour list (WAND tab, standard and VFD)

    /// New Wand codes carry this signature; the Starlight colour list leaves them out.
    static let newWandSignature: String = "CF0B00C020224EAC7807866"

    static func isNewWandHex(_ hex: String) -> Bool {
        hex.uppercased().contains(newWandSignature)
    }

    /// The colour a Starlight code is listed as: the palette name of the colour index it decodes
    /// to. Indexes the palette names alike (Pink 0x08–0x0E, Cyan 0x00/0x16–0x18, Blue 0x02/0x04,
    /// Purple 0x01/0x07, White 0x1B/0x1C) are one colour. Same as Android `wandColorKey`.
    static func wandColorKey(index: Int) -> String {
        nameFor(index)
    }

    static func wandColorKey(hex: String) -> String {
        nameFor(MagicClassifier.starlightColorIndex(hex))
    }

    /// The Starlight wand colour list: one entry per colour (`wandColorKey`), each the most
    /// recently learned code of that colour — the highest packet id, as the store numbers packets
    /// in the order they are learned (equal ids keep the first) — ordered by colour name. New
    /// Wand codes are left out. Same rule as Android `StarlightColors.wandColors`.
    static func wandColors(_ learned: [MagicPacket]) -> [MagicPacket] {
        var newest: [String: MagicPacket] = [:]
        for packet in learned {
            if isNewWandHex(packet.hex) { continue }
            let key: String = wandColorKey(hex: packet.hex)
            if let kept = newest[key], kept.id >= packet.id { continue }
            newest[key] = packet
        }
        // UTF-16 code unit order, the order Android's sorted() gives.
        let keys: [String] = newest.keys.sorted { (a: String, b: String) -> Bool in
            Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16))
        }
        var out: [MagicPacket] = []
        out.reserveCapacity(keys.count)
        for key in keys {
            if let packet = newest[key] {
                out.append(packet)
            }
        }
        return out
    }

    /// Every learned code the list shows as colour `key` (not only the one it sends), New Wand
    /// codes left out.
    static func wandColorGroup(_ learned: [MagicPacket], key: String) -> [MagicPacket] {
        learned.filter { (packet: MagicPacket) -> Bool in
            !isNewWandHex(packet.hex) && wandColorKey(hex: packet.hex) == key
        }
    }

    /// "Pink · removes 3 learned codes": the delete confirmation's line for a colour row.
    static func wandDeleteLabel(key: String, count: Int) -> String {
        let noun: String = count == 1 ? "code" : "codes"
        return "\(key) · removes \(count) learned \(noun)"
    }
}
