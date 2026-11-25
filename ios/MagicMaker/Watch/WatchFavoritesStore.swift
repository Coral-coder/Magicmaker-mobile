import Foundation

/// The packets starred for the Apple Watch (docs/WATCH_APP.md 2.2), in the watch's order, at most
/// `WatchProtocol.maxFavorites`. Kept on this iPhone only, in Application Support, apart from the
/// library store: not in the library export, not synced. Each favourite is a self-contained
/// snapshot (its own label and hex), so deleting the library row does not remove it.
///
/// A row shows a filled star when a favourite with the same canonical hex exists, whatever its
/// source, so a hex is starred only once. The WAND quick button's favourite is the exception: at
/// most one, `source == wandQuick`, and it follows the button when the button is reprogrammed.
///
/// Like `VFDSettings`, the class is not actor-isolated so both themes (SwiftUI views and the VFD
/// renderer) can read `shared` anywhere; every call comes from the main thread.
final class WatchFavoritesStore: ObservableObject {
    static let shared: WatchFavoritesStore = WatchFavoritesStore()

    static let fileName: String = "watch_favorites.json"
    static let corruptFileName: String = "watch_favorites.corrupt.json"
    /// Longest label a favourite keeps (the watch shows two lines of it).
    static let maxLabelLength: Int = 40
    /// The FULL alert both themes show when a star is refused.
    static let fullTitle: String = "FAVORITES FULL (\(WatchProtocol.maxFavorites))"
    static let fullMessage: String = "Remove one in SETTINGS → APPLE WATCH."

    /// The favourites in the watch's order.
    @Published private(set) var items: [WatchFavorite] = []

    /// Canonical hexes of the starred packets (the quick button's favourite not included).
    private var starredHexes: Set<String> = []
    /// The file could not be read (not the same as unreadable content): try again before the
    /// next use instead of overwriting it, e.g. a background launch before the first unlock.
    private var needsLoad: Bool = true

    private struct FileBody: Codable {
        var v: Int
        var items: [WatchFavorite]
    }

    init() {
        load()
    }

    // MARK: - Reading

    var count: Int { return items.count }

    var isFull: Bool { return items.count >= WatchProtocol.maxFavorites }

    /// A favourite with this packet's canonical hex exists (not counting the quick button's).
    func isStarred(hex: String) -> Bool {
        if starredHexes.isEmpty { return false }
        return starredHexes.contains(HexUtils.canonicalHex(hex))
    }

    /// The WAND quick button is starred.
    var isQuickStarred: Bool {
        return items.contains(where: { (f: WatchFavorite) -> Bool in f.source == WatchFavorite.Source.wandQuick })
    }

    func favorite(id: String) -> WatchFavorite? {
        reloadIfNeeded()
        return items.first(where: { (f: WatchFavorite) -> Bool in f.id == id })
    }

    // MARK: - Changing

    /// Adds the packet (at the end) or, when its hex is starred, removes it. Returns false only
    /// when it was not added because the list is full; the caller then shows the FULL alert.
    @discardableResult
    func toggle(hex: String, label: String, source: String) -> Bool {
        reloadIfNeeded()
        let canonical: String = HexUtils.canonicalHex(hex)
        if canonical.isEmpty { return true }
        var next: [WatchFavorite] = items
        if let index = next.firstIndex(where: { (f: WatchFavorite) -> Bool in
            f.source != WatchFavorite.Source.wandQuick && HexUtils.canonicalHex(f.hex) == canonical
        }) {
            next.remove(at: index)
            commit(next)
            return true
        }
        if next.count >= WatchProtocol.maxFavorites { return false }
        next.append(WatchFavoritesStore.describe(hex: canonical, label: label, source: source))
        commit(next)
        return true
    }

