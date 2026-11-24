import CryptoKit
import Foundation

// The ESP32 transmitter firmware images the app can install over Bluetooth (FirmwareUpdater):
// the ones bundled with the app (Firmware/magicmaker-<board>-app.bin), and the latest ones of the
// "esp32-firmware" GitHub release, downloaded on request and cached in Application Support.
//
// An OTA image is the APP image: the bytes a merged release image holds from offset 0x10000.
// Every image carries the ASCII marker "MMFW:<version>:<board>" (firmware/esp32-transmitter/ota.h),
// which is how the app knows its version and the board it is built for.

/// The board an image is built for: the "<board>" of its "MMFW:<version>:<board>" marker.
enum FirmwareBoard: String, CaseIterable, Identifiable, Sendable {
    case heltecV3 = "heltec-v3"
    case esp32 = "esp32"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heltecV3: return "HELTEC V3"
        case .esp32: return "ESP32"
        }
    }

    /// How instructions name the board.
    var boardName: String {
        switch self {
        case .heltecV3: return "Heltec"
        case .esp32: return "ESP32"
        }
    }

    /// The button that arms an update (both on GPIO0).
    var buttonName: String {
        switch self {
        case .heltecV3: return "PRG"
        case .esp32: return "BOOT"
        }
    }

    /// esp_image_header_t chip id of its images: ESP32 0, ESP32-S3 9.
    var chipId: UInt16 {
        switch self {
        case .heltecV3: return 9
        case .esp32: return 0
        }
    }

    /// The app image (bundled resource, release asset, cache file).
    var appFileName: String { "magicmaker-\(rawValue)-app.bin" }
    /// The merged release image (flashed at 0x0); its app image starts at 0x10000.
    var mergedFileName: String { "magicmaker-\(rawValue).bin" }
    var bundledResourceName: String { "magicmaker-\(rawValue)-app" }
}

/// Where an image came from.
enum FirmwareSource: String, Sendable {
    case bundled
    case web

    var label: String {
        switch self {
        case .bundled: return "BUNDLED"
        case .web: return "WEB"
        }
    }
}

/// "MMFW:<version>:<board>", as found in an image or at the start of the board's QUERY reply.
struct FirmwareMarker: Equatable, Sendable {
    let version: String
    let board: FirmwareBoard

    static let prefix: String = "MMFW:"

    /// The marker at the start of `text`; anything from the first ';' on is ignored.
    static func parse(_ text: String) -> FirmwareMarker? {
        let head: String = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { (part: Substring) -> String in String(part) } ?? ""
        let parts: [String] = head.split(separator: ":", omittingEmptySubsequences: false)
            .map { (part: Substring) -> String in String(part) }
        guard parts.count == 3, parts[0] == "MMFW", !parts[1].isEmpty,
              let board = FirmwareBoard(rawValue: parts[2]) else {
            return nil
        }
        return FirmwareMarker(version: parts[1], board: board)
    }

    /// The first valid marker in an image's bytes.
    static func find(in data: Data) -> FirmwareMarker? {
        let tag: Data = Data(prefix.utf8)
        var from: Int = data.startIndex
        while from < data.endIndex {
            guard let found = data.range(of: tag, options: [], in: from..<data.endIndex) else { return nil }
            // The marker is a C string: printable ASCII up to its NUL.
            var end: Int = found.upperBound
            let limit: Int = min(data.endIndex, found.lowerBound + 80)
            while end < limit {
                let byte: UInt8 = data[end]
                if byte < 0x21 || byte > 0x7E || byte == 0x3B { break }
                end += 1
            }
            let text: String = String(decoding: data[found.lowerBound..<end], as: UTF8.self)
            if let marker = parse(text) { return marker }
            from = found.upperBound
        }
        return nil
    }
}

