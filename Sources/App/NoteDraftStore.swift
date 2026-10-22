import Foundation
import Core

struct NoteDraftSnapshot: Codable, Sendable {
    var text: String
    var pinOnSave: Bool
    var folder: NoteFolder? = nil
}

/// Text and pin intent share one atomic record. The lock also protects compare-and-clear
/// when a journal replay finishes while the main actor is accepting edits.
final class NoteDraftStore: @unchecked Sendable {
    private let lock = NSLock()
    /// Every draft mutation, including delayed editor writes, passes through this queue.
    /// A synchronous flush/clear is therefore ordered after an in-flight write.
    private let persistenceQueue = DispatchQueue(label: "note-draft-persistence", qos: .utility)
    /// Preserve ordering between concurrent synchronous store/flush/clear callers as they enqueue.
    private let mutationLock = NSLock()
    private let scheduleLock = NSLock()
    private var scheduleGeneration: UInt64 = 0
    private var pendingWrite: PendingWrite?
    private var scheduledWork: DispatchWorkItem?
    private var firstPendingAt: DispatchTime?
    private let debounceInterval: DispatchTimeInterval
    private let maxCoalescingInterval: DispatchTimeInterval
    private let beforeScheduledWriteForTesting: (@Sendable () -> Void)?
    let url: URL
    private let legacyURL: URL

    private struct PendingWrite: Sendable {
        let text: String
        let pinOnSave: Bool?
        let folder: NoteFolder?
        let onFailure: (@Sendable (Error) -> Void)?
    }

    init(stateDirectory: URL, debounceInterval: DispatchTimeInterval = .milliseconds(180),
         maxCoalescingInterval: DispatchTimeInterval = .seconds(1),
         beforeScheduledWriteForTesting: (@Sendable () -> Void)? = nil) {
        url = stateDirectory.appendingPathComponent("draft-note.json")
        legacyURL = stateDirectory.appendingPathComponent("draft-note.md")
        self.debounceInterval = debounceInterval
        self.maxCoalescingInterval = maxCoalescingInterval
        self.beforeScheduledWriteForTesting = beforeScheduledWriteForTesting
    }
    func load() throws -> String { try loadSnapshot().text }
    func loadSnapshot() throws -> NoteDraftSnapshot {
        try mutationLock.withLock {
            let (generation, pending) = supersedeScheduledWrite()
            return try persistenceQueue.sync {
                if let pending { try writeSnapshot(pending) }
                clearPendingWrite(ifCurrent: generation)
                return try lock.withLock { try read() }
            }
        }
    }

    /// Coalesce editor keystrokes and write the newest snapshot away from the main actor.
    /// A one-second max wait bounds crash exposure during continuous typing. Failures leave
    /// the snapshot pending so a synchronous dismissal/commit flush can retry it.
    func scheduleStore(_ text: String, pinOnSave: Bool? = nil, folder: NoteFolder? = nil,
                       onFailure: (@Sendable (Error) -> Void)? = nil) {
        scheduleLock.withLock {
            let pending = PendingWrite(text: text, pinOnSave: pinOnSave ?? pendingWrite?.pinOnSave,
                                       folder: folder,
                                       onFailure: onFailure)
            scheduleGeneration &+= 1
            scheduledWork?.cancel()
            pendingWrite = pending
            let now = DispatchTime.now()
            let first = firstPendingAt ?? now
            firstPendingAt = first
            let quietDeadline = now + debounceInterval
            let maximumDeadline = first + maxCoalescingInterval
            let deadline = quietDeadline.uptimeNanoseconds < maximumDeadline.uptimeNanoseconds
                ? quietDeadline : maximumDeadline
            let generation = scheduleGeneration
            let work = DispatchWorkItem { [weak self] in self?.persistScheduledWrite(generation: generation) }
            scheduledWork = work
            persistenceQueue.asyncAfter(deadline: deadline, execute: work)
        }
    }

    /// Persist the current editor text before dismissal or a save. It invalidates delayed
    /// writes first, then waits behind any write already in progress, so stale text cannot
    /// land after this snapshot. A failure keeps the latest snapshot pending for retry.
    func flushScheduledStore(_ text: String, pinOnSave: Bool? = nil, folder: NoteFolder? = nil) throws {
        try mutationLock.withLock {
            let (generation, pending) = replacePendingWrite(text: text, pinOnSave: pinOnSave, folder: folder)
            try persistenceQueue.sync {
                try writeSnapshot(pending)
                clearPendingWrite(ifCurrent: generation)
            }
        }
    }