    /// Stars or unstars the WAND quick button. Returns false when it was not added (list full).
    @discardableResult
    func toggleQuick(label: String, hex: String) -> Bool {
        reloadIfNeeded()
        var next: [WatchFavorite] = items
        if let index = next.firstIndex(where: { (f: WatchFavorite) -> Bool in f.source == WatchFavorite.Source.wandQuick }) {
            next.remove(at: index)
            commit(next)
            return true
        }
        if next.count >= WatchProtocol.maxFavorites { return false }
        let canonical: String = HexUtils.canonicalHex(hex)
        if canonical.isEmpty { return true }
        next.append(WatchFavoritesStore.describe(hex: canonical, label: label, source: WatchFavorite.Source.wandQuick))
        commit(next)
        return true
    }

    func remove(id: String) {
        reloadIfNeeded()
        let next: [WatchFavorite] = items.filter { (f: WatchFavorite) -> Bool in f.id != id }
        if next.count == items.count { return }
        commit(next)
    }

    /// Moves a favourite `offset` places (-1 up, +1 down), clamped to the list.
    func move(id: String, by offset: Int) {
        reloadIfNeeded()
        guard let from = items.firstIndex(where: { (f: WatchFavorite) -> Bool in f.id == id }) else { return }
        let to: Int = min(max(from + offset, 0), items.count - 1)
        if to == from { return }
        var next: [WatchFavorite] = items
        let moved: WatchFavorite = next.remove(at: from)
        next.insert(moved, at: to)
        commit(next)
    }

    /// A blank label is ignored.
    func rename(id: String, label: String) {
        reloadIfNeeded()
        let cleaned: String = WatchFavoritesStore.cleanLabel(label)
        if cleaned.isEmpty { return }
        guard let index = items.firstIndex(where: { (f: WatchFavorite) -> Bool in f.id == id }) else { return }
        if items[index].label == cleaned { return }
        var next: [WatchFavorite] = items
        next[index].label = cleaned
        commit(next)
    }

    /// The quick button was (maybe) reprogrammed: its favourite takes the new label and hex.
    /// Nothing changes when there is no quick favourite or it already matches.
    func followQuick(label: String, hex: String) {
        reloadIfNeeded()
        guard let index = items.firstIndex(where: { (f: WatchFavorite) -> Bool in f.source == WatchFavorite.Source.wandQuick }) else {
            return
        }
        let canonical: String = HexUtils.canonicalHex(hex)
        if canonical.isEmpty { return }
        let cleaned: String = WatchFavoritesStore.cleanLabel(label)
        let current: WatchFavorite = items[index]
        let newLabel: String = cleaned.isEmpty ? current.label : cleaned
        if current.hex == canonical && current.label == newLabel { return }
        var updated: WatchFavorite = WatchFavoritesStore.describe(hex: canonical, label: newLabel,
                                                                  source: WatchFavorite.Source.wandQuick)
        updated.id = current.id
        updated.addedAt = current.addedAt
        var next: [WatchFavorite] = items
        next[index] = updated
        commit(next)
    }

    // MARK: - Describing a packet

    /// A new favourite for `hex`, with the fields derived from the same tests TxEngine uses to
    /// pick a packet's burst (TxEngine.burstKind) and colour (TxEngine.transmit).
    static func describe(hex: String, label: String, source: String) -> WatchFavorite {
        let canonical: String = HexUtils.canonicalHex(hex)
        var kind: String = WatchFavorite.Kind.band
        var burst: String = WatchFavorite.Burst.command
        var wake: Bool = true
        var swatch: String? = nil
        if HexUtils.isStarlightPacket(canonical) {
            let learned: Int? = MagicClassifier.starlightLearnColorIndex(canonical)
            let index: Int = learned ?? MagicClassifier.starlightColorIndex(canonical)
            let rgb = starlightGlowRGB(index & 0x1F)
            swatch = VFDRGB(unitRed: rgb.red, green: rgb.green, blue: rgb.blue).hex
            kind = WatchFavorite.Kind.wand
            burst = WatchFavorite.Burst.starlight
            wake = false
        } else if WatchFavoritesStore.isPing(canonical) {
            kind = WatchFavorite.Kind.other
            burst = WatchFavorite.Burst.ping
            wake = false
        }
        var shown: String = cleanLabel(label)
        if shown.isEmpty {
            shown = "Packet " + String(canonical.suffix(4))
        }
        return WatchFavorite(
            id: UUID().uuidString,
            label: shown,
            hex: canonical,
            kind: kind,
            source: source,
            burst: burst,
            wake: wake,
            swatch: swatch,
            onAirMs: nil,
            addedAt: Date().timeIntervalSince1970
        )
    }

