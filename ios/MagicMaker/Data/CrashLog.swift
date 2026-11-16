import Foundation

/// Lightweight crash capture. Uncaught exceptions, fatal signals and the caught errors the app
/// deliberately swallows go to a small rolling file, so a crash leaves a trail instead of
/// vanishing. Never throws. Port of Android `core/CrashLog.kt`.
enum CrashLog {
    static let fileName = "crash_log.txt"
    /// Past this size the file is cut back to its newest half.
    static let maxBytes = 200 * 1024

    // Recursive, so an exception raised while an entry is being written can still be recorded.
    private static let lock = NSRecursiveLock()
    private static var installed = false
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    /// Documents/crash_log.txt, visible in the Files app.
    static var fileURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent(fileName)
    }

    /// Starts recording uncaught exceptions and fatal signals. Call once, first thing at launch.
    static func install() {
        lock.lock()
        if installed {
            lock.unlock()
            return
        }
        installed = true
        let ready = preparePathLocked() != nil
        if ready {
            trimLocked()
        }
        lock.unlock()
        guard ready else { return }

        // The handler that was there before still runs, after the entry is written.
        crashPreviousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(crashExceptionHandler)
        for sig in crashSignals {
            _ = signal(sig, crashSignalHandler)
        }
    }

    /// Appends one entry for an error that was caught and swallowed. Safe from any thread.
    static func record(_ error: Error, _ context: String = "") {
        let typeName = String(describing: type(of: error))
        let message = error.localizedDescription
        var body = "\(typeName): \(message)\n"
        let detail = String(describing: error)
        if !detail.isEmpty && detail != message {
            body += detail + "\n"
        }
        append(tag: context, body: body)
    }

    /// Appends a line of free text. Safe from any thread.
    static func note(_ text: String) {
        append(tag: "note", body: text + "\n")
    }

    /// The whole log, or "" when nothing has been recorded.
    static func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return "" }
        // Lenient decoding: trimming can cut through a multi-byte character.
        return String(decoding: data, as: UTF8.self)
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    fileprivate static func recordUncaught(_ exception: NSException) {
        let threadName = Thread.isMainThread ? "main" : (Thread.current.name ?? "")
        let reason = exception.reason ?? ""
        var body = "\(exception.name.rawValue): \(reason)\n"
        let frames = exception.callStackSymbols.prefix(40)
        if !frames.isEmpty {
            body += frames.joined(separator: "\n") + "\n"
        }
        let tag = threadName.isEmpty ? "UNCAUGHT" : "UNCAUGHT on \(threadName)"
        append(tag: tag, body: body)
    }

    private static func append(tag: String, body: String) {
        lock.lock()
        defer { lock.unlock() }
        guard preparePathLocked() != nil else { return }
        trimLocked()
        let stamp = stampFormatter.string(from: Date())
        let header: String
        if tag.isEmpty {
            header = "\n===== \(stamp) =====\n"
        } else {
            header = "\n===== \(stamp) · \(tag) =====\n"
        }
        crashAppend(Array((header + body).utf8))
    }

    /// The log's path as a C string, plus the buffer the signal handler writes with. Set up once
    /// and never freed.
    private static func preparePathLocked() -> UnsafeMutablePointer<CChar>? {
        let state = crashSignalState
        if let ready = state.pointee.path { return ready }
        guard let url = fileURL else { return nil }
        guard let cPath = strdup(url.path) else { return nil }
        let capacity = 160
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        scratch.initialize(repeating: 0, count: capacity)
        state.pointee.scratch = scratch
        state.pointee.scratchCapacity = capacity
        state.pointee.utcOffsetSeconds = TimeZone.current.secondsFromGMT()
        state.pointee.path = cPath
        return cPath
    }

    /// Keeps the newest half once the file has passed `maxBytes`, starting on a line boundary.
    private static func trimLocked() {
        guard let url = fileURL else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if size <= maxBytes { return }
        guard let data = try? Data(contentsOf: url) else { return }
        var kept = [UInt8](data.suffix(maxBytes / 2))
        if let newline = kept.firstIndex(of: 0x0A) {
            kept.removeFirst(newline + 1)
        }
        try? Data(kept).write(to: url, options: .atomic)
    }
}

// MARK: - Uncaught exceptions

private var crashPreviousExceptionHandler: (@convention(c) (NSException) -> Void)? = nil

private func crashExceptionHandler(_ exception: NSException) {
    CrashLog.recordUncaught(exception)
    crashPreviousExceptionHandler?(exception)
}

// MARK: - Fatal signals
//
// A signal handler may interrupt the app anywhere, including inside malloc or the Swift runtime,
// so it must not allocate or touch any Swift or Foundation object. Everything it needs is plain
// memory prepared ahead of time, and it only calls open, write, close, time, signal and raise.

private let crashSignals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP]

private struct CrashSignalState {
    var path: UnsafeMutablePointer<CChar>? = nil
    var scratch: UnsafeMutablePointer<UInt8>? = nil
    var scratchCapacity: Int = 0
    var utcOffsetSeconds: Int = 0
    var handling: Bool = false
}

