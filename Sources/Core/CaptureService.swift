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

/// Note URLs reserved by unsaved typed notes. Locked so the editor can read it without awaiting.
final class ReservedNoteURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls = Set<URL>()

    var snapshot: Set<URL> { lock.lock(); defer { lock.unlock() }; return urls }
    func contains(_ url: URL) -> Bool { Self.match(url, in: snapshot) != nil }
    /// The reserved URL naming the same file as `url`; APFS is case-insensitive, so compare folded paths.
    static func match(_ url: URL, in urls: Set<URL>) -> URL? {
        func key(_ u: URL) -> String { u.standardizedFileURL.path.lowercased() }
        let wanted = key(url)
        return urls.sorted { $0.path < $1.path }.first { key($0) == wanted }
    }
    func insert(_ url: URL) { lock.lock(); urls.insert(url); lock.unlock() }
    func remove(_ url: URL) { lock.lock(); urls.remove(url); lock.unlock() }
}

/// Single entry point for saving captures: routes, writes the asset if any, then appends the block.
public actor CaptureService {
    private let vault: Vault
    private let sessions: SessionStore
    private let writer: NoteWriter
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let preparedNoteURLs = ReservedNoteURLs()

    /// URLs reserved by typed notes that are prepared but not yet saved.
    public nonisolated var reservedNoteURLs: Set<URL> { preparedNoteURLs.snapshot }

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

    /// Chooses the note for a typed capture, once. Unless `newNote` is set or the title is a
    /// generated timestamp, a name whose exact path exists, or was reserved earlier in
    /// this process, appends to it. Otherwise a new path is reserved. Replay saves this
    /// preparation without routing again, even if a file with the same name or a different
    /// session now exists. `outsideSession` bypasses the active session for this preparation
    /// only; explicit Browse destinations still take precedence and session state is untouched.
    public func prepareNote(_ capture: Capture, destination: Destination? = nil, newNote: Bool = false, outsideSession: Bool = false, folder: NoteFolder? = nil, calendar: Calendar) async throws -> PreparedCapture {
        if let destination { return PreparedCapture(capture: capture, destination: destination) }
        if folder == nil, !outsideSession, let active = await sessions.current() {
            return PreparedCapture(capture: capture, destination: try Router.destination(
                noteTitle: nil, activeSession: active, notes: [], vault: vault))
        }
        guard case .note(let markdown) = capture.content else {
            return try await prepare(capture, noteTitle: outsideSession ? Vault.inboxTitle : nil)
        }
        let note = TypedNote(markdown: markdown, createdAt: capture.createdAt, calendar: calendar)
        guard let parsedName = note.pathName else {
            throw note.pathNameError ?? NotePathNameError.invalidComponent
        }

        let pathName = try folder.map { try $0.scoped(parsedName) } ?? parsedName

        let noteCapture = Capture(id: capture.id, createdAt: capture.createdAt, content: .note(note.body), source: capture.source)
        // A title-only note has no body, so its text (the title line) is appended instead.
        let hasBody = !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let appendCapture = hasBody ? noteCapture : capture
        let appendsToMatch = !newNote && !note.isGeneratedTitle
        if appendsToMatch {
            if let target = try Self.appendTarget(for: note, reserved: preparedNoteURLs.snapshot, vault: vault, folder: folder) {
                return PreparedCapture(capture: appendCapture, destination: target, noteMarkerIsIdentity: true)
            }
        }

        var selectedName = pathName
        var location = try vault.resolveNoteName(selectedName)
        let locationExists = FileManager.default.fileExists(atPath: location.url.path)
        if !appendsToMatch, locationExists || preparedNoteURLs.contains(location.url) {
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

        let destinationTitle = selectedName == pathName ? note.title : selectedName.displayTitle
        let destination = Destination(url: location.url, title: destinationTitle, kind: .note)
        preparedNoteURLs.insert(destination.url)
        return PreparedCapture(capture: noteCapture, destination: destination, createsNote: true, noteMarkerIsIdentity: true)
    }

    /// The destination a default (not Save as New) typed save would append to, if any: Inbox for a bare
    /// "Inbox", else the exact resolved path when it exists on disk or was reserved. Generated titles never match.
    public static func appendTarget(for note: TypedNote, reserved: Set<URL>, vault: Vault, folder: NoteFolder? = nil) throws -> Destination? {
        guard !note.isGeneratedTitle else { return nil }
        guard let parsedName = note.pathName else {
            throw note.pathNameError ?? NotePathNameError.invalidComponent
        }
        let pathName = try folder.map { try $0.scoped(parsedName) } ?? parsedName
        if folder == nil, pathName.scope == .vault, pathName.components.count == 1,
           NoteTitle.matchKey(note.title) == NoteTitle.matchKey(Vault.inboxTitle) {
            return Destination(url: vault.inboxURL, title: Vault.inboxTitle, kind: .inbox)
        }
        let location = try vault.resolveNoteName(pathName)
        if FileManager.default.fileExists(atPath: location.url.path) {
            return Destination(url: location.url, title: note.title, kind: .note)
        }
        guard let held = ReservedNoteURLs.match(location.url, in: reserved) else { return nil }
        return Destination(url: held, title: note.title, kind: .note)
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
