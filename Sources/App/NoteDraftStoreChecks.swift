import Foundation
import Core

private final class ScheduledDraftWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    let firstWrite = DispatchSemaphore(value: 0)

    func record() {
        lock.withLock { total += 1 }
        firstWrite.signal()
    }

    var count: Int { lock.withLock { total } }
}

private func diskDraft(at url: URL) throws -> NoteDraftSnapshot {
    try JSONDecoder().decode(NoteDraftSnapshot.self, from: Data(contentsOf: url))
}

/// Keep semaphore blocking in a synchronous helper; Swift 6 forbids it directly
/// inside async task contexts, including detached tasks.
private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: DispatchTimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

@MainActor
func checkNoteDraftStoreScheduling() async throws {
    try checkDraftFolderContext()
    try checkDraftCompletionFolderIdentity()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("draft-store-scheduler-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Several rapid edits result in one delayed write containing the latest text and pin.
    let coalescedProbe = ScheduledDraftWriteProbe()
    let coalesced = NoteDraftStore(stateDirectory: root.appendingPathComponent("Coalesced"),
                                   debounceInterval: .milliseconds(300), maxCoalescingInterval: .seconds(1),
                                   beforeScheduledWriteForTesting: { coalescedProbe.record() })
    coalesced.scheduleStore("older editor text", pinOnSave: true)
    try await Task.sleep(for: .milliseconds(20))
    coalesced.scheduleStore("latest editor text", pinOnSave: false)
    guard !FileManager.default.fileExists(atPath: coalesced.url.path) else {
        throw SelfTestFailure("Draft keystrokes must not synchronously write on the caller thread")
    }
    let coalescingDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !FileManager.default.fileExists(atPath: coalesced.url.path), ContinuousClock.now < coalescingDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let coalescedSnapshot = try diskDraft(at: coalesced.url)
    guard coalescedSnapshot.text == "latest editor text", !coalescedSnapshot.pinOnSave,
          coalescedProbe.count == 1 else {
        throw SelfTestFailure("Rapid draft edits were not coalesced into the newest atomic snapshot")
    }

    // Continuous typing cannot postpone persistence forever: the max wait wins over debounce.
    let boundedProbe = ScheduledDraftWriteProbe()
    let bounded = NoteDraftStore(stateDirectory: root.appendingPathComponent("Bounded"),
                                 debounceInterval: .seconds(1), maxCoalescingInterval: .milliseconds(250),
                                 beforeScheduledWriteForTesting: { boundedProbe.record() })
    let producerDone = DispatchSemaphore(value: 0)
    let producer = Task.detached(priority: .utility) {
        defer { producerDone.signal() }
        for index in 0..<24 {
            bounded.scheduleStore("continuous edit \(index)", pinOnSave: false)
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
    let persistedBeforeProducerFinished = await Task.detached(priority: .utility) {
        waitForSignal(boundedProbe.firstWrite, timeout: .seconds(1))
            && !waitForSignal(producerDone, timeout: .nanoseconds(0))
    }.value
    await producer.value
    guard persistedBeforeProducerFinished else {
        throw SelfTestFailure("Continuous editor changes exceeded the maximum draft persistence interval")
    }
    let boundedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while (try? diskDraft(at: bounded.url).text) != "continuous edit 23", ContinuousClock.now < boundedDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard try diskDraft(at: bounded.url).text == "continuous edit 23" else {
        throw SelfTestFailure("The bounded draft writer did not persist the final edit")
    }

    let pinStore = NoteDraftStore(stateDirectory: root.appendingPathComponent("Pin"),
                                  debounceInterval: .milliseconds(200), maxCoalescingInterval: .milliseconds(400))
    pinStore.scheduleStore("draft whose pin changes", pinOnSave: false)
    try pinStore.setPinOnSave(true)
    try await Task.sleep(for: .milliseconds(250))
    let pinnedSnapshot = try diskDraft(at: pinStore.url)
    guard pinnedSnapshot.text == "draft whose pin changes", pinnedSnapshot.pinOnSave else {
        throw SelfTestFailure("A delayed text write overwrote a newer pin-on-save intent")
    }

    // A flush waits behind an already-running stale write, then leaves the newer snapshot last.
    let enteredWrite = DispatchSemaphore(value: 0)
    let releaseWrite = DispatchSemaphore(value: 0)
    let inFlight = NoteDraftStore(stateDirectory: root.appendingPathComponent("InFlight"),
                                  debounceInterval: .milliseconds(25), maxCoalescingInterval: .milliseconds(100),
                                  beforeScheduledWriteForTesting: {
        enteredWrite.signal()
        releaseWrite.wait()
    })
    inFlight.scheduleStore("in-flight old text", pinOnSave: false)
    let didEnterWrite = await Task.detached(priority: .utility) {
        waitForSignal(enteredWrite, timeout: .seconds(2))
    }.value
    guard didEnterWrite else { throw SelfTestFailure("Scheduled draft write did not start for the ordering check") }
    let flushStarted = DispatchSemaphore(value: 0)
    let flushFinished = DispatchSemaphore(value: 0)
    let flush = Task.detached(priority: .utility) {
        defer { flushFinished.signal() }
        flushStarted.signal()
        try inFlight.flushScheduledStore("newest flushed text", pinOnSave: true)
    }
    let didStartFlush = await Task.detached(priority: .utility) {
        waitForSignal(flushStarted, timeout: .seconds(1))
    }.value
    try await Task.sleep(for: .milliseconds(30))
    let flushWaitedForWriter = await Task.detached(priority: .utility) {
        !waitForSignal(flushFinished, timeout: .nanoseconds(0))
    }.value
    releaseWrite.signal()
    guard didStartFlush else { throw SelfTestFailure("Synchronous draft flush did not start") }
    try await flush.value
    guard flushWaitedForWriter,
          try diskDraft(at: inFlight.url).text == "newest flushed text",
          try diskDraft(at: inFlight.url).pinOnSave else {
        throw SelfTestFailure("A stale in-flight write landed after the latest synchronous flush")
    }

    // Conditional clear and successful commit invalidate every queued debounce.
    let clearStore = NoteDraftStore(stateDirectory: root.appendingPathComponent("Clear"),
                                    debounceInterval: .milliseconds(100), maxCoalescingInterval: .milliseconds(300))
    clearStore.scheduleStore("draft to clear", pinOnSave: true)
    try clearStore.clear(ifMatching: "draft to clear")
    try await Task.sleep(for: .milliseconds(180))
    guard !FileManager.default.fileExists(atPath: clearStore.url.path) else {
        throw SelfTestFailure("A stale scheduled write resurrected a cleared draft")
    }
    clearStore.scheduleStore("draft consumed by commit", pinOnSave: true)
    try clearStore.completeSave(matching: "draft consumed by commit", pinOnSave: nil) { _ in }
    try await Task.sleep(for: .milliseconds(180))
    guard !FileManager.default.fileExists(atPath: clearStore.url.path) else {
        throw SelfTestFailure("A stale scheduled write resurrected a committed draft")
    }

    // A background failure keeps its latest snapshot pending so the final flush can retry it.
    let failed = NoteDraftStore(stateDirectory: root.appendingPathComponent("Failure"),
                                debounceInterval: .milliseconds(25), maxCoalescingInterval: .milliseconds(100))
    try failed.store("older durable text")
    try FileManager.default.removeItem(at: failed.url)
    try FileManager.default.createDirectory(at: failed.url, withIntermediateDirectories: false)
    let failureObserved = DispatchSemaphore(value: 0)
    failed.scheduleStore("latest text after failure", pinOnSave: true) { _ in failureObserved.signal() }
    let asyncFailureReported = await Task.detached(priority: .utility) {
        waitForSignal(failureObserved, timeout: .seconds(2))
    }.value
    guard asyncFailureReported else { throw SelfTestFailure("A failed background draft write was not reported") }
    var finalFlushFailed = false
    do { try failed.flushScheduledStore("latest text after failure", pinOnSave: true) }
    catch { finalFlushFailed = true }
    guard finalFlushFailed else { throw SelfTestFailure("The test storage fault did not fail the synchronous flush") }
    try FileManager.default.removeItem(at: failed.url)
    try failed.flushScheduledStore("latest text after failure", pinOnSave: true)
    let recovered = try failed.loadSnapshot()
    guard recovered.text == "latest text after failure", recovered.pinOnSave else {
        throw SelfTestFailure("Failed persistence did not retain the latest draft and pin intent for retry")
    }
}

@MainActor
private func checkDraftCompletionFolderIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("draft-folder-completion-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NoteDraftStore(stateDirectory: root, debounceInterval: .seconds(60))
    let original = try NoteFolder(rawValue: "Projects/Original")
    let newer = try NoteFolder(rawValue: "Projects/Newer")
    let text = "Same title\nSame body"
    // A newer scheduled draft must survive replay of identical text for another folder.
    store.scheduleStore(text, pinOnSave: true, folder: newer)
    var appliedPin: Bool?
    try store.completeSave(matching: text, pinOnSave: nil, folder: original) { appliedPin = $0 }
    let retained = try store.loadSnapshot()
    guard retained.text == text, retained.folder == newer, retained.pinOnSave, appliedPin == false else {
        throw SelfTestFailure("Recovery consumed another folder's same-text draft or inherited its pin intent")
    }
    // A legacy journal without folder context also cannot consume a scoped draft.
    appliedPin = nil
    try store.completeSave(matching: text, pinOnSave: nil) { appliedPin = $0 }
    guard try store.loadSnapshot().folder == newer, appliedPin == false else {
        throw SelfTestFailure("Legacy recovery consumed a folder draft or inherited its pin intent")
    }
    try store.clear(ifMatching: text, folder: original)
    guard try store.loadSnapshot().folder == newer else {
        throw SelfTestFailure("Explicit draft cleanup ignored its folder identity")
    }
    appliedPin = nil
    try store.completeSave(matching: text + "\n", pinOnSave: nil, folder: newer) { appliedPin = $0 }
    guard appliedPin == true, !FileManager.default.fileExists(atPath: store.url.path) else {
        throw SelfTestFailure("Matching folder completion did not consume the draft with its pin intent")
    }
    try store.store(text, pinOnSave: true)
    appliedPin = nil
    try store.completeSave(matching: text, pinOnSave: nil) { appliedPin = $0 }
    guard appliedPin == true, !FileManager.default.fileExists(atPath: store.url.path) else {
        throw SelfTestFailure("Legacy ordinary draft completion changed behavior")
    }
}

@MainActor
func checkDraftFolderContext() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("draft-folder-context-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NoteDraftStore(stateDirectory: root, debounceInterval: .seconds(60))
    let folder = try NoteFolder(rawValue: "Projects/Research")
    let other = try NoteFolder(rawValue: "Projects/Other")

    store.scheduleStore("first folder draft", pinOnSave: false, folder: folder)
    store.scheduleStore("latest folder draft", folder: other)
    try store.setPinOnSave(true)
    let pending = try store.loadSnapshot()
    guard pending.text == "latest folder draft", pending.folder == other, pending.pinOnSave else {
        throw SelfTestFailure("Coalesced draft or pin update lost the newest folder context")
    }
    try store.setPinOnSave(false)
    guard try store.loadSnapshot().folder == other else {
        throw SelfTestFailure("Updating a persisted draft pin lost its folder context")
    }

    store.scheduleStore("stale folder draft", folder: other)
    try store.flushScheduledStore("flushed folder draft", pinOnSave: true, folder: folder)
    let reopened = NoteDraftStore(stateDirectory: root)
    let restored = try reopened.loadSnapshot()
    guard restored.text == "flushed folder draft", restored.folder == folder, restored.pinOnSave else {
        throw SelfTestFailure("Flushed draft did not durably restore its folder context")
    }

    try store.store("ordinary draft")
    guard try store.loadSnapshot().folder == nil else {
        throw SelfTestFailure("An ordinary draft retained a previous folder context")
    }
    store.scheduleStore("folder draft before ordinary edit", folder: folder)
    store.scheduleStore("ordinary scheduled draft")
    guard try store.loadSnapshot().folder == nil else {
        throw SelfTestFailure("A scheduled ordinary draft inherited a pending folder context")
    }
    try store.store("folder draft before ordinary flush", folder: folder)
    try store.flushScheduledStore("ordinary flushed draft")
    guard try store.loadSnapshot().folder == nil else {
        throw SelfTestFailure("An ordinary draft flush retained the previous folder context")
    }

    try store.store("folder draft before blank", folder: folder)
    try store.store(" \n\t", folder: folder)
    guard !FileManager.default.fileExists(atPath: store.url.path), try store.loadSnapshot().folder == nil else {
        throw SelfTestFailure("A blank draft did not clear its durable folder context")
    }

    try Data("{\"text\":\"legacy JSON draft\",\"pinOnSave\":true}".utf8).write(to: store.url, options: .atomic)
    let legacy = try store.loadSnapshot()
    guard legacy.text == "legacy JSON draft", legacy.pinOnSave, legacy.folder == nil else {
        throw SelfTestFailure("A legacy JSON draft without folder did not load normally")
    }
    let invalidFolder = Data(#"{"text":"unsafe folder draft","pinOnSave":true,"folder":{"rawValue":"../escape"}}"#.utf8)
    try invalidFolder.write(to: store.url, options: .atomic)
    let recovered = try store.loadSnapshot()
    let quarantined = store.url.deletingPathExtension().appendingPathExtension("corrupt.json")
    guard recovered.text.isEmpty, recovered.folder == nil, !recovered.pinOnSave,
          !FileManager.default.fileExists(atPath: store.url.path),
          try Data(contentsOf: quarantined) == invalidFolder else {
        throw SelfTestFailure("An unsafe serialized draft folder did not recover and preserve the corrupt record")
    }
    try Data("legacy Markdown draft".utf8).write(to: root.appendingPathComponent("draft-note.md"), options: .atomic)
    let markdown = try store.loadSnapshot()
    guard markdown.text == "legacy Markdown draft", markdown.folder == nil else {
        throw SelfTestFailure("A legacy Markdown draft inherited a folder context")
    }
}
