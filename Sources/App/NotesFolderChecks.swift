import AppKit
import Core

@MainActor
func checkNotesFolder() async throws {
    let suite = "notes-folder-check-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw SelfTestFailure("Could not create folder preferences") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(suite, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let original = temporary.appendingPathComponent("Original", isDirectory: true)
    let other = temporary.appendingPathComponent("Other", isDirectory: true)
    let base = temporary.appendingPathComponent("State", isDirectory: true)
    try NotesFolder.save(original, defaults: defaults)
    guard NotesFolder.configuredRoot(defaults: defaults) == original,
          NotesFolder.startupRoot(defaults: defaults) == original else {
        throw SelfTestFailure("An existing configured folder was not preserved at startup")
    }
    let originalState = try NotesFolder.stateDirectory(for: original, base: base)
    guard originalState == base else { throw SelfTestFailure("Existing vault state was relocated") }

    let file = original.appendingPathComponent("file.txt")
    try Data("unchanged".utf8).write(to: file)
    do {
        try NotesFolder.save(file, defaults: defaults)
        throw SelfTestFailure("A regular file was accepted as the notes folder")
    } catch is CocoaError {}
    guard NotesFolder.configuredRoot(defaults: defaults) == original,
          try String(contentsOf: file, encoding: .utf8) == "unchanged" else {
        throw SelfTestFailure("Invalid folder selection changed preferences or existing content")
    }

    let pipeline = try await CapturePipeline.open(vaultRoot: original, stateDirectory: originalState, calendar: .current)
    let session = try await pipeline.sessions.start(name: "Original session")
    try pipeline.drafts.store("Original draft")
    try pipeline.pins.set(session.notePath, pinned: true)
    let capture = PendingCapture(trigger: .selection, content: .text("original pending capture"),
                                 source: CaptureSource(appName: "Folder checks"), subtitle: "check")
    let job = try await pipeline.prepare(capture, noteTitle: nil)
    try await pipeline.journal.store(job)
    _ = try await pipeline.index.sync()
    try NotesFolder.save(other, defaults: defaults)
    let otherState = try NotesFolder.stateDirectory(for: other, base: base)
    let otherPipeline = try await CapturePipeline.open(vaultRoot: other, stateDirectory: otherState, calendar: .current,
                                                     modelsDirectory: base.appendingPathComponent("models", isDirectory: true))
    let otherSession = await otherPipeline.sessions.current()
    let otherJobs = try await otherPipeline.journal.recordURLs()
    let otherHits = try await otherPipeline.index.titleSuggestions(prefix: "", limit: 20)
    guard otherState != originalState, otherSession == nil, otherJobs.isEmpty, otherHits.isEmpty,
          try otherPipeline.drafts.load().isEmpty, otherPipeline.pins.paths().isEmpty,
          try NotesFolder.stateDirectory(for: other, base: base) == otherState else {
        throw SelfTestFailure("Changing notes folders leaked state from the original folder")
    }
    guard await pipeline.sessions.current() == session,
          try pipeline.drafts.load() == "Original draft",
          pipeline.pins.isPinned(session.notePath),
          try await pipeline.journal.recordURLs().count == 1 else {
        throw SelfTestFailure("Changing notes folders altered the running pipeline")
    }
    try NotesFolder.save(original, defaults: defaults)
    let restoredState = try NotesFolder.stateDirectory(for: original, base: base)
    let restored = try await CapturePipeline.open(vaultRoot: original, stateDirectory: restoredState, calendar: .current)
    guard restoredState == base, await restored.sessions.current() == session,
          try restored.drafts.load() == "Original draft", restored.pins.isPinned(session.notePath),
          try await restored.journal.recordURLs().count == 1 else {
        throw SelfTestFailure("Returning to a notes folder did not preserve its state")
    }
    let aliases = temporary.appendingPathComponent("Alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: aliases, withDestinationURL: original)
    guard try NotesFolder.stateDirectory(for: aliases, base: base) == originalState else {
        throw SelfTestFailure("A folder alias unexpectedly created a separate state directory")
    }
    let missing = temporary.appendingPathComponent("Detached", isDirectory: true)
    let missingState = temporary.appendingPathComponent("DetachedState", isDirectory: true)
    guard try NotesFolder.stateDirectory(for: missing, base: missingState) == missingState,
          try NotesFolder.stateDirectory(for: other, base: missingState) != missingState else {
        throw SelfTestFailure("An unavailable original folder assigned its legacy state to a replacement")
    }
    try NotesFolder.save(missing, defaults: defaults)
    guard try NotesFolder.stateDirectory(for: missing, base: missingState) == missingState else {
        throw SelfTestFailure("Restoring the original folder did not restore its state")
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: original.path)
    guard !leftovers.contains(where: { $0.hasPrefix(".focusnotes-write-test-") }) else {
        throw SelfTestFailure("Notes folder validation left its probe behind")
    }
    defaults.removePersistentDomain(forName: suite)
    guard try NotesFolder.stateDirectory(for: other, base: base) == otherState else {
        throw SelfTestFailure("Resetting preferences reassigned existing vault state")
    }
    let marker = base.appendingPathComponent("legacy-vault-root.json")
    for contents in ["{ invalid", "null", "\"\"", "{\"configuredPath\":\"relative\"}"] {
        try Data(contents.utf8).write(to: marker)
        do {
            _ = try NotesFolder.stateDirectory(for: other, base: base)
            throw SelfTestFailure("Invalid state mapping was accepted")
        } catch is SelfTestFailure { throw SelfTestFailure("Invalid state mapping was accepted") }
        catch {}
        guard try String(contentsOf: marker, encoding: .utf8) == contents else {
            throw SelfTestFailure("Invalid state mapping was overwritten")
        }
    }
}