    func store(_ text: String, pinOnSave: Bool? = nil, folder: NoteFolder? = nil) throws {
        try mutationLock.withLock {
            let (generation, pending) = replacePendingWrite(text: text, pinOnSave: pinOnSave, folder: folder, keepFailureHandler: false)
            try persistenceQueue.sync {
                try writeSnapshot(pending)
                clearPendingWrite(ifCurrent: generation)
            }
        }
    }
    func setPinOnSave(_ pin: Bool) throws {
        try mutationLock.withLock {
            let (generation, pending) = supersedeScheduledWrite(updatingPin: pin)
            try persistenceQueue.sync {
                if let pending { try writeSnapshot(pending) }
                else {
                    try lock.withLock {
                        var draft = try read()
                        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        draft.pinOnSave = pin
                        try write(draft)
                    }
                }
                clearPendingWrite(ifCurrent: generation)
            }
        }
    }
    func clear(ifMatching text: String, folder: NoteFolder? = nil) throws {
        try mutationLock.withLock {
            let (generation, pending) = supersedeScheduledWrite()
            try persistenceQueue.sync {
                if let pending { try writeSnapshot(pending) }
                try lock.withLock {
                    let draft = try read()
                    if draft.folder == folder, CaptureFormat.noteBody(draft.text) == CaptureFormat.noteBody(text) { try remove() }
                }
                clearPendingWrite(ifCurrent: generation)
            }
        }
    }
    /// Apply the current intent before consuming the matching draft. Recovery never
    /// takes intent from a replaced/discarded draft; interactive saves supply their call's intent.
    func completeSave(matching text: String, pinOnSave: Bool?, folder: NoteFolder? = nil, applyPin: (Bool) -> Void) throws {
        try mutationLock.withLock {
            let (generation, pending) = supersedeScheduledWrite()
            try persistenceQueue.sync {
                if let pending { try writeSnapshot(pending) }
                try lock.withLock {
                    let draft = try read()
                    let matches = draft.folder == folder && CaptureFormat.noteBody(draft.text) == CaptureFormat.noteBody(text)
                    applyPin(pinOnSave ?? (matches && draft.pinOnSave))
                    if matches { try remove() }
                }
                clearPendingWrite(ifCurrent: generation)
            }
        }
    }

    private func persistScheduledWrite(generation: UInt64) {
        guard let pending = scheduleLock.withLock({
            scheduleGeneration == generation ? pendingWrite : nil
        }) else { return }
        do {
            beforeScheduledWriteForTesting?()
            try writeSnapshot(pending)
            clearPendingWrite(ifCurrent: generation)
        } catch {
            let handler = scheduleLock.withLock { () -> (@Sendable (Error) -> Void)? in
                guard scheduleGeneration == generation else { return nil }
                scheduledWork = nil
                firstPendingAt = DispatchTime.now()
                return pendingWrite?.onFailure
            }
            handler?(error)
        }
    }

    private func replacePendingWrite(text: String, pinOnSave: Bool?, folder: NoteFolder?, keepFailureHandler: Bool = true) -> (UInt64, PendingWrite) {
        scheduleLock.withLock {
            let previous = pendingWrite
            let pending = PendingWrite(text: text, pinOnSave: pinOnSave ?? previous?.pinOnSave,
                                       folder: folder,
                                       onFailure: keepFailureHandler ? previous?.onFailure : nil)
            scheduleGeneration &+= 1
            scheduledWork?.cancel()
            scheduledWork = nil
            firstPendingAt = nil
            pendingWrite = pending
            return (scheduleGeneration, pending)
        }
    }

    /// Stop a delayed write without discarding it, for barriers that need to drain it first.
    private func supersedeScheduledWrite(updatingPin pin: Bool? = nil) -> (UInt64, PendingWrite?) {
        scheduleLock.withLock {
            scheduleGeneration &+= 1
            scheduledWork?.cancel()
            scheduledWork = nil
            firstPendingAt = nil
            if let pin, let pendingWrite {
                self.pendingWrite = PendingWrite(text: pendingWrite.text, pinOnSave: pin, folder: pendingWrite.folder, onFailure: pendingWrite.onFailure)
            }
            return (scheduleGeneration, pendingWrite)
        }
    }

    private func clearPendingWrite(ifCurrent generation: UInt64) {
        scheduleLock.withLock {
            guard scheduleGeneration == generation else { return }
            pendingWrite = nil
            scheduledWork = nil
            firstPendingAt = nil
        }
    }

    private func writeSnapshot(_ pending: PendingWrite) throws {
        try lock.withLock {
            if pending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try remove(); return }
            let pin = try pending.pinOnSave ?? read().pinOnSave
            try write(NoteDraftSnapshot(text: pending.text, pinOnSave: pin, folder: pending.folder))
        }
    }
    private func read() throws -> NoteDraftSnapshot {
        do { return try JSONDecoder().decode(NoteDraftSnapshot.self, from: Data(contentsOf: url)) }
        catch is DecodingError {
            // A corrupt record must not block the editor or fail saves; keep it aside for inspection.
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return NoteDraftSnapshot(text: "", pinOnSave: false)
        }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            do { return NoteDraftSnapshot(text: try String(contentsOf: legacyURL, encoding: .utf8), pinOnSave: false) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return NoteDraftSnapshot(text: "", pinOnSave: false)
            }
        }
    }
    private func write(_ draft: NoteDraftSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        try removeFile(legacyURL)
    }
    private func remove() throws { try removeFile(legacyURL); try removeFile(url) }
    private func removeFile(_ file: URL) throws {
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }
}
