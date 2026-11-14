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
}
