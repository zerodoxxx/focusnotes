import CaptureKit
import Core
import Foundation

/// Drives CaptureCommitQueue directly, without AppController or any UI.
@MainActor
func checkCaptureCommitQueue() async throws {
    try await checkStagedCapturesCommitInOrder()
    try await checkFailedChoiceHoldsCapture()
    try await checkRetypedSubheadingSavesOnce()
    try await checkQuitDrainSavesHeldCapture()
}

/// Records host calls; `waitUntil` resumes once a recorded call satisfies its condition, or throws after a timeout.
@MainActor
private final class RecordingQueueHost: CaptureQueueHost {
    var calls: [String] = []
    var held: [UUID] = []
    private var waiters: [UUID: (condition: () -> Bool, continuation: CheckedContinuation<Bool, Never>)] = [:]

    func captureStaged(_ capture: PendingCapture, outsideSession: Bool, previousNotice: String?) async { record("staged") }
    func pendingCaptureReleased() { record("released") }
    func captureSaved(_ saved: SavedCapture, outsideSession: Bool) async { record("saved") }
    func captureHeldForChoice(_ capture: PendingCapture, error: Error) { held.append(capture.id); record("held") }
    func previousCaptureWillRetry(destination: Destination?) { record("willRetry") }
    func captureSaveFailed(_ error: Error) { record("saveFailed") }
    func captureJournalFailed(_ error: Error) { record("journalFailed") }
    func noteSaved(_ saved: SavedCapture, pinFailed: Bool) { record("noteSaved") }

    func waitUntil(_ description: String, timeout: Duration = .seconds(3), _ condition: @escaping () -> Bool) async throws {
        if condition() { return }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.waiters.removeValue(forKey: id)?.continuation.resume(returning: false)
        }
        defer { timer.cancel() }
        let satisfied = await withCheckedContinuation { waiters[id] = (condition, $0) }
        guard satisfied else { throw SelfTestFailure("Queue: timed out waiting for \(description)") }
    }

    private func record(_ call: String) {
        calls.append(call)
        for (id, waiter) in waiters where waiter.condition() {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: true)
        }
    }
}

@MainActor
private func withQueue(_ name: String, _ body: (CaptureCommitQueue, RecordingQueueHost, CapturePipeline, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultRoot = root.appendingPathComponent("Vault")
    let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let queue = CaptureCommitQueue(pipeline: pipeline)
    let host = RecordingQueueHost()
    queue.host = host
    try await body(queue, host, pipeline, root)
}

private func queueCapture(_ text: String) -> PendingCapture {
    PendingCapture(trigger: .selection, content: .text(text), source: CaptureSource(appName: "Queue check"), subtitle: "check")
}

@MainActor
private func checkStagedCapturesCommitInOrder() async throws {
    try await withQueue("queue-order") { queue, _, pipeline, _ in
        await queue.stage(queueCapture("first queued capture"))
        await queue.stage(queueCapture("second queued capture"))
        guard let task = queue.commitPending() else { throw SelfTestFailure("Queue: second capture was not pending") }
        _ = try await task.value
        await queue.waitForCommits()
        let inbox = try String(contentsOf: pipeline.vault.inboxURL, encoding: .utf8)
        guard let first = inbox.range(of: "first queued capture"), let second = inbox.range(of: "second queued capture"),
              first.lowerBound < second.lowerBound, try await pipeline.journal.recordURLs().isEmpty else {
            throw SelfTestFailure("Queue: staged captures were not saved in order with a clean journal")
        }
    }
}

@MainActor
private func checkFailedChoiceHoldsCapture() async throws {
    try await withQueue("queue-held") { queue, host, pipeline, root in
        let vaultRoot = root.appendingPathComponent("Vault")
        let firstURL = vaultRoot.appendingPathComponent("Sessions/First.md")
        let secondURL = vaultRoot.appendingPathComponent("Sessions/Second.md")
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Target\n".utf8).write(to: firstURL)
        try Data("# Target\n".utf8).write(to: secondURL)
        try await pipeline.index.reindex(note: firstURL)
        try await pipeline.index.reindex(note: secondURL)
        let capture = queueCapture("held for an exact choice")
        await queue.stage(capture, outsideSession: true)
        if (try? await queue.commitPending(noteTitle: "Target")?.value) != nil {
            throw SelfTestFailure("Queue: an ambiguous title selected a destination")
        }
        try await host.waitUntil("the failed choice to hold the capture") { host.held.contains(capture.id) }
        guard queue.pending?.id == capture.id, queue.needsRetryChoice else {
            throw SelfTestFailure("Queue: a failed chosen title did not hold the same capture for a retry choice")
        }
        let chosen = NotePick(noteID: "Sessions/Second.md", title: "Target", kind: .session)
        guard let task = queue.commitPending(pick: chosen) else { throw SelfTestFailure("Queue: held capture was not committable") }
        _ = try await task.value
        await queue.waitForCommits()
        let second = try String(contentsOf: secondURL, encoding: .utf8)
        let first = try String(contentsOf: firstURL, encoding: .utf8)
        guard second.components(separatedBy: "held for an exact choice").count - 1 == 1, !first.contains("held for an exact choice"),
              queue.pending == nil, try await pipeline.journal.recordURLs().isEmpty else {
            throw SelfTestFailure("Queue: an explicit destination did not save the held capture exactly once")
        }
    }
}

@MainActor
private func checkRetypedSubheadingSavesOnce() async throws {
    try await withQueue("queue-subheading") { queue, _, pipeline, root in
        let session = try await pipeline.sessions.start(name: "Linked")
        let noteURL = root.appendingPathComponent("Vault").appendingPathComponent(session.notePath)
        // A second hard link makes the session note unsafe to write, so the commit fails.
        let link = root.appendingPathComponent("second-link.md")
        try FileManager.default.linkItem(at: noteURL, to: link)
        if (try? await queue.addSubheading("Queue heading", destination: nil)) != nil {
            throw SelfTestFailure("Queue: a subheading saved to an unsafe note")
        }
        try FileManager.default.removeItem(at: link)
        guard try await queue.addSubheading("Queue heading", destination: nil) != nil else {
            throw SelfTestFailure("Queue: a retyped subheading did not save")
        }
        queue.beginQuit()
        await queue.drainForQuit()
        queue.close()
        let note = try String(contentsOf: noteURL, encoding: .utf8)
        guard note.components(separatedBy: "## Queue heading\n").count - 1 == 1,
              try await pipeline.journal.recordURLs().isEmpty else {
            throw SelfTestFailure("Queue: a retyped failed subheading was not written exactly once")
        }
    }
}

@MainActor
private func checkQuitDrainSavesHeldCapture() async throws {
    try await withQueue("queue-quit") { queue, host, pipeline, _ in
        let capture = queueCapture("held capture saved by quit")
        await queue.stage(capture, outsideSession: true)
        _ = try? await queue.commitPending(noteTitle: "../escape")?.value
        try await host.waitUntil("the failed choice to hold the capture") { host.held.contains(capture.id) }
        guard queue.pending?.id == capture.id, queue.commitPending() == nil else {
            throw SelfTestFailure("Queue: a retry-held capture was committed implicitly")
        }
        queue.beginQuit()
        await queue.drainForQuit()
        queue.close()
        let inbox = try String(contentsOf: pipeline.vault.inboxURL, encoding: .utf8)
        guard queue.pending == nil, inbox.components(separatedBy: "held capture saved by quit").count - 1 == 1,
              try await pipeline.journal.recordURLs().isEmpty else {
            throw SelfTestFailure("Queue: the quit drain did not save a retry-held capture")
        }
    }
}