private let crashSignalState: UnsafeMutablePointer<CrashSignalState> = {
    let state = UnsafeMutablePointer<CrashSignalState>.allocate(capacity: 1)
    state.initialize(to: CrashSignalState())
    return state
}()

/// Appends bytes with the same plain file calls the signal handler uses.
private func crashAppend(_ bytes: [UInt8]) {
    guard let path = crashSignalState.pointee.path else { return }
    if bytes.isEmpty { return }
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if fd < 0 { return }
    bytes.withUnsafeBufferPointer { pointer in
        if let base = pointer.baseAddress {
            _ = write(fd, base, pointer.count)
        }
    }
    _ = close(fd)
}

private func crashSignalHandler(_ sig: Int32) {
    let state = crashSignalState
    if !state.pointee.handling {
        state.pointee.handling = true
        if let path = state.pointee.path, let buffer = state.pointee.scratch {
            let capacity = state.pointee.scratchCapacity
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            if fd >= 0 {
                var count = 0
                count = crashPut("\n===== ", buffer, count, capacity)
                count = crashPutStamp(time(nil), state.pointee.utcOffsetSeconds, buffer, count, capacity)
                count = crashPut(" · SIGNAL ", buffer, count, capacity)
                count = crashPut(crashSignalName(sig), buffer, count, capacity)
                count = crashPut(" =====\nThe app was stopped by a fatal signal.\n", buffer, count, capacity)
                _ = write(fd, buffer, count)
                _ = close(fd)
            }
        }
    }
    // Hand the signal back to the system so the app still stops the normal way.
    _ = signal(sig, SIG_DFL)
    _ = raise(sig)
}

private func crashSignalName(_ sig: Int32) -> StaticString {
    switch sig {
    case SIGABRT:
        return "SIGABRT"
    case SIGILL:
        return "SIGILL"
    case SIGSEGV:
        return "SIGSEGV"
    case SIGFPE:
        return "SIGFPE"
    case SIGBUS:
        return "SIGBUS"
    case SIGTRAP:
        return "SIGTRAP"
    default:
        return "UNKNOWN"
    }
}

/// Copies a literal into the handler's buffer and returns the new length.
private func crashPut(_ text: StaticString, _ buffer: UnsafeMutablePointer<UInt8>, _ offset: Int, _ capacity: Int) -> Int {
    if !text.hasPointerRepresentation { return offset }
    let source = text.utf8Start
    let length = text.utf8CodeUnitCount
    var count = offset
    var index = 0
    while index < length && count < capacity {
        buffer[count] = source[index]
        index += 1
        count += 1
    }
    return count
}

private func crashPutByte(_ byte: UInt8, _ buffer: UnsafeMutablePointer<UInt8>, _ offset: Int, _ capacity: Int) -> Int {
    if offset >= capacity { return offset }
    buffer[offset] = byte
    return offset + 1
}

private func crashPutTwoDigits(_ value: Int, _ buffer: UnsafeMutablePointer<UInt8>, _ offset: Int, _ capacity: Int) -> Int {
    if offset + 2 > capacity { return offset }
    var clamped = value
    if clamped < 0 { clamped = 0 }
    if clamped > 99 { clamped = 99 }
    buffer[offset] = UInt8(truncatingIfNeeded: 48 + clamped / 10)
    buffer[offset + 1] = UInt8(truncatingIfNeeded: 48 + clamped % 10)
    return offset + 2
}

/// Writes "MM-dd HH:mm:ss" for a Unix time with integer arithmetic only (no date formatter can
/// be used in a signal handler). `utcOffset` is the local zone's offset, read at install time.
private func crashPutStamp(_ now: Int, _ utcOffset: Int, _ buffer: UnsafeMutablePointer<UInt8>, _ offset: Int, _ capacity: Int) -> Int {
    let local = now + utcOffset
    if now <= 0 || local <= 0 {
        return crashPut("unknown time", buffer, offset, capacity)
    }
    let days = local / 86_400
    let secondOfDay = local % 86_400
    // Days since 1970-01-01 to month and day of the Gregorian calendar.
    let shifted = days + 719_468
    let era = shifted / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthIndex = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
    let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
    let hour = secondOfDay / 3_600
    let minute = (secondOfDay % 3_600) / 60
    let second = secondOfDay % 60

    var count = offset
    count = crashPutTwoDigits(month, buffer, count, capacity)
    count = crashPutByte(0x2D, buffer, count, capacity)
    count = crashPutTwoDigits(day, buffer, count, capacity)
    count = crashPutByte(0x20, buffer, count, capacity)
    count = crashPutTwoDigits(hour, buffer, count, capacity)
    count = crashPutByte(0x3A, buffer, count, capacity)
    count = crashPutTwoDigits(minute, buffer, count, capacity)
    count = crashPutByte(0x3A, buffer, count, capacity)
    count = crashPutTwoDigits(second, buffer, count, capacity)
    return count
}
