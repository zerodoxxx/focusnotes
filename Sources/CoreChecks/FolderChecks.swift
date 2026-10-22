import Core
import Foundation

func checkFolderRoutes() async throws {
    for raw in ["", "/Users/me", "~/notes", "C:/notes", "a\\b", "a//b", "a/", ".hidden", "a/..", "a/./b", " a", "a:b", "a\n", String(repeating: "x/", count: 30) + "x", String(repeating: "x", count: 121)] {
        do {
            _ = try NoteFolder(rawValue: raw)
            throw CheckFailure.failed("Accepted unsafe folder \(raw.debugDescription)")
        } catch is NotePathNameError { }
    }
    do {
        _ = try JSONDecoder().decode(NoteFolder.self, from: Data(#"{"rawValue":"../escape"}"#.utf8))
        throw CheckFailure.failed("Decoded an unsafe folder")
    } catch is DecodingError { }
    let folder = try NoteFolder(rawValue: "Work/Project")
    let encoded = try JSONEncoder().encode(folder)
    let decoded = try JSONDecoder().decode(NoteFolder.self, from: encoded)
    try require(decoded == folder, "Folder Codable round trip")
    let base = try checkMakeDirectory("folder-routes")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    let calendar = checkCalendar()
    let date = checkDate(2026, 10, 22, 14, 30)
    let state = base.appendingPathComponent("State")
    let sessions = SessionStore(stateDirectory: state, vault: vault, calendar: calendar, now: { date })
    let service = CaptureService(vault: vault, sessions: sessions,
                                 writer: NoteWriter(vault: vault, calendar: calendar), now: { date })
    _ = try await sessions.start(name: "Active")
    func capture(_ text: String) -> Capture {
        Capture(id: UUID(), createdAt: date, content: .note(text), source: CaptureSource())
    }
    let draft = capture("Topic\nbody")
    let prepared = try await service.prepareNote(draft, folder: folder, calendar: calendar)
    try require(prepared.destination.url.path.hasSuffix("/Work/Project/Topic.md"), "Folder overrides active session")
    try require(prepared.capture.content == .note("body"), "Folder note extracts first line")
    let reserved = try await service.prepareNote(draft, folder: folder, calendar: calendar)
    try require(reserved.destination == prepared.destination && reserved.createsNote != true, "Reserved folder path appends")
    let fresh = try await service.prepareNote(draft, newNote: true, folder: folder, calendar: calendar)
    try require(fresh.destination.url.lastPathComponent == "Topic 2.md", "Save as New honors reservations")
    let preview = try CaptureService.appendTarget(for: TypedNote(markdown: "Topic\nbody", createdAt: date, calendar: calendar),
                                                 reserved: service.reservedNoteURLs, vault: vault, folder: folder)
    try require(preview == prepared.destination, "Folder append preview matches preparation")
    let browse = Destination(url: vault.inboxURL, title: "Inbox", kind: .inbox)
    let explicit = try await service.prepareNote(draft, destination: browse, folder: folder, calendar: calendar)
    try require(explicit.destination == browse, "Browse overrides folder")
    let nested = try await service.prepareNote(capture("nested/Child\nchild body"), folder: folder, calendar: calendar)
    try require(nested.destination.url.path.hasSuffix("/Work/Project/nested/Child.md"), "Relative names stay inside folder")
    do {
        _ = try await service.prepareNote(capture("/outside/Topic\nbody"), folder: folder, calendar: calendar)
        throw CheckFailure.failed("Folder accepted home-relative note")
    } catch is NotePathNameError { }
    _ = try await sessions.start(name: "Changed")
    _ = try await service.save(prepared)
    let text = try checkRead(prepared.destination.url)
    try require(text.contains("body"), "Prepared folder destination survives active session change")
    let existing = try await service.prepareNote(draft, folder: folder, calendar: calendar)
    try require(existing.destination == prepared.destination && existing.createsNote != true, "Existing folder file appends")
    let newer = try await service.prepareNote(draft, newNote: true, folder: folder, calendar: calendar)
    try require(newer.destination.url.lastPathComponent == "Topic 3.md", "Save as New skips existing files and reservations")
    let inbox = try await service.prepareNote(capture("Inbox\nscoped inbox"), folder: folder, calendar: calendar)
    try require(inbox.destination.kind == .note && inbox.destination.url.path.hasSuffix("/Work/Project/Inbox.md"),
                "Folder Inbox title creates a scoped note")
    let ordinary = try await service.prepareNote(draft, calendar: calendar)
    try require(ordinary.destination.kind == .session, "Ordinary quick notes retain active session routing")
    try FileManager.default.removeItem(at: prepared.destination.url.deletingLastPathComponent())
    _ = try await service.save(nested)
    try require(FileManager.default.fileExists(atPath: nested.destination.url.path), "Save recreates removed nested folder")
    let first = try await sessions.start(in: folder)
    let second = try await sessions.start(in: folder)
    try require(first.notePath.hasPrefix("Sessions/Work/Project/") && second.notePath != first.notePath,
                "Folder sessions always create unique timestamp notes")
    try require(first.resumed == false && second.resumed == false, "Folder sessions never resume")
    let firstURL = vault.root.appendingPathComponent(first.notePath)
    let firstContents = try checkRead(firstURL)
    try require(firstContents.hasPrefix("# " + first.name), "Folder sessions create readable headers")
    let restored = SessionStore(stateDirectory: state, vault: vault, calendar: calendar, now: { date })
    let current = await restored.current()
    try require(current == second, "Folder session identity persists")
    let outside = base.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: vault.root.appendingPathComponent("Link"), withDestinationURL: outside)
    do {
        _ = try await service.prepareNote(draft, folder: NoteFolder(rawValue: "Link"), calendar: calendar)
        throw CheckFailure.failed("Folder quick note followed symlink")
    } catch let error as CocoaError {
        try require(error.code == .fileWriteInvalidFileName, "Quick-note symlink rejects unsafe destination")
    }
    try FileManager.default.createSymbolicLink(at: vault.root.appendingPathComponent("Sessions/Link"), withDestinationURL: outside)
    do {
        _ = try await sessions.start(in: NoteFolder(rawValue: "Link"))
        throw CheckFailure.failed("Folder session followed symlink")
    } catch is POSIXError { }
    let outsideFiles = try FileManager.default.contentsOfDirectory(atPath: outside.path)
    try require(outsideFiles.isEmpty, "Symlink targets remain untouched")
    print("PASS folder routes and sessions")
}
