import CaptureKit
import Core
import Foundation
import os

/// UI reactions to capture lifecycle events. The queue owns the jobs; the host owns toasts and pickers.
@MainActor
protocol CaptureQueueHost: AnyObject {
    /// A staged capture's default job is journaled and it is still pending (queue not quitting). Show its toast or picker.
    func captureStaged(_ capture: PendingCapture, outsideSession: Bool, previousNotice: String?) async
    /// The pending capture was taken for commit: dismiss its toast and clear its UI state.
    func pendingCaptureReleased()
    /// An `announce: true` commit succeeded while nothing else is pending.
    func captureSaved(_ saved: SavedCapture, outsideSession: Bool) async
    /// A chosen title/destination failed to prepare; the capture is pending again and needs a retry choice.
    func captureHeldForChoice(_ capture: PendingCapture, error: Error)
    /// Same failure while another capture is pending: the staged default stays queued for the quit drain/recovery.
    func previousCaptureWillRetry(destination: Destination?)
    func captureSaveFailed(_ error: Error)
    func captureJournalFailed(_ error: Error)
    /// Feedback for a note saved by the quit drain's retry.
    func noteSaved(_ saved: SavedCapture, pinFailed: Bool)
}

/// Owns the capture job lifecycle: prepare → journal → wait for earlier commits → commit.
@MainActor
final class CaptureCommitQueue {
    let pipeline: CapturePipeline
    weak var host: CaptureQueueHost?
    private let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "app")
    private(set) var pending: PendingCapture?
    private(set) var pendingOutsideSession = false
    private(set) var needsRetryChoice = false
    private var commitTail: Task<SavedCapture, Error>?
    private var commitMonitor: Task<Void, Never>?
    private var stagedJob: (id: UUID, preparation: Task<CaptureJob, Error>, persistence: Task<Void, Error>)?
    private var commitGeneration = 0
    private var preparedJobs: [UUID: Task<CaptureJob, Error>] = [:]
    // Subheading jobs in `preparedJobs` whose commit already threw; only these can be reused by a retyped subheading.
    private var failedSubheadingIDs = Set<UUID>()
    private var recoveryJobs: [UUID: Task<CaptureJob, Error>] = [:]
    private var recoveryPersistences: [UUID: Task<Void, Error>] = [:]
    private var processingTail: Task<Void, Never>?
    private var processingGeneration = 0
    private var isQuitting = false
    private var isClosed = false

    init(pipeline: CapturePipeline) {
        self.pipeline = pipeline
    }

    func beginQuit() { isQuitting = true }
    func close() { isClosed = true }
    func hasPreparedJobForChecks(_ id: UUID) -> Bool { preparedJobs[id] != nil }
    var commitTailForChecks: Task<SavedCapture, Error>? { commitTail }

    /// Every job the queue may still write, for redirecting a session rename.
    func knownJobs() async -> [CaptureJob] {
        var knownJobs: [CaptureJob] = []
        var tasks = Array(preparedJobs.values) + Array(recoveryJobs.values)
        if let stagedJob { tasks.append(stagedJob.preparation) }
        for task in tasks {
            if let job = try? await task.value { knownJobs.append(job) }
        }
        return knownJobs
    }

    func journalAcquisition(_ capture: PendingCapture, outsideSession: Bool = false) {
        guard recoveryJobs[capture.id] == nil else { return }
        let pipeline = pipeline
        let preparation = Task.detached(priority: .userInitiated) {
            try await pipeline.prepare(capture, noteTitle: nil, outsideSession: outsideSession)
        }
        recoveryJobs[capture.id] = preparation
        recoveryPersistences[capture.id] = Task.detached(priority: .userInitiated) {
            try await pipeline.journal.store(try await preparation.value)
        }
    }

    /// Stages processed captures in acquisition order.
    func enqueueProcessed(_ capture: Task<PendingCapture, Never>, outsideSession: Bool) {
        let previous = processingTail
        processingGeneration += 1
        let processingID = processingGeneration
        processingTail = Task { [self] in
            await previous?.value
            await stage(capture.value, outsideSession: outsideSession)
            if processingGeneration == processingID { processingTail = nil }
        }
    }

    func stage(_ capture: PendingCapture, outsideSession: Bool = false) async {
        guard !isClosed else { return }
        _ = commitPending()
        // A newer capture saves a retry-pending one to its staged default, then says so.
        var previousNotice: String?
        if needsRetryChoice, let held = pending {
            let staged = stagedJob.flatMap { $0.id == held.id ? $0 : nil }
            let destination = try? await staged?.preparation.value.prepared.destination
            if needsRetryChoice, pending?.id == held.id, let commit = commitPending(force: true) {
                // Finish A, including its failure handling, before B is staged.
                let succeeded = (try? await commit.value) != nil
                await commitMonitor?.value
                previousNotice = succeeded
                    ? destination.map { "Previous capture saved to \($0.title)" } ?? "Previous capture saved"
                    : "Couldn't save the previous capture · recovery will retry"
            }
        }
        let pipeline = pipeline
        let recovery = recoveryJobs[capture.id]
        let recoveryPersistence = recoveryPersistences[capture.id]
        let preparation = Task.detached(priority: .userInitiated) {
            let recovered = try? await recovery?.value
            return try await pipeline.prepare(capture, noteTitle: nil, destination: recovered?.prepared.destination, outsideSession: outsideSession)
        }
        let persistence = Task.detached(priority: .userInitiated) {
            _ = try? await recoveryPersistence?.value
            try await pipeline.journal.store(try await preparation.value)
        }
        stagedJob = (capture.id, preparation, persistence)
        pending = capture
        pendingOutsideSession = outsideSession
        // Persist the default job before showing the toast or accepting a note title.
        do { try await persistence.value }
        catch { host?.captureJournalFailed(error) }
        guard pending?.id == capture.id else { return }
        if isQuitting { _ = commitPending(); return }
        await host?.captureStaged(capture, outsideSession: outsideSession, previousNotice: previousNotice)
    }

    /// Implicit commits (drain, toast, rename, draft save) skip a retry-pending capture; only an
    /// explicit destination, shutdown, or a newer capture staged in `stage()` may save it.
    @discardableResult
    func commitPending(noteTitle: String? = nil, destination: Destination? = nil, announce: Bool = false, force: Bool = false) -> Task<SavedCapture, Error>? {
        guard let capture = pending else { return nil }
        if needsRetryChoice, !force, noteTitle == nil, destination == nil, !isQuitting { return nil }
        let outsideSession = pendingOutsideSession
        pending = nil
        pendingOutsideSession = false
        needsRetryChoice = false
        host?.pendingCaptureReleased()
        let pipeline = pipeline
        let staged = stagedJob.flatMap { $0.id == capture.id ? $0 : nil }
        stagedJob = nil
        // Only shutdown's acquired-pixel fallback forces its original destination.
        let recovery = isQuitting ? recoveryJobs[capture.id] : nil
        let recoveryPersistence = recoveryPersistences[capture.id]
        let preparation = Task.detached(priority: .userInitiated) {
            let resolvedDestination: Destination?
            if let recovery { resolvedDestination = try? await recovery.value.prepared.destination }
            else if let destination { resolvedDestination = destination }
            else if noteTitle == nil { resolvedDestination = try? await staged?.preparation.value.prepared.destination }
            else { resolvedDestination = nil }
            if destination != nil {
                // noteLocation covers HOME notes too; it fails when the note no longer exists.
                guard let resolvedDestination,
                      let noteID = try? pipeline.vault.noteID(for: resolvedDestination.url),
                      (try? pipeline.vault.noteLocation(forID: noteID)) != nil else {
                    throw CocoaError(.fileNoSuchFile)
                }
            }
            return try await pipeline.prepare(capture, noteTitle: noteTitle, destination: resolvedDestination, outsideSession: outsideSession)
        }
        preparedJobs[capture.id] = preparation
        let (task, generation) = enqueueCommit(preparation, after: commitTail,
                                               journals: [staged?.persistence, recoveryPersistence].compactMap { $0 })
        commitMonitor = Task { [weak self] in
            do {
                let saved = try await task.value
                self?.preparedJobs.removeValue(forKey: capture.id)
                self?.recoveryJobs.removeValue(forKey: capture.id)
                self?.recoveryPersistences.removeValue(forKey: capture.id)
                if announce, self?.pending == nil {
                    await self?.host?.captureSaved(saved, outsideSession: outsideSession)
                }
            } catch {
                if (noteTitle != nil || destination != nil), case .failure = await preparation.result, let staged {
                    self?.preparedJobs.removeValue(forKey: capture.id)
                    if self?.pending == nil {
                        self?.stagedJob = staged
                        self?.pending = capture
                        self?.pendingOutsideSession = outsideSession
                        self?.needsRetryChoice = true
                        self?.host?.captureHeldForChoice(capture, error: error)
                    } else {
                        let fallback = try? await staged.preparation.value.prepared.destination
                        self?.preparedJobs[capture.id] = staged.preparation
                        self?.host?.previousCaptureWillRetry(destination: fallback)
                    }
                } else {
                    self?.host?.captureSaveFailed(error)
                }
            }
            self?.releaseCommitTail(generation)
        }
        return task
    }

    /// Saves a typed note after earlier captures. The caller stores the draft first.
    /// `onNoteSaved` gets (saved, pinFailed, created, outsideSessionName).
    func addNote(_ rawText: String, destination: Destination?, pinOnSave: Bool, newNote: Bool, outsideSession: Bool, folder: NoteFolder?,
                 onNoteSaved: @escaping @MainActor @Sendable (SavedCapture, Bool, Bool, String?) -> Void) async throws -> SavedCapture? {
        let text = CaptureFormat.noteBody(rawText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        await commitEarlierCaptures(waitingForThem: true)
        let pipeline = pipeline
        var retry: Task<CaptureJob, Error>?
        var superseded: [UUID: UUID] = [:]
        for (key, candidate) in Array(preparedJobs) {
            guard let job = try? await candidate.value else { continue }
            if job.noteDraft.map(CaptureFormat.noteBody) == text || (job.noteDraft == nil && job.prepared.capture.content == .note(text)) {
                if job.noteOutsideSession != outsideSession || job.noteFolder != folder || (destination != nil && job.prepared.destination != destination) {
                    superseded[key] = job.prepared.capture.id
                    continue
                }
                if destination == nil || job.prepared.destination == destination {
                    if newNote && job.prepared.createsNote != true {
                        superseded[key] = job.prepared.capture.id
                        continue
                    }
                    retry = candidate; break
                }
            }
        }
        // A changed route or Save as New Note replaces the earlier job for this draft; replay must not also append it.
        // Remove from the journal first; on failure the draft is kept and the old job stays retryable.
        for (key, id) in superseded {
            try await pipeline.journal.remove(id: id)
            preparedJobs.removeValue(forKey: key)
        }
        let capture = Capture(id: UUID(), createdAt: Date(), content: .note(text), source: CaptureSource())
        let preparation = retry ?? Task.detached(priority: .userInitiated) {
            let prepared = try await pipeline.prepareNote(capture, destination: destination, newNote: newNote, outsideSession: outsideSession, folder: folder)
            return CaptureJob(prepared: prepared, png: nil, ocr: nil, noteDraft: rawText, noteOutsideSession: outsideSession, noteFolder: folder)
        }
        let preparedNote = try await preparation.value.prepared
        let noteID = preparedNote.capture.id
        preparedJobs[noteID] = preparation
        let previous = commitTail
        let outsideSessionName = outsideSession ? await pipeline.sessions.current()?.name : nil
        let created = preparedNote.createsNote == true
        let (task, generation) = enqueueCommit(preparation, after: previous, pinOnSave: pinOnSave) { saved, pinFailed in
            onNoteSaved(saved, pinFailed, created, outsideSessionName)
        }
        // A failed commit must clear the tail too, or later editor opens keep rethrowing it.
        defer { releaseCommitTail(generation) }
        let saved = try await task.value
        preparedJobs.removeValue(forKey: noteID)
        return saved
    }

    /// Returns nil for an empty subheading.
    func addSubheading(_ text: String, destination: Destination?) async throws -> SavedCapture? {
        let text = CaptureFormat.cleanSubheading(text)
        guard !text.isEmpty else { return nil }
        await commitEarlierCaptures(waitingForThem: false)
        let pipeline = pipeline
        // Retyping a subheading whose commit failed retries that capture and id, so the quit drain
        // cannot also write it. Only a failed job with the same text and destination matches; a
        // queued or different one is left alone.
        var retry: Task<CaptureJob, Error>?
        var capture = Capture(id: UUID(), createdAt: Date(), content: .subheading(text), source: CaptureSource())
        failedSubheadingIDs.formIntersection(preparedJobs.keys)
        for id in failedSubheadingIDs {
            guard let candidate = preparedJobs[id], let job = try? await candidate.value,
                  job.prepared.capture.content == .subheading(text),
                  destination == nil || job.prepared.destination == destination else { continue }
            retry = candidate
            capture = job.prepared.capture
            failedSubheadingIDs.remove(id)
            break
        }
        let preparation = retry ?? Task.detached(priority: .userInitiated) { [capture] in
            let prepared = try await pipeline.prepareCapture(capture, destination: destination)
            return CaptureJob(prepared: prepared, png: nil, ocr: nil)
        }
        preparedJobs[capture.id] = preparation
        let (task, generation) = enqueueCommit(preparation, after: commitTail)
        defer { releaseCommitTail(generation) }
        let saved: SavedCapture
        do { saved = try await task.value }
        catch {
            failedSubheadingIDs.insert(capture.id)
            throw error
        }
        preparedJobs.removeValue(forKey: capture.id)
        return saved
    }

    /// Commits earlier captures, runs `beforeWaiting` (false stops here), then waits for every
    /// commit queued so far. Each commit reports its own failure; none fails the caller.
    func settleEarlierCaptures(beforeWaiting: @MainActor () async -> Bool) async -> Bool {
        let pendingCommit = commitPending()
        await processingTail?.value
        let processedCommit = commitPending()
        guard await beforeWaiting() else { return false }
        let tail = commitTail
        _ = try? await pendingCommit?.value
        _ = try? await processedCommit?.value
        _ = try? await tail?.value
        return true
    }

    func waitForProcessing() async { await processingTail?.value }

    func waitForCommits() async { _ = try? await commitTail?.value }

    /// Commits the pending and processing captures; the caller awaits acquisition first.
    func drain() async {
        _ = commitPending()
        await processingTail?.value
        _ = commitPending()
        await waitForCommits()
    }

    /// The shutdown drain after acquisition, processing and queued actions have finished.
    func drainForQuit() async {
        for persistence in recoveryPersistences.values {
            do { try await persistence.value }
            catch { logger.error("Shutdown recovery journal failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)") }
        }
        guard !isClosed else { return }
        _ = commitPending()
        await waitForCommits()
        guard !isClosed else { return }
        let pipeline = pipeline
        // A journal write itself may have failed earlier. Retry the exact prepared
        // capture, never its title or destination routing.
        for (id, preparation) in preparedJobs {
            do {
                let job = try await preparation.value
                try await pipeline.journal.store(job)
                _ = try await pipeline.commit(job) { [weak self] saved, pinFailed in
                    self?.host?.noteSaved(saved, pinFailed: pinFailed)
                }
                preparedJobs.removeValue(forKey: id)
            } catch { logger.error("Shutdown save retained in journal (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)") }
        }
    }

    /// Earlier captures save first, but their commits report their own failures; one
    /// must not fail a typed note or subheading.
    private func commitEarlierCaptures(waitingForThem: Bool) async {
        let pendingCommit = commitPending()
        await processingTail?.value
        let processedCommit = commitPending()
        guard waitingForThem else { return }
        _ = try? await pendingCommit?.value
        _ = try? await processedCommit?.value
    }

    /// The one commit chain. Journal before waiting for earlier writes, so even queued work is
    /// recoverable. Callers must `releaseCommitTail` with the returned generation, also on failure.
    private func enqueueCommit(_ preparation: Task<CaptureJob, Error>, after previous: Task<SavedCapture, Error>?,
                               journals: [Task<Void, Error>] = [], pinOnSave: Bool? = nil,
                               onNoteSaved: (@MainActor @Sendable (SavedCapture, Bool) -> Void)? = nil) -> (Task<SavedCapture, Error>, Int) {
        let pipeline = pipeline
        let task = Task.detached(priority: .userInitiated) {
            let job = try await preparation.value
            for journal in journals { _ = try? await journal.value }
            try await pipeline.journal.store(job)
            _ = try? await previous?.value
            return try await pipeline.commit(job, pinOnSave: pinOnSave, onNoteSaved: onNoteSaved)
        }
        commitTail = task
        commitGeneration += 1
        return (task, commitGeneration)
    }

    private func releaseCommitTail(_ generation: Int) {
        if commitGeneration == generation { commitTail = nil }
    }
}
