@_spi(Checks) import Core
import Darwin
import Foundation

/// Gregorian calendar in Asia/Kolkata, the zone every check uses.
func checkCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    return calendar
}

/// Whole-second date in Asia/Kolkata. Whole seconds matter because session.json stores ISO-8601 without fractions.
func checkDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
    return checkCalendar().date(from: components)!
}

/// Callers remove it with `defer`.
func checkMakeDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("corechecks-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func checkRemoveDirectory(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        FileHandle.standardError.write(Data("WARN cleanup failed for \(url.path): \(error)\n".utf8))
    }
}

func checkWrite(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func checkRead(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return String(decoding: data, as: UTF8.self)
}

/// The marker line exactly as the format writes it: lowercase UUID.
func checkMarker(_ id: UUID) -> String {
    CaptureFormat.markerPrefix + id.uuidString.lowercased() + CaptureFormat.markerSuffix
}

/// The typed-note marker up to its timestamp, as the format writes it.
func checkNoteMarker(_ id: UUID) -> String {
    CaptureFormat.noteMarkerPrefix + id.uuidString.lowercased() + CaptureFormat.markerStampKey
}

func checkKindName(_ kind: NoteKind) -> String {
    switch kind {
    case .inbox:
        return "inbox"
    case .session:
        return "session"
    case .note:
        return "note"
    }
}

/// Identity prefix works for both legacy and metadata-bearing capture markers.
func checkCaptureMarker(_ id: UUID) -> String {
    CaptureFormat.markerPrefix + id.uuidString.lowercased()
}

/// Number of non-overlapping occurrences of `needle` in `text`.
func checkCount(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

func checkSkip(_ reason: String) {
    print("SKIP \(reason)")
}

/// Passes only when `operation` throws an error that `matching` accepts. Success, or any other error, fails the check.
func expectRejection<T>(_ message: String, matching: (any Error) -> Bool, _ operation: () throws -> T) throws {
    do {
        _ = try operation()
    } catch let failure as CheckFailure {
        throw failure
    } catch let error where matching(error) {
        return
    } catch {
        throw CheckFailure.failed("\(message): unexpected error \(error)")
    }
    throw CheckFailure.failed("\(message): expected a rejection, but it succeeded")
}

func expectRejection<T>(_ message: String, matching: (any Error) -> Bool, _ operation: () async throws -> T) async throws {
    do {
        _ = try await operation()
    } catch let failure as CheckFailure {
        throw failure
    } catch let error where matching(error) {
        return
    } catch {
        throw CheckFailure.failed("\(message): unexpected error \(error)")
    }
    throw CheckFailure.failed("\(message): expected a rejection, but it succeeded")
}

func isPOSIX(_ code: POSIXErrorCode) -> (any Error) -> Bool {
    { ($0 as? POSIXError)?.code == code }
}

/// Polls `condition` until it holds. The condition is checked once more after the deadline before failing.
func waitUntil(_ message: String, timeout: TimeInterval, poll: TimeInterval = 0.01, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            throw CheckFailure.failed("\(message) (timed out after \(timeout) s)")
        }
        try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
    }
}

func waitUntil(_ message: String, timeout: TimeInterval, poll: TimeInterval = 0.01, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            throw CheckFailure.failed("\(message) (timed out after \(timeout) s)")
        }
        Thread.sleep(forTimeInterval: poll)
    }
}

/// Exclusive flock on a note, held for the length of a check so a background writer parks on it.
final class CheckFileLock {
    private let descriptor: Int32
    private var held = false
    private var closed = false

    init(_ url: URL) throws {
        descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CheckFailure.failed("could not open the lock fixture")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            Darwin.close(descriptor)
            throw CheckFailure.failed("could not lock the fixture note")
        }
        held = true
    }

    func release() {
        guard held else { return }
        held = false
        _ = flock(descriptor, LOCK_UN)
    }

    func close() {
        guard !closed else { return }
        release()
        closed = true
        Darwin.close(descriptor)
    }

    /// Waits until another descriptor in this process refers to the same inode, which means a background
    /// save has opened the note and queued on this flock.
    func waitForQueuedWriter(timeout: TimeInterval = 5) async throws {
        var target = stat()
        let identified = fstat(descriptor, &target) == 0
        try await waitUntil("a background writer never queued on the lock", timeout: timeout) {
            guard identified else { return false }
            for other in 0..<min(getdtablesize(), 4096) where other != descriptor {
                var candidate = stat()
                if fstat(other, &candidate) == 0, candidate.st_dev == target.st_dev, candidate.st_ino == target.st_ino { return true }
            }
            return false
        }
    }
}

/// Records vault changes from a watcher callback so checks can wait on them from another thread.
final class CheckChangeRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var recorded: [VaultChange] = []

    func append(_ change: VaultChange) {
        condition.lock()
        recorded.append(change)
        condition.broadcast()
        condition.unlock()
    }

    func changes() -> [VaultChange] {
        condition.lock()
        defer { condition.unlock() }
        return recorded
    }

    func waitForChange(after offset: Int = 0, timeout: TimeInterval,
                       matching predicate: (VaultChange) -> Bool) -> VaultChange? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while let change = recorded.dropFirst(offset).first(where: predicate) {
            return change
        }
        while condition.wait(until: deadline) {
            if let change = recorded.dropFirst(offset).first(where: predicate) {
                return change
            }
        }
        return nil
    }

    func waitForQuiet(for interval: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let initialCount = recorded.count
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            guard condition.wait(until: deadline) else { break }
            if recorded.count != initialCount { return false }
        }
        return recorded.count == initialCount
    }
}
