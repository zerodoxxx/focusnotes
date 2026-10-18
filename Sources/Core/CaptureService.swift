import Foundation

public struct PreparedCapture: Codable, Sendable, Equatable {
    public let capture: Capture
    public let destination: Destination
    // Optional for journals written before independent typed notes existed.
    public let createsNote: Bool?
    // Independent typed notes keep their identity marker when appending to an
    // existing file. Older journals used createsNote for the same purpose.
    public let noteMarkerIsIdentity: Bool?

    public init(capture: Capture, destination: Destination, createsNote: Bool = false, noteMarkerIsIdentity: Bool = false) {
        self.capture = capture
        self.destination = destination
        self.createsNote = createsNote ? true : nil
        self.noteMarkerIsIdentity = noteMarkerIsIdentity ? true : nil
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

    public func saveText(_ text: String, source: CaptureSource, noteTitle: String?) async throws -> SavedCapture {
        let destination = try await route(noteTitle: noteTitle)
        try registerExternalLocation(for: destination)
        let capture = Capture(id: makeID(), createdAt: now(), content: .text(text), source: source)
        try await writer.append(capture, to: destination.url, title: destination.title)
        return SavedCapture(captureID: capture.id, destination: destination)
    }

    public func saveImage(png: Data, source: CaptureSource, noteTitle: String?) async throws -> SavedCapture {
        let destination = try await route(noteTitle: noteTitle)
        try registerExternalLocation(for: destination)
        let createdAt = now()
        let assetPath = try await writer.saveImage(png: png, createdAt: createdAt)
        let capture = Capture(id: makeID(), createdAt: createdAt, content: .image(assetPath: assetPath), source: source)
        try await writer.append(capture, to: destination.url, title: destination.title)
        return SavedCapture(captureID: capture.id, destination: destination)
    }

    /// Resolve once, before writing. A detached or unreadable vault volume must
    /// not prevent journaling a deterministic destination. Registry failures
    /// remain visible so a capture cannot be routed around unseen external notes.
    public func prepare(_ capture: Capture, noteTitle: String?) async throws -> PreparedCapture {
        let notes = try Self.loadNotesForRouting(
            registrySnapshot: {
                guard let snapshot = try vault.externalRegistrySnapshot() else { return nil }
                return (paths: snapshot.paths, value: snapshot)
            },
            loadNotes: { snapshot in
                try vault.listNotes(externalRegistrySnapshot: snapshot)
            }
        )
        let active = await sessions.current()
        return PreparedCapture(capture: capture, destination: try Router.destination(
            noteTitle: noteTitle, activeSession: active, notes: notes, vault: vault
        ))
    }

    /// Resolve once. Replay saves this preparation without routing again, even
    /// if a file with the same name or a different session now exists.
    public func prepareNote(_ capture: Capture, destination: Destination? = nil, calendar: Calendar) async throws -> PreparedCapture {
        if let destination { return PreparedCapture(capture: capture, destination: destination) }
        if let active = await sessions.current() {
            return PreparedCapture(capture: capture, destination: try Router.destination(
                noteTitle: nil, activeSession: active, notes: [], vault: vault))
        }
        guard case .note(let markdown) = capture.content else { return try await prepare(capture, noteTitle: nil) }
        let note = TypedNote(markdown: markdown, createdAt: capture.createdAt, calendar: calendar)
        guard let pathName = note.pathName else {
            throw note.pathNameError ?? NotePathNameError.invalidComponent
        }

        var selectedName = pathName
        var location = try vault.resolveNoteName(selectedName)
        if !FileManager.default.fileExists(atPath: location.url.path), preparedNoteURLs.contains(location.url) {
            var suffix = 2
            while true {
                var components = pathName.components
                components[components.count - 1] = NoteTitle.fileStem(for: "\(pathName.leafName) \(suffix)")
                let reservedName = try NotePathName.validated(scope: pathName.scope, components: components)
                let candidate = try vault.resolveNoteName(reservedName)
                if !preparedNoteURLs.contains(candidate.url), !FileManager.default.fileExists(atPath: candidate.url.path) {
                    selectedName = reservedName
                    location = candidate
                    break
                }
                suffix += 1
            }
        }

        let createsNote = !FileManager.default.fileExists(atPath: location.url.path)
        let destinationTitle = selectedName == pathName ? note.title : selectedName.displayTitle
        let destination = Destination(url: location.url, title: destinationTitle, kind: .note)
        preparedNoteURLs.insert(destination.url)
        let body = Capture(id: capture.id, createdAt: capture.createdAt, content: .note(note.body), source: capture.source)
        return PreparedCapture(capture: body, destination: destination, createsNote: createsNote, noteMarkerIsIdentity: true)
    }

    /// Saves an existing identity to its fixed destination without re-routing. Replaying
    /// after an append succeeded but journal cleanup failed does not add another block.
    public func save(_ prepared: PreparedCapture, png: Data? = nil) async throws -> SavedCapture {
        try registerExternalLocation(for: prepared.destination)
        if prepared.createsNote == true { preparedNoteURLs.insert(prepared.destination.url) }
        try vault.prepare()
        try await writer.appendIfMissing(prepared.capture, to: prepared.destination, png: png,
                                         noteMarkerIsIdentity: prepared.noteMarkerIsIdentity == true || prepared.createsNote == true)
        preparedNoteURLs.remove(prepared.destination.url)
        return SavedCapture(captureID: prepared.capture.id, destination: prepared.destination)
    }

    private func route(noteTitle: String?) async throws -> Destination {
        try vault.prepare()
        let notes = try vault.listNotes()
        let active = await sessions.current()
        return try Router.destination(noteTitle: noteTitle, activeSession: active, notes: notes, vault: vault)
    }

    private func registerExternalLocation(for destination: Destination) throws {
        let managed = try vault.managedLocation(of: destination.url)
        if managed.scope == .home { try vault.registerExternalNote(managed.note) }
    }

    /// Validates registry state before allowing the unavailable-volume fallback.
    @_spi(Checks)
    public static func loadNotesForRouting<Snapshot>(
        registrySnapshot: () throws -> (paths: [String], value: Snapshot)?,
        loadNotes: (Snapshot?) throws -> [NoteRef]
    ) throws -> [NoteRef] {
        let snapshot = try registrySnapshot()
        do {
            return try loadNotes(snapshot?.value)
        } catch let error as ExternalNoteRegistryError {
            throw error
        } catch let error as POSIXError where isUnavailableVaultVolume(error.code) {
            guard snapshot?.paths.isEmpty ?? true else { throw error }
            return []
        }
    }

    private static func isUnavailableVaultVolume(_ code: POSIXErrorCode) -> Bool {
        code == .EIO || code == .ENODEV || code == .ENXIO
    }
}
