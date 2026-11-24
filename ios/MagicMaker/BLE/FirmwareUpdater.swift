import Combine
import CryptoKit
import Foundation
import UIKit

/// Firmware updates over Bluetooth for the linked ESP32 transmitter (firmware 1.2+), on the relay
/// link's OTA characteristic (A7830007; protocol in firmware/esp32-transmitter/ota.h):
///
///   app -> board  01 BEGIN [u32 size][16-byte MD5] · 02 DATA [u32 offset][bytes] · 03 END ·
///                 04 ABORT · 05 QUERY
///   board -> app  [0x80 | op][status][u32 value][text]   (notify; all integers little-endian)
///
/// QUERY answers "MMFW:<version>:<board>;s=<state>;o=<offset>;n=<size>" with the seconds left in
/// the button-armed window as its value: the board only takes an update for 120 s after PRG
/// (Heltec V3) / BOOT (classic ESP32) is pressed. BEGIN, END, ABORT and QUERY are written with
/// response, DATA without (chunks of the link's largest write minus the 5-byte header). During
/// DATA the board acks with OK every 4096 bytes and at the end; the app keeps at most `window`
/// bytes beyond the last ack in flight and carries on from the board's offset after an
/// ERR_OFFSET. After END the board checks the image and restarts into it about 1.5 s later; the
/// link drops, the app links again on its own and asks again to confirm the new version.
///
/// While a transfer runs, transmits, relay commands and status reads are refused (the client's
/// `otaBusy`), the local scan pauses (`onBusyChanged`) and the screen stays awake
/// (`holdsScreen`).
@MainActor
final class FirmwareUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Asked the board which firmware it runs, to pick the image.
        case querying
        /// Waiting for PRG / BOOT on the board (QUERY polled every second).
        case waitingForButton
        /// BEGIN sent.
        case starting
        /// DATA streaming.
        case sending
        /// END sent: the board is checking the image.
        case finishing
        /// The board is restarting into the new image; waiting for it to link again.
        case restarting
        case succeeded
        case failed
    }

    /// The board's last QUERY reply.
    struct BoardInfo: Equatable {
        var version: String
        var board: FirmwareBoard
        /// 0 idle, 1 receiving, 2 done, 3 error.
        var state: Int
        var offset: Int
        var size: Int
    }

    /// What both SETTINGS screens show in BOARD FIRMWARE.
    struct Summary {
        var boardText: String
        var boardAlarm: Bool
        /// (key, value) rows: the image for the linked board, or every board's when none is linked.
        var available: [(key: String, value: String)]
        var webText: String
        var checkingWeb: Bool
        var actionTitle: String
        var actionEnabled: Bool
        /// Not newer than what the board runs: ask before installing.
        var confirmMessage: String?
        var instruction: String
        var instructionIsPrompt: Bool
        var showsProgress: Bool
        var progress: Double
        var progressText: String
        var resultText: String
        var resultIsError: Bool
        var canCancel: Bool
        /// A transfer holds the link (CHECK WEB waits).
        var busy: Bool
    }

    private enum Op {
        static let begin: UInt8 = 0x01
        static let data: UInt8 = 0x02
        static let end: UInt8 = 0x03
        static let abort: UInt8 = 0x04
        static let query: UInt8 = 0x05
    }

    private enum Status {
        static let ok: UInt8 = 0
        static let notArmed: UInt8 = 1
        static let offset: UInt8 = 4
    }

    /// Bytes allowed in flight beyond the board's last ack.
    private static let window: Int = 16 * 1024
    /// One GATT value carries at most 512 bytes: the DATA payload is at most 512 - 5.
    private static let maxChunk: Int = 512 - 5

    let catalog: FirmwareCatalog

    @Published private(set) var phase: Phase = .idle
    /// The linked board's last QUERY reply (nil while not linked or not asked yet).
    @Published private(set) var board: BoardInfo?
    /// The OTA characteristic is linked with its notifications on.
    @Published private(set) var otaReady: Bool = false
    /// Seconds left in the board's button-armed window (last QUERY).
    @Published private(set) var armedSeconds: Int = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var resultText: String = ""
    @Published private(set) var resultIsError: Bool = false
    /// The image being installed (or last installed).
    @Published private(set) var target: FirmwareImage?

    /// A transfer started (true) or ended (false): the app pauses its own radio work meanwhile.
    var onBusyChanged: ((Bool) -> Void)?
    /// `holdsScreen` changed: the app's idle-timer owner (TxEngine.refreshIdleTimer) applies it.
    /// Without one the updater sets UIApplication.isIdleTimerDisabled itself.
    var onScreenHoldChanged: (() -> Void)?
    /// The screen should stay on: from the button prompt until the update has ended.
    private(set) var holdsScreen: Bool = false

    private weak var client: AndroidRelayGattClient?
    private var catalogChanges: AnyCancellable?
    private var busy: Bool = false
    private var bytes: [UInt8] = []
    private var md5: [UInt8] = []
    private var chunkSize: Int = 180
    private var nextOffset: Int = 0
    private var ackedOffset: Int = 0
    /// The offset of the last ERR_OFFSET resend; repeats of it answer packets sent before it.
    private var rewindOffset: Int = -1
    private var phaseStartedAt: Date = Date()
    private var transferStartedAt: Date = Date()
    private var lastProgressAt: Date = Date()
    private var lastQueryAt: Date = .distantPast
    private var lastPublishAt: Date = .distantPast
    private var sawLinkDrop: Bool = false
    private var ticker: Task<Void, Never>?
    private var screenWasHeld: Bool = false

    init() {
        let catalog = FirmwareCatalog()
        self.catalog = catalog
        catalogChanges = catalog.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Wires the relay link (once, after Bluetooth starts). The client calls back on the main
    /// queue (its central runs there).
    func attach(to client: AndroidRelayGattClient) {
        self.client = client
        client.onOtaNotify = { [weak self] data in
            self?.handleNotify(data)
        }
        client.onOtaLinkChanged = { [weak self] up in
            // A turn later: the client is mid-way through its own link bookkeeping.
            Task { @MainActor [weak self] in
                self?.linkChanged(up)
            }
        }
        client.onOtaWriteReady = { [weak self] in
            self?.pump()
        }
        client.onOtaWriteResult = { [weak self] error in
            self?.writeFinished(error)
        }
        if client.isOtaReady {
            linkChanged(true)
        }
    }

    /// A transfer holds the link (BEGIN until END is answered or the update ended).
    var isBusy: Bool { busy }

    /// UPDATE (or REINSTALL): asks for the button press, then installs the newest image for the
    /// linked board.
    func startUpdate() {
        switch phase {
        case .idle, .succeeded, .failed:
            break
        default:
            return
        }
        resultText = ""
        resultIsError = false
        progress = 0
        bytesPerSecond = 0
        guard client?.isOtaReady == true else {
            fail("Link the ESP32 first (LINK tab, ESP32 backend), then tap UPDATE.")
            return
        }
        if board == nil {
            setPhase(.querying)
            sendQuery()
            return
        }
        prepareAndWait()
    }

    /// CANCEL: before END only; a started transfer is aborted on the board too.
    func cancel() {
        switch phase {
        case .querying, .waitingForButton:
            finish(.idle, "Update cancelled.", error: false)
        case .starting, .sending:
            client?.otaWrite(Data([Op.abort]), withResponse: true)
            finish(.idle, "Update cancelled — the board keeps its current firmware.", error: false)
        default:
            break
        }
    }

    var canCancel: Bool {
        switch phase {
        case .querying, .waitingForButton, .starting, .sending:
            return true
        default:
            return false
        }
    }

    // MARK: Flow

    private func prepareAndWait() {
        guard let info = board else {
            fail("The board did not say which firmware it runs.")
            return
        }
        // Catalog images are filed under their own marker's board, so this is an image built
        // for the board that answered QUERY.
        guard let image = catalog.newest(for: info.board), image.board == info.board else {
            fail("No \(info.board.label) firmware in the app — tap CHECK WEB.")
            return
        }
        target = image
        bytes = [UInt8](image.data)
        md5 = Array(Insecure.MD5.hash(data: image.data))
        armedSeconds = 0
        setPhase(.waitingForButton)
        holdScreen(true)
        sendQuery()
    }

    private func sendQuery() {
        guard let client, client.isOtaReady else { return }
        lastQueryAt = Date()
        client.otaWrite(Data([Op.query]), withResponse: true)
    }

    private func sendBegin() {
        guard let client, client.isOtaReady, !bytes.isEmpty, md5.count == 16 else {
            fail("The ESP32 link dropped — link it again, then tap UPDATE.")
            return
        }
        setBusy(true)
        setPhase(.starting)
        var payload: [UInt8] = [Op.begin]
        Self.appendU32(&payload, bytes.count)
        payload.append(contentsOf: md5)
        if !client.otaWrite(Data(payload), withResponse: true) {
            fail("The ESP32 link dropped — link it again, then tap UPDATE.")
        }
    }

    /// Streams DATA while CoreBluetooth takes it and the window allows; called again when
    /// CoreBluetooth has room, on every ack and after a resend point.
    private func pump() {
        guard phase == .sending, let client else { return }
        let total: Int = bytes.count
        while nextOffset < total && nextOffset - ackedOffset < Self.window {
            if !client.otaCanSendWithoutResponse { return }
            let end: Int = min(nextOffset + chunkSize, total)
            var packet: [UInt8] = [Op.data]
            packet.reserveCapacity(5 + end - nextOffset)
            Self.appendU32(&packet, nextOffset)
            packet.append(contentsOf: bytes[nextOffset..<end])
            if !client.otaWrite(Data(packet), withResponse: false) { return }
            nextOffset = end
        }
    }

    /// Carry on from what the board holds. Not progress by itself (`lastProgressAt` moves only
    /// when the board acks more), so a board that keeps losing the same bytes still times out.
    private func resend(from offset: Int) {
        rewindOffset = offset
        nextOffset = offset
        ackedOffset = offset
        pump()
    }

    private func sendEnd() {
        guard let client else { return }
        ackedOffset = bytes.count
        publishProgress(force: true)
        sawLinkDrop = false
        setPhase(.finishing)
        if !client.otaWrite(Data([Op.end]), withResponse: true) {
            fail("The ESP32 link dropped before the update finished — the board keeps its current firmware.")
        }
    }

    /// END was answered (or the board restarted before its answer came): the transfer no longer
    /// holds the link, which drops when the board restarts and comes back by itself.
    private func awaitRestart() {
        setBusy(false)
        setPhase(.restarting)
    }

    // MARK: Board replies

    private func handleNotify(_ data: Data) {
        let b: [UInt8] = [UInt8](data)
        guard b.count >= 6, (b[0] & 0x80) != 0 else { return }
        let op: UInt8 = b[0] & 0x7F
        let status: UInt8 = b[1]
        var raw: UInt32 = UInt32(b[2])
        raw |= UInt32(b[3]) << 8
        raw |= UInt32(b[4]) << 16
        raw |= UInt32(b[5]) << 24
        let value: Int = Int(raw)
        let text: String = b.count > 6 ? String(decoding: b[6...], as: UTF8.self) : ""
        switch op {
        case Op.query:
            queryReply(status, value, text)
        case Op.begin:
            beginReply(status)
        case Op.data:
            dataReply(status, value)
        case Op.end:
            endReply(status)
        default:
            // ABORT's reply needs nothing.
            break
        }
    }

    private func queryReply(_ status: UInt8, _ armed: Int, _ text: String) {
        guard status == Status.ok, let info = Self.parseQuery(text) else { return }
        if board != info { board = info }
        if armedSeconds != armed { armedSeconds = armed }
        switch phase {
        case .querying:
            prepareAndWait()
        case .waitingForButton:
            if let target, target.board != info.board {
                fail("The board is a \(info.board.label), not a \(target.board.label) — nothing sent.")
            } else if armed > 0 {
                sendBegin()
            }
        case .sending:
            // Asked because the acks stopped: carry on from where the board is.
            guard info.state == 1 else {
                fail("The board dropped the update — it keeps its current firmware. Try again.")
                return
            }
            let held: Int = min(info.offset, bytes.count)
            let stalled: Bool = Date().timeIntervalSince(lastProgressAt) > 4
            if held > ackedOffset {
                ackedOffset = held
                lastProgressAt = Date()
                publishProgress(force: false)
            }
            if ackedOffset >= bytes.count {
                sendEnd()
            } else if stalled && held < nextOffset {
                resend(from: held)
            } else {
                pump()
            }
        case .restarting:
            // A reply from before the restart still shows state 2 (done).
            if !sawLinkDrop && info.state == 2 { return }
            verifyAfterRestart(info)
        default:
            break
        }
    }

    private func beginReply(_ status: UInt8) {
        guard phase == .starting else { return }
        if status == Status.ok {
            let maxWrite: Int = client?.otaMaxWriteWithoutResponse ?? 20
            chunkSize = max(16, min(maxWrite - 5, Self.maxChunk))
            nextOffset = 0
            ackedOffset = 0
            rewindOffset = -1
            transferStartedAt = Date()
            lastProgressAt = Date()
            setPhase(.sending)
            publishProgress(force: true)
            pump()
            return
        }
        if status == Status.notArmed {
            // The window closed between the last QUERY and BEGIN.
            setBusy(false)
            armedSeconds = 0
            setPhase(.waitingForButton)
            sendQuery()
            return
        }
        fail("The board refused the update: \(Self.statusText(status)).")
    }

    private func dataReply(_ status: UInt8, _ value: Int) {
        guard phase == .sending else { return }
        if status == Status.ok {
            if value > ackedOffset {
                ackedOffset = min(value, bytes.count)
                lastProgressAt = Date()
                publishProgress(force: false)
            }
            // Past the last resend point: a new ERR_OFFSET there is a new gap.
            if value > rewindOffset { rewindOffset = -1 }
            if ackedOffset >= bytes.count {
                sendEnd()
            } else {
                pump()
            }
            return
        }
        if status == Status.offset {
            // One ERR_OFFSET per packet that was in flight: act on the first only.
            if value == rewindOffset { return }
            guard value <= bytes.count else {
                fail("The board lost its place in the update — it keeps its current firmware. Try again.")
                return
            }
            resend(from: value)
            return
        }
        fail("The update stopped: \(Self.statusText(status)). The board keeps its current firmware.")
    }

    private func endReply(_ status: UInt8) {
        guard phase == .finishing else { return }
        if status == Status.ok {
            awaitRestart()
            return
        }
        fail("The board rejected the new firmware: \(Self.statusText(status)). It keeps its current firmware.")
    }

    private func verifyAfterRestart(_ info: BoardInfo) {
        // Only BEGIN sets the size the board reports, and it is 0 after a boot: a size means the
        // board did not restart (END never took, or the link dropped before it), whatever version
        // it reports, so a reinstall of the same version is not taken for a success.
        if info.size != 0 {
            if info.state == 1 {
                // Still holding the transfer: drop it.
                client?.otaWrite(Data([Op.abort]), withResponse: true)
            }
            fail("The board did not restart into the new firmware — it still runs v\(info.version). Try again.")
            return
        }
        guard let target else {
            finish(.succeeded, "The board restarted on v\(info.version).", error: false)
            return
        }
        if info.board == target.board && FirmwareVersion.compare(info.version, target.version) == 0 {
            finish(.succeeded, "Updated — the \(info.board.label) now runs v\(info.version).", error: false)
        } else {
            fail("The board restarted but still runs v\(info.version) — the update did not take. Try again.")
        }
    }

    private func linkChanged(_ up: Bool) {
        let ready: Bool = up && (client?.isOtaReady ?? false)
        if otaReady != ready { otaReady = ready }
        if ready {
            switch phase {
            case .idle, .succeeded, .failed, .querying, .restarting:
                sendQuery()
            default:
                break
            }
            return
        }
        if up { return }
        switch phase {
        case .querying, .waitingForButton:
            fail("The ESP32 link dropped — link it again, then tap UPDATE.")
        case .starting, .sending:
            fail("The Bluetooth link dropped during the update — the board drops the partial image and keeps its current firmware. Link it again and retry.")
        case .finishing:
            // END may have gone through and the board restarted before its reply came back.
            sawLinkDrop = true
            awaitRestart()
        case .restarting:
            sawLinkDrop = true
        default:
            break
        }
        if phase != .restarting && board != nil { board = nil }
    }

    private func writeFinished(_ error: Error?) {
        guard let error else { return }
        switch phase {
        case .starting:
            fail("Bluetooth write failed: \(error.localizedDescription)")
        case .finishing:
            fail("Bluetooth write failed before the update finished: \(error.localizedDescription)")
        default:
            // A QUERY that did not go out is asked again by the ticker.
            break
        }
    }

    // MARK: Ticker (timeouts, button polling, stall check, progress)

    private func tick() {
        let now: Date = Date()
        let inPhase: TimeInterval = now.timeIntervalSince(phaseStartedAt)
        let sinceQuery: TimeInterval = now.timeIntervalSince(lastQueryAt)
        switch phase {
        case .querying:
            if inPhase > 8 {
                // Only reached with the update characteristic linked, so the firmware has updates.
                fail("The board did not say which firmware it runs — link it again, then tap UPDATE.")
            } else if sinceQuery > 2 {
                sendQuery()
            }
        case .waitingForButton:
            if inPhase > 180 {
                let button: String = target?.board.buttonName ?? "PRG / BOOT"
                fail("\(button) was not pressed — tap UPDATE to try again.")
            } else if sinceQuery >= 1 {
                sendQuery()
            }
        case .starting:
            if inPhase > 12 {
                fail("The board did not start the update — try again.")
            }
        case .sending:
            publishProgress(force: false)
            let quiet: TimeInterval = now.timeIntervalSince(lastProgressAt)
            if quiet > 25 {
                fail("The board stopped answering during the update — it keeps its current firmware. Try again.")
            } else if quiet > 4 && sinceQuery > 3 {
                sendQuery()
            }
        case .finishing:
            if inPhase > 20 {
                // No answer to END: find out after the restart what the board runs.
                awaitRestart()
            }
        case .restarting:
            if inPhase > 90 {
                fail("The board did not come back after restarting — power-cycle it, then check its version here.")
            } else if otaReady && sinceQuery > 3 {
                sendQuery()
            }
        case .idle, .succeeded, .failed:
            stopTicker()
        }
    }

    private func startTicker() {
        if ticker != nil { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: State

    private func setPhase(_ next: Phase) {
        phase = next
        phaseStartedAt = Date()
        switch next {
        case .idle, .succeeded, .failed:
            break
        default:
            startTicker()
        }
    }

    private func fail(_ message: String) {
        switch phase {
        case .starting, .sending:
            // Drop what the board has taken so far (it also drops it when the link goes).
            client?.otaWrite(Data([Op.abort]), withResponse: true)
        default:
            break
        }
        finish(.failed, message, error: true)
    }

    private func finish(_ next: Phase, _ message: String, error: Bool) {
        setPhase(next)
        resultText = message
        resultIsError = error
        bytesPerSecond = 0
        bytes = []
        md5 = []
        stopTicker()
        setBusy(false)
        holdScreen(false)
        // What the board runs now.
        if otaReady { sendQuery() }
    }

    private func setBusy(_ on: Bool) {
        if busy == on { return }
        busy = on
        client?.otaBusy = on
        onBusyChanged?(on)
    }

    /// Keeps the screen on from the button prompt until the update ends.
    private func holdScreen(_ on: Bool) {
        if holdsScreen == on { return }
        holdsScreen = on
        if let apply = onScreenHoldChanged {
            apply()
            return
        }
        if on {
            screenWasHeld = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            UIApplication.shared.isIdleTimerDisabled = screenWasHeld
        }
    }

    private func publishProgress(force: Bool) {
        let now: Date = Date()
        if !force && now.timeIntervalSince(lastPublishAt) < 0.25 { return }
        lastPublishAt = now
        let total: Int = max(1, bytes.count)
        let next: Double = min(1, Double(ackedOffset) / Double(total))
        if progress != next { progress = next }
        let elapsed: TimeInterval = now.timeIntervalSince(transferStartedAt)
        let rate: Double = elapsed > 0.5 ? Double(ackedOffset) / elapsed : 0
        if bytesPerSecond != rate { bytesPerSecond = rate }
    }

    // MARK: Helpers

    private static func appendU32(_ out: inout [UInt8], _ value: Int) {
        let v: UInt32 = UInt32(truncatingIfNeeded: value)
        out.append(UInt8(truncatingIfNeeded: v))
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v >> 16))
        out.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    /// "MMFW:<version>:<board>;s=<state>;o=<offset>;n=<size>".
    static func parseQuery(_ text: String) -> BoardInfo? {
        let fields: [String] = text.split(separator: ";").map { (part: Substring) -> String in String(part) }
        guard let first = fields.first, let marker = FirmwareMarker.parse(first) else { return nil }
        var info = BoardInfo(version: marker.version, board: marker.board, state: 0, offset: 0, size: 0)
        for field in fields.dropFirst() {
            let pair: [String] = field.split(separator: "=", maxSplits: 1).map { (part: Substring) -> String in String(part) }
            guard pair.count == 2, let n = Int(pair[1]) else { continue }
            switch pair[0] {
            case "s": info.state = n
            case "o": info.offset = n
            case "n": info.size = n
            default: break
            }
        }
        return info
    }

    /// Every status code of ota.h, in words.
    static func statusText(_ status: UInt8) -> String {
        switch status {
        case 0: return "OK"
        case 1: return "the button window is closed (press PRG on the Heltec, BOOT on a classic ESP32, and try again)"
        case 2: return "the image size does not fit this board"
        case 3: return "the board could not open its update slot"
        case 4: return "data arrived out of order"
        case 5: return "the board could not write its flash"
        case 6: return "the image failed the board's checks (checksum, format or chip)"
        case 7: return "the board was not expecting that step"
        case 8: return "the board did not understand the request"
        default: return "error \(status)"
        }
    }

    // MARK: Summary for the SETTINGS screens

    /// `linked`: the ESP32 is the selected backend and its relay link takes commands.
    func summary(linked: Bool) -> Summary {
        let hasOta: Bool = linked && (client?.hasOtaCharacteristic ?? false)
        var boardText: String = "NOT LINKED TO THE ESP32"
        var boardAlarm: Bool = false
        if let info = board {
            boardText = "\(info.board.label) · v\(info.version)"
        } else if phase == .restarting {
            boardText = "RESTARTING…"
        } else if hasOta {
            boardText = "LINKED · ASKING…"
        } else if linked {
            boardText = "FIRMWARE BEFORE 1.2"
            boardAlarm = true
        }

        var available: [(key: String, value: String)] = []
        let image: FirmwareImage? = board.flatMap { (info: BoardInfo) -> FirmwareImage? in catalog.newest(for: info.board) }
        if let info = board {
            if let image {
                available.append((key: "AVAILABLE", value: "v\(image.version) · \(image.source.label)"))
            } else {
                available.append((key: "AVAILABLE", value: catalog.loaded ? "NONE FOR \(info.board.label)" : "…"))
            }
        } else {
            for kind in FirmwareBoard.allCases {
                if let item = catalog.newest(for: kind) {
                    available.append((key: kind.label, value: "v\(item.version) · \(item.source.label)"))
                } else {
                    available.append((key: kind.label, value: catalog.loaded ? "NONE" : "…"))
                }
            }
        }

        var actionTitle: String = "UPDATE"
        var confirmMessage: String? = nil
        if let info = board, let image {
            let order: Int = FirmwareVersion.compare(image.version, info.version)
            if order > 0 {
                actionTitle = "UPDATE TO v\(image.version)"
            } else if order == 0 {
                actionTitle = "REINSTALL v\(image.version)"
                confirmMessage = "The \(info.board.label) already runs v\(info.version). Install it again?"
            } else {
                actionTitle = "INSTALL OLDER v\(image.version)"
                confirmMessage = "The \(info.board.label) runs v\(info.version), newer than v\(image.version). Install the older firmware?"
            }
        }
        let idle: Bool = phase == .idle || phase == .succeeded || phase == .failed
        let actionEnabled: Bool = idle && linked && otaReady && board != nil && image != nil

        var instruction: String = ""
        var prompt: Bool = false
        let kind: FirmwareBoard? = board?.board ?? target?.board
        let version: String = target?.version ?? ""
        switch phase {
        case .querying:
            instruction = "Asking the board which firmware it runs…"
        case .waitingForButton:
            let named: String
            if let kind {
                named = "Press \(kind.buttonName) on the \(kind.boardName) now"
            } else {
                named = "Press the board's button now"
            }
            instruction = named + " (PRG on the Heltec, BOOT on a classic ESP32). The update starts by itself."
            prompt = true
        case .starting:
            instruction = "Starting the update…"
        case .sending:
            instruction = "Sending v\(version) — keep the phone near the board and this screen open. Transmits are paused."
        case .finishing:
            instruction = "The board is checking the new firmware…"
        case .restarting:
            instruction = "The board is restarting into v\(version) — linking again…"
        case .idle, .succeeded, .failed:
            if hasOta {
                instruction = "UPDATE asks you to press PRG on the Heltec (BOOT on a classic ESP32): the board only takes an update for 2 minutes after a press."
            } else if linked {
                instruction = "This board's firmware has no Bluetooth updates. Flash 1.2 or newer once over USB (the web flasher, or flash.sh / flash.ps1 in firmware/esp32-transmitter); later updates come from here."
            } else {
                instruction = "Select ESP32 on LINK and power the board to see its firmware and update it."
            }
        }

        var showsProgress: Bool = false
        var progressText: String = ""
        var shownProgress: Double = 0
        switch phase {
        case .starting, .sending:
            showsProgress = true
            shownProgress = progress
            let percent: Int = Int((progress * 100).rounded(.down))
            let kbs: Double = bytesPerSecond / 1024
            progressText = kbs > 0 ? "\(percent)% · " + String(format: "%.1f KB/s", kbs) : "\(percent)%"
        case .finishing:
            showsProgress = true
            shownProgress = 1
            progressText = "100% · CHECKING"
        case .restarting:
            showsProgress = true
            shownProgress = 1
            progressText = "100% · RESTARTING"
        default:
            break
        }

        return Summary(
            boardText: boardText,
            boardAlarm: boardAlarm,
            available: available,
            webText: catalog.webStatus,
            checkingWeb: catalog.isCheckingWeb,
            actionTitle: actionTitle,
            actionEnabled: actionEnabled,
            confirmMessage: confirmMessage,
            instruction: instruction,
            instructionIsPrompt: prompt,
            showsProgress: showsProgress,
            progress: shownProgress,
            progressText: progressText,
            resultText: resultText,
            resultIsError: resultIsError,
            canCancel: canCancel,
            busy: busy
        )
    }
}
