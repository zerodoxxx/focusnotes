import Core
import Foundation

@MainActor
func checkFolderShortcutActions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-shortcut-actions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"),
        stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let controller = AppController(pipeline: pipeline, presentsUI: false)
    let folder = try NoteFolder(rawValue: "Science/Research")
    let active = try await controller.startSession(name: "Existing session")
    let activeURL = pipeline.vault.root.appendingPathComponent(active.notePath)
    let before = try Data(contentsOf: activeURL)
    guard let saved = try await controller.addNote("Experiment\nObservations", outsideSession: true, folder: folder),
          saved.destination.url.path.hasSuffix("/Science/Research/Experiment.md"),
          await pipeline.sessions.current() == active,
          try Data(contentsOf: activeURL) == before,
          try pipeline.drafts.load().isEmpty else {
        throw SelfTestFailure("Folder quick note failed to override routing without changing the session")
    }
    let first = try await controller.startFolderSession(in: folder)
    let second = try await controller.startFolderSession(in: folder)
    guard first.notePath.hasPrefix("Sessions/Science/Research/"), first.notePath != second.notePath,
          await pipeline.sessions.current() == second else {
        throw SelfTestFailure("Folder shortcut did not activate a fresh automatically named session")
    }
    let ordinary = try await controller.addNote("Ordinary capture")
    guard ordinary?.destination.url == pipeline.vault.root.appendingPathComponent(second.notePath) else {
        throw SelfTestFailure("Ordinary notes did not follow the newly activated folder session")
    }

    // Replay retains its exact folder while a same-text newer draft has another destination.
    let text = "Replay topic\nPending observations"
    let capture = Capture(id: UUID(), createdAt: Date(), content: .note(text), source: CaptureSource())
    let prepared = try await pipeline.prepareNote(capture, destination: nil, newNote: false, folder: folder)
    let job = CaptureJob(prepared: prepared, png: nil, ocr: nil, noteDraft: text,
                         noteOutsideSession: true, noteFolder: folder)
    try await pipeline.journal.store(job)
    let records = try await pipeline.journal.recordURLs()
    guard let record = records.first else { throw SelfTestFailure("Folder note did not journal") }
    let reloaded = try await pipeline.journal.load(record: record)
    guard reloaded.noteFolder == folder, reloaded.prepared.destination == prepared.destination else {
        throw SelfTestFailure("Folder note journal lost its destination context")
    }
    let other = try NoteFolder(rawValue: "Other")
    try pipeline.drafts.store(text, pinOnSave: true, folder: other)
    _ = try await pipeline.commit(reloaded)
    let retained = try pipeline.drafts.loadSnapshot()
    guard retained.text == text, retained.folder == other, retained.pinOnSave,
          !pipeline.pins.isPinned(try pipeline.vault.noteID(for: prepared.destination.url)) else {
        throw SelfTestFailure("Folder journal replay consumed another folder's draft or pin intent")
    }

    let state = QuickNoteState(destination: nil, folder: folder)
    state.destination = Destination(url: pipeline.vault.inboxURL, title: "Inbox", kind: .inbox)
    try state.restoreSessionDestination(ordinary?.destination, drafts: pipeline.drafts)
    guard state.destination == nil, state.folder == folder, state.outsideSession,
          state.destinationLabel == "Folder: Science/Research" else {
        throw SelfTestFailure("New note reset lost the shortcut folder")
    }
}
