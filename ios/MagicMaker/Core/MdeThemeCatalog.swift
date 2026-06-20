import Foundation

/// Hawkeye Light Up themes — structure from MDE `HawkeyeLightUpColorTheme` / `HawkeyeMbpThemeAsset`.
struct MdeHawkeyeTheme: Identifiable {
    let mapIdentifier: String
    let title: String
    let colors: [String]
    let lightSequenceBase64: String?
    let categoryId: String
    let transmitHexOverride: String?

    var id: String { mapIdentifier }

    /// Best on-air hex: CMS lightSequence if present, override, else built from swatch colors.
    var transmitHex: String {
        if let override = transmitHexOverride { return HexUtils.canonicalHex(override) }
        if let b64 = lightSequenceBase64, let hex = MdeLightSequence.transmitHex(fromBase64: b64) {
            return HexUtils.canonicalHex(hex)
        }
        if let primary = colors.first, let idx = PacketBuilder.colorIndex(fromHex: primary) {
            return PacketBuilder.preset(color: idx)
        }
        return PacketBuilder.preset(color: PacketBuilder.Color.cyan)
    }
}

/// MBLE VMMS tap layout from `MbleAdvertisingManagerImpl` (manufacturer 0x0183, beacon id 987393).
enum MbleBeaconBuilder {
    static let manufacturerId = 0x0183
    static let beaconId = "987393"

    static func buildPayload(tokenHex: String) -> [UInt8] {
        let token = tokenHex.uppercased().filter { "0123456789ABCDEF".contains($0) }
        let power = UInt8(token.suffix(2), radix: 16) ?? 0xC5
        let idBytes = fixedHexBytes(beaconId, byteCount: 2)
        let body = fixedHexBytes(token, byteCount: 14)
        return [0x0F, 0x11] + idBytes + body + [power]
    }

    private static func fixedHexBytes(_ hex: String, byteCount: Int) -> [UInt8] {
        let padded = String(hex.suffix(byteCount * 2)).padding(toLength: byteCount * 2, withPad: "0", startingAt: 0)
        return stride(from: 0, to: padded.count, by: 2).compactMap { i in
            let start = padded.index(padded.startIndex, offsetBy: i)
            let end = padded.index(start, offsetBy: 2)
            return UInt8(padded[start..<end], radix: 16)
        }
    }
}

/// Hawkeye-style theme catalog (mapIdentifiers mirror MDE CMS `mapIdentifier` field).
enum MdeThemeCatalog {
    static let categories: [(id: String, title: String, themes: [MdeHawkeyeTheme])] = [
        ("solid", "SOLID COLORS", [
            make("cyan-solid", "Cyan", ["#00BCE4"], category: "solid"),
            make("blue-solid", "Blue", ["#0079BC"], category: "solid"),
            make("lavender-solid", "Lavender", ["#B69FCC"], category: "solid"),
            make("purple-solid", "Purple", ["#6B3FA0"], category: "solid"),
            make("pink-solid", "Pink", ["#F078A8"], category: "solid"),
            make("red-solid", "Red", ["#D02030"], category: "solid"),
            make("orange-solid", "Orange", ["#F07830"], category: "solid"),
            make("green-solid", "Green", ["#78C850"], category: "solid"),
            make("white-solid", "White", ["#FFFFFF"], category: "solid"),
        ]),
        ("dual", "DUAL TONES", [
            make("yo-blue", "Yellow-Orange / Blue", ["#F07830", "#0079BC"], category: "dual",
                 hex: PacketBuilder.dual(PacketBuilder.Color.yellowOrange, PacketBuilder.Color.blue)),
            make("purple-pink", "Purple / Pink", ["#6B3FA0", "#F078A8"], category: "dual",
                 hex: PacketBuilder.dual(PacketBuilder.Color.brightPurple, PacketBuilder.Color.pink)),
            make("cyan-green", "Cyan / Green", ["#00BCE4", "#78C850"], category: "dual",
                 hex: PacketBuilder.dual(PacketBuilder.Color.cyan, PacketBuilder.Color.green)),
        ]),
        ("multi", "MULTI-COLOR", [
            make("rainbow-guest", "Guest Rainbow", ["#F07830", "#D02030", "#78C850", "#0079BC", "#6B3FA0"], category: "multi",
                 hex: PacketBuilder.rainbow5()),
        ]),
    ]

    static var allThemes: [MdeHawkeyeTheme] { categories.flatMap(\.themes) }

    private static func make(
        _ mapId: String,
        _ title: String,
        _ colors: [String],
        category: String,
        base64: String? = nil,
        hex: String? = nil
    ) -> MdeHawkeyeTheme {
        MdeHawkeyeTheme(
            mapIdentifier: mapId,
            title: title,
            colors: colors,
            lightSequenceBase64: base64,
            categoryId: category,
            transmitHexOverride: hex
        )
    }
}
