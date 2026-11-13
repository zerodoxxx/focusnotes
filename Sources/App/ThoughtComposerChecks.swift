import Core
import Foundation

@MainActor
func checkThoughtComposer() async throws {
    try await checkThoughtReadScope()
    try await checkThoughtRenameDestination()
    let a = UUID(), b = UUID()
    let noteA = URL(fileURLWithPath: "/vault/A.md"), noteB = URL(fileURLWithPath: "/vault/B.md")
    var writes: [(String, UUID, URL)] = []
    var failure: Error?
    let composer = ThoughtComposer { text, id, note in
        if let failure { throw failure }
        writes.append((text, id, note))
    }

    let deleted = UUID()
    _ = composer.begin(deleted, savedThought: "saved", destination: { noteA })
    guard await composer.save(deleted, text: "saved") == .saved,
          composer.begin(deleted, savedThought: nil, destination: { noteA }) == "saved",
          composer.begin(deleted, savedThought: nil, savedStateLoaded: true, destination: { noteA }) == "" else {
        throw SelfTestFailure("Confirmed disk absence restored a deleted thought from cache")
    }
    composer.close(deleted, text: "draft")
    guard composer.begin(deleted, savedThought: nil, savedStateLoaded: true, destination: { noteA }) == "draft" else {
        throw SelfTestFailure("Confirmed disk absence discarded an unsaved draft")
    }
    writes.removeAll()

    // Escape keeps a draft; reopening prefers it over the saved thought.
    guard composer.begin(a, savedThought: "saved", destination: { noteA }) == "saved" else {
        throw SelfTestFailure("Thought editor did not start from the saved thought")
    }
    composer.close(a, text: "draft")
    guard composer.begin(a, savedThought: "saved elsewhere", destination: { noteA }) == "draft" else {
        throw SelfTestFailure("Thought draft was not restored on reopen")
    }
    composer.close(a, text: "saved elsewhere")
    guard composer.drafts[a] == nil else { throw SelfTestFailure("Unchanged thought left a draft") }

    // A save stays bound to its own capture after another capture opens.
    _ = composer.begin(a, savedThought: nil, destination: { noteA })
    _ = composer.begin(b, savedThought: nil, destination: { noteB })
    composer.close(a, text: "for A")
    failure = CocoaError(.fileWriteNoPermission)
    guard await composer.save(a, text: "for A") == .failed(ThoughtComposer.saveFailedMessage),
          composer.drafts[a] == "for A", writes.isEmpty else {
        throw SelfTestFailure("Failed thought save did not keep the draft")
    }
    failure = ThoughtWriteError.captureNotFound
    guard await composer.save(a, text: "for A") == .failed(ThoughtComposer.captureMissingMessage) else {
        throw SelfTestFailure("Missing capture reported the wrong message")
    }
    failure = nil
    guard await composer.save(a, text: "for A") == .saved, composer.drafts[a] == nil,
          writes.count == 1, writes[0].0 == "for A", writes[0].1 == a, writes[0].2 == noteA else {
        throw SelfTestFailure("Thought save did not write to its own capture and clear the draft")
    }

    // Reopening the same capture after closing unsaved text offers that text again.
    let c = UUID()
    _ = composer.begin(c, savedThought: "s", destination: { noteA })
    composer.close(c, text: "abc")
    guard composer.begin(c, savedThought: "s", destination: { noteA }) == "abc" else {
        throw SelfTestFailure("Reopened capture lost its unsaved thought")
    }

    // The index answers first; the known note is only consulted when the index has none.
    var knownCalls = 0
    let indexedNote = try await ThoughtComposer.resolveNote(indexed: { noteB }, known: { knownCalls += 1; return noteA })
    guard indexedNote == noteB, knownCalls == 0 else {
        throw SelfTestFailure("Indexed note did not win over the known note")
    }
    let knownNote = try await ThoughtComposer.resolveNote(indexed: { nil }, known: { noteA })
    guard knownNote == noteA else { throw SelfTestFailure("Unindexed capture did not use the known note") }
    let commitError = CocoaError(.fileWriteNoPermission)
    var rethrown: Error?
    do { _ = try await ThoughtComposer.resolveNote(indexed: { nil }, known: { throw commitError }) } catch { rethrown = error }
    guard (rethrown as? CocoaError)?.code == CocoaError.Code.fileWriteNoPermission else {
        throw SelfTestFailure("Commit failure was not rethrown for an unindexed capture")
    }
}

@MainActor
private func checkThoughtReadScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("thought-scope-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let outside = root.appendingPathComponent("outside.md")
    try Data("private".utf8).write(to: outside)
    let link = pipeline.vault.root.appendingPathComponent("Swapped.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    var rejected = false
    do { _ = try await pipeline.savedThought(forCapture: UUID(), inNoteAt: link) } catch { rejected = true }
    guard rejected else { throw SelfTestFailure("Thought read followed a link outside the vault") }
}

@MainActor
private func checkThoughtRenameDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("thought-rename-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("State")
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"), stateDirectory: state, calendar: .current)
    let session = try await pipeline.selfCheck.sessions.start(name: "Standup")
    let oldURL = pipeline.vault.root.appendingPathComponent(session.notePath)
    let capture = Capture(id: UUID(), createdAt: Date(), content: .text("capture"), source: CaptureSource(appName: "Check"))
    let prepared = PreparedCapture(capture: capture, destination: Destination(url: oldURL, title: session.name, kind: .session), noteMarkerIsIdentity: true)
    _ = try await pipeline.commit(CaptureJob(prepared: prepared, png: nil, ocr: nil, noteDraft: nil))
    let stateFile = state.appendingPathComponent("session.json")
    try FileManager.default.removeItem(at: stateFile)
    try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
    let candidate = SessionCandidate(name: session.name, notePath: session.notePath, modifiedAt: .distantPast)
    let outcome = try await pipeline.selfCheck.renames.rename(candidate, to: "Moved", followingCaptures: [])
    guard outcome.identityUpdatePending else { throw SelfTestFailure("Expected pending thought rename recovery") }
    let moved = pipeline.vault.root.appendingPathComponent(outcome.session.notePath)
    let before = try Data(contentsOf: moved)
    var rejected = false
    do { try await pipeline.setThought("blocked", forCapture: capture.id, inNoteAt: moved) } catch { rejected = true }
    guard rejected, try Data(contentsOf: moved) == before else { throw SelfTestFailure("Thought save bypassed pending rename recovery") }
    try FileManager.default.removeItem(at: stateFile)
    try await pipeline.setThought("recovered", forCapture: capture.id, inNoteAt: oldURL)
    guard try await pipeline.savedThought(forCapture: capture.id, inNoteAt: moved) == "recovered" else {
        throw SelfTestFailure("Thought save did not resolve recovered rename destination")
    }
}
