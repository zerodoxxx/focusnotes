import Core
import Foundation
import AppKit
import CaptureKit
@_spi(Checks) import OverlayKit

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
    let first = try await controller.startFolderSession(name: "Experiment review", in: folder)
    let second = try await controller.startFolderSession(name: "Experiment review", in: folder)
    guard first.notePath == "Sessions/Science/Research/Experiment review.md", first.notePath == second.notePath,
          second.resumed == true,
          await pipeline.sessions.current() == second else {
        throw SelfTestFailure("Folder shortcut did not create and resume the named session inside its folder")
    }
    do {
        _ = try await controller.startFolderSession(name: " \n\t ", in: folder)
        throw SelfTestFailure("Blank folder-session name created a session")
    } catch NotePathNameError.emptyPath { }
    guard await pipeline.sessions.current() == second else {
        throw SelfTestFailure("Blank folder-session name changed the active session")
    }
    guard AppController.sessionPath(second.notePath, isIn: folder),
          AppController.sessionPath("Sessions/science/research/Other.md", isIn: folder),
          !AppController.sessionPath("Sessions/Science/Research/Nested/Other.md", isIn: folder),
          !AppController.sessionPath("Sessions/Other/Experiment review.md", isIn: folder) else {
        throw SelfTestFailure("Folder session suggestions included a different folder")
    }

    let binding = FolderShortcut(hotkey: Hotkey(keyCode: 11, modifiers: [.command, .option]),
                                action: .startSession, folder: folder.rawValue)
    for code in [UInt16(53), UInt16(36)] {
        controller.runFolderShortcut(binding)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.inputForChecks == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let input = controller.inputForChecks,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                  windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else {
            throw SelfTestFailure("Folder shortcut did not ask for a session name")
        }
        _ = input.handleKeyForChecks(event)
        while controller.inputForChecks != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard controller.inputForChecks == nil, await pipeline.sessions.current() == second else {
            throw SelfTestFailure("Cancel or blank session prompt changed the active session")
        }
    }
    let ordinary = try await controller.addNote("Ordinary capture")
    guard ordinary?.destination.url == pipeline.vault.root.appendingPathComponent(second.notePath) else {
        throw SelfTestFailure("Ordinary notes did not follow the newly activated folder session")
    }

    // Display titles can differ from filenames (including dated legacy sessions).
    // Choosing the suggestion must retain the exact path, rather than create a title-derived sibling.
    let selectedURL = pipeline.vault.root.appendingPathComponent(second.notePath)
    let selectedMarkdown = try String(contentsOf: selectedURL, encoding: .utf8)
    try selectedMarkdown.replacingOccurrences(of: "# Experiment review\n", with: "# Visible review\n")
        .write(to: selectedURL, atomically: true, encoding: .utf8)
    try await pipeline.index.reindex(note: selectedURL)
    controller.runFolderShortcut(binding)
    let selectionDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while controller.inputForChecks == nil, ContinuousClock.now < selectionDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    for code in [UInt16(125), UInt16(36)] {
        guard let input = controller.inputForChecks,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                  windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else {
            throw SelfTestFailure("Folder session suggestion was not presented")
        }
        _ = input.handleKeyForChecks(event)
        if code == 125, input.selectedValueForChecks != "/" + second.notePath {
            throw SelfTestFailure("Folder session suggestion lost its exact path identity")
        }
    }
    while await pipeline.sessions.current()?.name != "Visible review", ContinuousClock.now < selectionDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard await pipeline.sessions.current()?.notePath == second.notePath,
          await pipeline.sessions.current()?.name == "Visible review",
          !FileManager.default.fileExists(atPath: selectedURL.deletingLastPathComponent().appendingPathComponent("Visible review.md").path) else {
        throw SelfTestFailure("Choosing a folder session by its display title created a sibling instead of resuming its exact path")
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
          state.folderLabel == "Folder: Science/Research" else {
        throw SelfTestFailure("New note reset lost the shortcut folder")
    }

    // The folder only titles the blank editor; it is not a chosen note, so the typed name resolves inside it.
    // That drives the footer (Add to note) and Save as New Note, which numbers a copy in the same folder.
    let existing = TypedNote(markdown: "Experiment\nFollow-up observations", createdAt: Date(), calendar: .current)
    guard state.destinationLabel == nil,
          try CaptureService.appendTarget(for: existing, reserved: pipeline.service.reservedNoteURLs, vault: pipeline.vault, folder: folder)?.title == "Experiment",
          try CaptureService.appendTarget(for: existing, reserved: pipeline.service.reservedNoteURLs, vault: pipeline.vault) == nil else {
        throw SelfTestFailure("Folder quick note did not resolve its typed name inside the folder")
    }
    guard let copy = try await controller.addNote("Experiment\nFollow-up observations", newNote: true, outsideSession: true, folder: folder),
          copy.destination.url.path.hasSuffix("/Science/Research/Experiment 2.md"),
          await pipeline.sessions.current()?.notePath == second.notePath else {
        throw SelfTestFailure("Save as New Note in a folder quick note did not create a numbered note in the folder")
    }
}