/// Firmware version order: dotted parts compared as numbers ("1.10" is newer than "1.9"), a
/// missing part counts as 0, and a text part (a pre-release tag) sorts below a number.
enum FirmwareVersion {
    /// -1 when a is older than b, 0 when the same, 1 when newer.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa: [String] = parts(a)
        let pb: [String] = parts(b)
        let n: Int = max(pa.count, pb.count)
        var i: Int = 0
        while i < n {
            let xs: String = i < pa.count ? pa[i] : ""
            let ys: String = i < pb.count ? pb[i] : ""
            i += 1
            let xn: Int? = xs.isEmpty ? 0 : Int(xs)
            let yn: Int? = ys.isEmpty ? 0 : Int(ys)
            if let xv = xn, let yv = yn {
                if xv != yv { return xv < yv ? -1 : 1 }
                continue
            }
            if xn != nil { return 1 }
            if yn != nil { return -1 }
            if xs != ys { return xs < ys ? -1 : 1 }
        }
        return 0
    }

    private static func parts(_ version: String) -> [String] {
        var s: String = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s.split(whereSeparator: { (ch: Character) -> Bool in ch == "." || ch == "-" || ch == "+" })
            .map { (part: Substring) -> String in String(part) }
    }
}

/// One installable app image.
struct FirmwareImage: Sendable {
    let board: FirmwareBoard
    let version: String
    let source: FirmwareSource
    let data: Data

    var size: Int { data.count }
}

/// What a web check found.
struct FirmwareWebResult: Sendable {
    /// Images downloaded on this check (each newer than the one the app had for its board).
    var images: [FirmwareImage] = []
    /// The release's firmware version (its firmware.json), when it lists one.
    var releaseVersion: String? = nil
    /// Per board, what the check found when nothing was downloaded for it.
    var notes: [String] = []
    /// Set when the release itself could not be read.
    var error: String? = nil
}

/// The release's firmware.json (tools/firmware_manifest.py): the version, and per board the app
/// image's MD5, which a download is checked against.
struct FirmwareReleaseManifest: Sendable {
    var version: String?
    var appMd5: [FirmwareBoard: String] = [:]

    static func parse(_ data: Data) -> FirmwareReleaseManifest? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            return nil
        }
        var out = FirmwareReleaseManifest(version: json["version"] as? String)
        if let boards = json["boards"] as? [String: Any] {
            for (key, value) in boards {
                guard let board = FirmwareBoard(rawValue: key), let entry = value as? [String: Any] else { continue }
                if let md5 = entry["md5"] as? String, md5.count == 32 {
                    out.appMd5[board] = md5.lowercased()
                }
            }
        }
        return out
    }
}

/// Reading, checking, downloading and caching images. Not tied to the main actor, so file and
/// network work runs off it.
enum FirmwareFiles {
    /// Where the app image starts in a merged release image.
    static let appOffset: Int = 0x10000
    /// The firmware's own size cap (OTA_MAX_SIZE).
    static let maxImageBytes: Int = 0x300000
    static let releaseAPI: String = "https://api.github.com/repos/Coral-coder/Magicmaker-mobile/releases/tags/esp32-firmware"
    static let manifestFileName: String = "firmware.json"
    private static let userAgent: String = "MagicMaker-iOS"

    /// An image the board can take: an ESP image header for the board's chip, a sane size, and a
    /// marker naming the same board.
    static func makeImage(from data: Data, source: FirmwareSource, board expected: FirmwareBoard) -> FirmwareImage? {
        guard data.count >= 0x1000, data.count <= maxImageBytes else { return nil }
        let start: Int = data.startIndex
        guard data[start] == 0xE9 else { return nil }
        let chipLow: UInt16 = UInt16(data[start + 12])
        let chipHigh: UInt16 = UInt16(data[start + 13])
        guard (chipLow | (chipHigh << 8)) == expected.chipId else { return nil }
        guard let marker = FirmwareMarker.find(in: data), marker.board == expected else { return nil }
        return FirmwareImage(board: expected, version: marker.version, source: source, data: Data(data))
    }

