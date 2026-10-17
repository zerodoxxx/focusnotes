import Foundation

public struct PreparedCapture: Codable, Sendable, Equatable {
    public let capture: Capture
    public let destination: Destination
    // Optional for journals written before independent typed notes existed.
    public let createsNote: Bool?

    public init(capture: Capture, destination: Destination, createsNote: Bool = false) {
        self.capture = capture
        self.destination = destination
        self.createsNote = createsNote ? true : nil
    }
}

public struct SavedCapture: Sendable, Equatable {
    public var captureID: UUID
    public var destination: Destination

    public init(captureID: UUID, destination: Destination) {
        self.captureID = captureID
        self.destination = destination
    }
}

/// Single entry point for saving captures: routes, writes the asset if any, then appends the block.
public actor CaptureService {
    private let vault: Vault
    private let sessions: SessionStore
    private let writer: NoteWriter
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private var preparedNoteURLs = Set<URL>()

    public init(
        vault: Vault,
        sessions: SessionStore,
        writer: NoteWriter,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.vault = vault
        self.sessions = sessions
        self.writer = writer
        self.now = now
        self.makeID = makeID
    }

    public func saveText(_ text: String, source: CaptureSource, heading: String?) async throws -> SavedCapture {
        let destination = try await route(heading: heading)
        let capture = Capture(id: makeID(), createdAt: now(), content: .text(text), source: source)
        try await writer.append(capture, to: destination.url, title: destination.title)
        return SavedCapture(captureID: capture.id, destination: destination)
    }

    public func saveImage(png: Data, source: CaptureSource, heading: String?) async throws -> SavedCapture {
        let destination = try await route(heading: heading)
        let createdAt = now()
        let assetPath = try await writer.saveImage(png: png, createdAt: createdAt)
        let capture = Capture(id: makeID(), createdAt: createdAt, content: .image(assetPath: assetPath), source: source)
        try await writer.append(capture, to: destination.url, title: destination.title)
        return SavedCapture(captureID: capture.id, destination: destination)
    }

    /// Resolve once, before writing. An unavailable vault must not prevent journaling a
    /// capture; when notes cannot be listed, Router still resolves a fixed destination.
    public func prepare(_ capture: Capture, heading: String?) async -> PreparedCapture {
        let notes = (try? vault.listNotes()) ?? []
        let active = await sessions.current()
        return PreparedCapture(capture: capture, destination: Router.destination(
            heading: heading, activeSession: active, notes: notes, vault: vault
        ))
    }

    /// Chooses the note for a typed capture, once. Unless `newNote` is set or the title is a
    /// generated timestamp, a title that names an existing note, or one reserved earlier in
    /// this process, appends to it. Otherwise a new root path is reserved. Replay saves this
    /// preparation without routing again.
    public func prepareNote(_ capture: Capture, destination: Destination? = nil, newNote: Bool = false, calendar: Calendar) async -> PreparedCapture {
        if let destination { return PreparedCapture(capture: capture, destination: destination) }
        if let active = await sessions.current() {
            return PreparedCapture(capture: capture, destination: Router.destination(
                heading: nil, activeSession: active, notes: [], vault: vault))
        }
        guard case .note(let markdown) = capture.content else { return await prepare(capture, heading: nil) }
        let note = TypedNote(markdown: markdown, createdAt: capture.createdAt, calendar: calendar)
        let noteCapture = Capture(id: capture.id, createdAt: capture.createdAt, content: .note(note.body), source: capture.source)
        if !newNote, !note.isGeneratedTitle {
            let notes = (try? vault.listNotes()) ?? []
            // A title-only note has no body, so its text (the title line) is appended instead.
            let hasBody = !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let appendCapture = hasBody ? noteCapture : capture
            if let existing = Router.existing(title: note.title, notes: notes, vault: vault) {
                return PreparedCapture(capture: appendCapture, destination: existing)
            }
            let reservedURLs = preparedNoteURLs.filter { url in
                let stem = url.deletingPathExtension().lastPathComponent
                return NoteTitle.names(note.title, title: stem, stem: stem)
            }
            if let reserved = reservedURLs.min(by: { $0.path < $1.path }) {
                return PreparedCapture(capture: appendCapture, destination: Destination(url: reserved, title: note.title, kind: .note))
            }
        }
        let destination = Destination(url: vault.uniqueNoteURL(forTitle: note.title, excluding: preparedNoteURLs), title: note.title, kind: .note)
        preparedNoteURLs.insert(destination.url)
        return PreparedCapture(capture: noteCapture, destination: destination, createsNote: true)
    }

    /// Saves an existing identity to its fixed destination without re-routing. Replaying
    /// after an append succeeded but journal cleanup failed does not add another block.
    public func save(_ prepared: PreparedCapture, png: Data? = nil) async throws -> SavedCapture {
        _ = try vault.writePath(of: prepared.destination.url)
        if prepared.createsNote == true { preparedNoteURLs.insert(prepared.destination.url) }
        try vault.prepare()
        try await writer.appendIfMissing(prepared.capture, to: prepared.destination, png: png, noteMarkerIsIdentity: prepared.createsNote == true)
        preparedNoteURLs.remove(prepared.destination.url)
        return SavedCapture(captureID: prepared.capture.id, destination: prepared.destination)
    }

    private func route(heading: String?) async throws -> Destination {
        try vault.prepare()
        let notes = try vault.listNotes()
        let active = await sessions.current()
        return Router.destination(heading: heading, activeSession: active, notes: notes, vault: vault)
    }
}
