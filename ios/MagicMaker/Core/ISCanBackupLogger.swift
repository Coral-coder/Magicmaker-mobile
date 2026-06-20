import Foundation

/// Saves raw iPhone backup scan lines to Documents/iscan_backup/*.csv (visible in Files app).
final class ISCanBackupLogger {
    static let shared = ISCanBackupLogger()

    /// Shown in UI — path inside the Files app.
    static let filesAppPath = "On My iPhone → MagicMaker → iscan_backup"

    private(set) var isLogging = false
    private(set) var sessionURL: URL?
    private var fileHandle: FileHandle?

    private var backupDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("iscan_backup", isDirectory: true)
    }

    func startSession() -> String {
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let name = "iscan_\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).csv"
        let url = backupDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("timestamp_ms,hex,rssi\n".utf8))
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        sessionURL = url
        isLogging = true
        return name
    }

    func append(hex: String, rssi: Int) {
        guard isLogging, let fileHandle else { return }
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let line = "\(ts),\(HexUtils.canonicalHex(hex)),\(rssi)\n"
        if let data = line.data(using: .utf8) {
            fileHandle.write(data)
            try? fileHandle.synchronize()
        }
    }

    func stopSession() -> String? {
        isLogging = false
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        let name = sessionURL?.lastPathComponent
        sessionURL = nil
        return name
    }

    func listSessions() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "csv" }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) } ?? []
    }
}