    /// Lower-case hex MD5 of `data`.
    static func md5Hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { (byte: UInt8) -> String in String(format: "%02x", byte) }.joined()
    }

    /// The images shipped in the app bundle.
    static func bundledImages() -> [FirmwareImage] {
        var out: [FirmwareImage] = []
        for board in FirmwareBoard.allCases {
            let name: String = board.bundledResourceName
            let url: URL? = Bundle.main.url(forResource: name, withExtension: "bin")
                ?? Bundle.main.url(forResource: name, withExtension: "bin", subdirectory: "Firmware")
            guard let url, let data = try? Data(contentsOf: url) else { continue }
            if let image = makeImage(from: data, source: .bundled, board: board) {
                out.append(image)
            }
        }
        return out
    }

    /// Application Support/Firmware, created on first use and kept out of backups.
    static func cacheDirectory() -> URL? {
        let fm: FileManager = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        var dir: URL = base.appendingPathComponent("Firmware", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return nil
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    static func cacheURL(_ board: FirmwareBoard) -> URL? {
        cacheDirectory()?.appendingPathComponent(board.appFileName)
    }

    /// The images downloaded earlier (the newest per board).
    static func cachedImages() -> [FirmwareImage] {
        var out: [FirmwareImage] = []
        for board in FirmwareBoard.allCases {
            guard let url = cacheURL(board), let data = try? Data(contentsOf: url) else { continue }
            if let image = makeImage(from: data, source: .web, board: board) {
                out.append(image)
            }
        }
        return out
    }

    /// Keeps `image` as the board's cached image when it is newer than the one there.
    @discardableResult
    static func cacheIfNewer(_ image: FirmwareImage) -> Bool {
        guard let url = cacheURL(image.board) else { return false }
        if let old = try? Data(contentsOf: url),
           let cached = makeImage(from: old, source: .web, board: image.board),
           FirmwareVersion.compare(cached.version, image.version) >= 0 {
            return false
        }
        do {
            try image.data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The latest release images from GitHub (public repository, no token). `have`: the version
    /// the app already has per board; a board whose release version (firmware.json) is not newer
    /// is not downloaded. Otherwise each board's magicmaker-<board>-app.bin is downloaded (or else
    /// its merged magicmaker-<board>.bin, from 0x10000), checked against firmware.json's MD5 and
    /// the image's own header and marker, and cached when newer than the cached one.
    static func fetchLatest(have: [FirmwareBoard: String]) async -> FirmwareWebResult {
        var result = FirmwareWebResult()
        guard let api = URL(string: releaseAPI) else {
            result.error = "bad release address"
            return result
        }
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let reply: (Data, URLResponse)
        do {
            reply = try await URLSession.shared.data(for: request)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        let body: Data = reply.0
        let code: Int = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 {
            result.error = "no firmware release on GitHub"
            return result
        }
        if code == 403 || code == 429 {
            result.error = "GitHub is limiting requests — try again in an hour"
            return result
        }
        if code != 200 {
            result.error = "GitHub answered \(code)"
            return result
        }
        let assets: [String: URL] = releaseAssets(body)
        if assets.isEmpty {
            result.error = "the release has no files"
            return result
        }
        var manifest: FirmwareReleaseManifest? = nil
        if let url = assets[manifestFileName], let json = await download(url, limit: 64 * 1024) {
            manifest = FirmwareReleaseManifest.parse(json)
        }
        result.releaseVersion = manifest?.version
        for board in FirmwareBoard.allCases {
            if let listed = manifest?.version, let mine = have[board],
               FirmwareVersion.compare(listed, mine) <= 0 {
                result.notes.append("\(board.label) v\(listed): already in the app")
                continue
            }
            var app: Data? = nil
            if let url = assets[board.appFileName] {
                app = await download(url, limit: maxImageBytes)
            }
            if app == nil, let url = assets[board.mergedFileName],
               let merged = await download(url, limit: appOffset + maxImageBytes),
               merged.count > appOffset {
                app = Data(merged.dropFirst(appOffset))
            }
            guard let appData = app else {
                result.notes.append("\(board.label): not in the release")
                continue
            }
            if let expected = manifest?.appMd5[board], md5Hex(appData) != expected {
                result.notes.append("\(board.label): download damaged (checksum)")
                continue
            }
            guard let image = makeImage(from: appData, source: .web, board: board) else {
                result.notes.append("\(board.label): not a \(board.label) image with a version marker")
                continue
            }
            if let mine = have[board], FirmwareVersion.compare(image.version, mine) <= 0 {
                result.notes.append("\(board.label) v\(image.version): already in the app")
                continue
            }
            result.images.append(image)
            cacheIfNewer(image)
        }
        return result
    }

    /// name -> download URL of every asset of a release.
    private static func releaseAssets(_ body: Data) -> [String: URL] {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let json = object as? [String: Any],
              let list = json["assets"] as? [[String: Any]] else {
            return [:]
        }
        var out: [String: URL] = [:]
        for asset in list {
            guard let name = asset["name"] as? String,
                  let link = asset["browser_download_url"] as? String,
                  let url = URL(string: link) else {
                continue
            }
            out[name] = url
        }
        return out
    }

    /// One release file (GitHub redirects to its storage host; URLSession follows). nil on any
    /// error or when it is larger than `limit` bytes.
    private static func download(_ url: URL, limit: Int) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let reply: (Data, URLResponse)
        do {
            reply = try await URLSession.shared.data(for: request)
        } catch {
            return nil
        }
        let data: Data = reply.0
        guard (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard !data.isEmpty, data.count <= limit else { return nil }
        return data
    }
}

/// The newest image the app has for each board: bundled, or downloaded from the web and cached.
/// Works offline with the bundled images; CHECK WEB looks for newer ones.
@MainActor
final class FirmwareCatalog: ObservableObject {
    /// The newest image per board.
    @Published private(set) var images: [FirmwareBoard: FirmwareImage] = [:]
    @Published private(set) var isCheckingWeb: Bool = false
    /// The outcome of the last web check ("" before the first).
    @Published private(set) var webStatus: String = ""
    @Published private(set) var loaded: Bool = false
    private var loadStarted: Bool = false

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init() {}

    func newest(for board: FirmwareBoard) -> FirmwareImage? {
        images[board]
    }

    /// Reads the bundled and cached images once (off the main actor).
    func loadIfNeeded() {
        if loadStarted { return }
        loadStarted = true
        Task { [weak self] in
            let found: [FirmwareImage] = await Task.detached(priority: .utility) { () -> [FirmwareImage] in
                FirmwareFiles.bundledImages() + FirmwareFiles.cachedImages()
            }.value
            self?.adopt(found)
            self?.loaded = true
        }
    }

    /// Looks for newer images in the GitHub release.
    func checkWeb() {
        if isCheckingWeb { return }
        isCheckingWeb = true
        webStatus = "Checking GitHub…"
        // Only a version newer than these is downloaded.
        let have: [FirmwareBoard: String] = images.mapValues { (image: FirmwareImage) -> String in image.version }
        Task { [weak self] in
            let result: FirmwareWebResult = await FirmwareFiles.fetchLatest(have: have)
            self?.finishWebCheck(result)
        }
    }

    /// Keeps the newest per board; on a tie the image already held stays.
    private func adopt(_ found: [FirmwareImage]) {
        var next: [FirmwareBoard: FirmwareImage] = images
        for image in found {
            if let current = next[image.board], FirmwareVersion.compare(image.version, current.version) <= 0 {
                continue
            }
            next[image.board] = image
        }
        images = next
    }

    private func finishWebCheck(_ result: FirmwareWebResult) {
        isCheckingWeb = false
        adopt(result.images)
        let time: String = Self.clock.string(from: Date())
        if let error = result.error {
            webStatus = "Web check failed (\(time)): \(error)"
            return
        }
        var parts: [String] = []
        for board in FirmwareBoard.allCases {
            if let image = result.images.first(where: { (item: FirmwareImage) -> Bool in item.board == board }) {
                parts.append("\(board.label) v\(image.version) downloaded")
            }
        }
        parts.append(contentsOf: result.notes)
        let found: String = parts.isEmpty ? "nothing usable" : parts.joined(separator: " · ")
        webStatus = "Web (\(time)): " + found
    }
}