    /// TxEngine.burstKind's ping test.
    static func isPing(_ canonical: String) -> Bool {
        if canonical == PacketBuilder.wakeupPing { return true }
        if let classified = MagicClassifier.classify(canonical), classified.typeInfo == "ping" { return true }
        return false
    }

    /// Trimmed and cut to `maxLabelLength` characters.
    static func cleanLabel(_ label: String) -> String {
        let trimmed: String = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLabelLength { return trimmed }
        return String(trimmed.prefix(maxLabelLength)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - File

    /// `Application Support/watch_favorites.json`.
    private static func fileURL(_ name: String) -> URL? {
        let manager: FileManager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(name, isDirectory: false)
    }

    /// Reads the file again when the last read failed (the content was never seen).
    func reloadIfNeeded() {
        if needsLoad { load() }
    }

    private func load() {
        guard let url = WatchFavoritesStore.fileURL(WatchFavoritesStore.fileName) else {
            needsLoad = false
            return
        }
        let manager: FileManager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            needsLoad = false
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            // Not readable now (file protection before the first unlock): keep the file.
            needsLoad = true
            return
        }
        needsLoad = false
        guard let body = try? JSONDecoder().decode(FileBody.self, from: data) else {
            // Unreadable content: moved aside, and the list starts empty.
            if let aside = WatchFavoritesStore.fileURL(WatchFavoritesStore.corruptFileName) {
                try? manager.removeItem(at: aside)
                try? manager.moveItem(at: url, to: aside)
            }
            return
        }
        var list: [WatchFavorite] = []
        var seen = Set<String>()
        var quickSeen: Bool = false
        for var item in body.items {
            if list.count >= WatchProtocol.maxFavorites { break }
            if item.id.isEmpty || seen.contains(item.id) { continue }
            item.hex = HexUtils.canonicalHex(item.hex)
            if item.hex.isEmpty { continue }
            if item.source == WatchFavorite.Source.wandQuick {
                if quickSeen { continue }
                quickSeen = true
            }
            seen.insert(item.id)
            list.append(item)
        }
        apply(list)
    }

    private func save() {
        guard let url = WatchFavoritesStore.fileURL(WatchFavoritesStore.fileName) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(FileBody(v: 1, items: items)) else { return }
        let directory: URL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Readable after the first unlock, so a watch message that wakes the app in the
        // background with the phone locked can still find the favourite.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func commit(_ next: [WatchFavorite]) {
        apply(next)
        save()
    }

    private func apply(_ list: [WatchFavorite]) {
        var hexes = Set<String>()
        for item in list where item.source != WatchFavorite.Source.wandQuick {
            hexes.insert(HexUtils.canonicalHex(item.hex))
        }
        starredHexes = hexes
        items = list
    }
}

extension WatchFavorite {
    /// Line 2 of a SETTINGS → APPLE WATCH row: "BAND · 8301CC…" (the hex is cut by the view).
    var phoneDetailText: String {
        var word: String = "PACKET"
        if burst == WatchFavorite.Burst.ping {
            word = "PING"
        } else if kind == WatchFavorite.Kind.wand {
            word = "WAND"
        } else if kind == WatchFavorite.Kind.band {
            word = "BAND"
        }
        return word + " · " + hex
    }

    /// The favourite follows the WAND quick button (shown with a QUICK tag).
    var phoneIsQuick: Bool {
        return source == WatchFavorite.Source.wandQuick
    }

    /// The wand glow colour of `swatch`, or nil.
    var phoneSwatchRGB: VFDRGB? {
        guard let swatch else { return nil }
        return VFDRGB.parse(swatch)
    }
}
