import Foundation

public struct Session: Codable, Sendable, Equatable {
    public var name: String
    /// Vault-relative path, for example `Sessions/Design.md`.
    public var notePath: String
    public var resumed: Bool?
    public var startedAt: Date

    public init(name: String, notePath: String, startedAt: Date) {
        self.name = name
        self.notePath = notePath
        self.startedAt = startedAt
        self.resumed = nil
    }
}

/// Holds the active session and persists it to `stateDirectory/session.json`.
public actor SessionStore {
    private static let stateFileName = "session.json"

    private let stateDirectory: URL
    private let vault: Vault
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let beforeNoteWrite: @Sendable (String) -> Void
    private var session: Session?

    public init(
        stateDirectory: URL,
        vault: Vault,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date,
        beforeNoteWrite: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.stateDirectory = stateDirectory
        self.vault = vault
        self.calendar = calendar
        self.now = now
        self.beforeNoteWrite = beforeNoteWrite
        self.session = Self.load(from: stateDirectory.appendingPathComponent(Self.stateFileName))
    }

    public func current() -> Session? {
        session
    }

    /// Starts a session, replacing any active one. Resumes a session note by its exact file name
    /// (regardless of case), then by its title or file name, then by a legacy dated file name.
    public func start(name: String) throws -> Session {
        let cleaned = NoteTitle.cleanTitle(name)
        let title = cleaned.isEmpty ? "Session" : cleaned

        try vault.prepare()
        let current = now()
        let stem = NoteTitle.fileStem(for: title)
        let existing = try vault.listNotes().filter { $0.kind == .session }
            .compactMap { note -> (rank: Int, note: NoteRef)? in
                let existingStem = note.url.deletingPathExtension().lastPathComponent
                if existingStem.caseInsensitiveCompare(stem) == .orderedSame { return (rank: 0, note: note) }
                if NoteTitle.names(title, title: note.title, stem: existingStem) { return (rank: 1, note: note) }
                // Legacy dated notes remain in place and can be resumed by their title.
                let prefix = existingStem.prefix(11)
                guard prefix.count == 11, prefix.last == " ", prefix.dropLast().enumerated().allSatisfy({
                    [4, 7].contains($0.offset) ? $0.element == "-" : $0.element.isNumber
                }) else { return nil }
                guard String(existingStem.dropFirst(11)).caseInsensitiveCompare(stem) == .orderedSame else { return nil }
                return (rank: 2, note: note)
            }
            .min { left, right in
                if left.rank != right.rank { return left.rank < right.rank }
                return left.note.url.lastPathComponent > right.note.url.lastPathComponent
            }?.note
        let fileName = existing?.url.lastPathComponent ?? "\(stem).md"
        var displayTitle: String?
        if existing != nil {
            let relativePath = "\(Vault.sessionsDirectoryName)/\(fileName)"
            if let prefix = try NoteFile.readManagedPrefix(4096, in: vault.rootAnchor, relativePath: relativePath) {
                let firstLineData = prefix.prefix { $0 != 0x0A }
                var firstLine = String(decoding: firstLineData, as: UTF8.self)
                if firstLine.hasPrefix("\u{FEFF}") { firstLine.removeFirst() }
                if firstLine.hasPrefix("# ") {
                    displayTitle = NoteTitle.cleanTitle(String(firstLine.dropFirst(2)))
                }
            }
        }
        let sessionTitle = displayTitle.flatMap { $0.isEmpty ? nil : $0 } ?? title
        beforeNoteWrite("\(Vault.sessionsDirectoryName)/\(fileName)")
        try NoteFile.create(Data(CaptureFormat.noteHeader(title: title).utf8), in: vault.rootAnchor,
                            relativePath: "\(Vault.sessionsDirectoryName)/\(fileName)")

        var started = Session(
            name: sessionTitle,
            notePath: "\(Vault.sessionsDirectoryName)/\(fileName)",
            startedAt: current
        )
        started.resumed = existing != nil
        try persist(started)
        session = started
        return started
    }

    /// Ends the active session and deletes the state file.
    public func end() throws {
        let url = stateFileURL
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // Ending an already ended session is harmless. Other I/O errors retain it.
        }
        session = nil
    }

    private var stateFileURL: URL {
        stateDirectory.appendingPathComponent(Self.stateFileName)
    }

    private func persist(_ session: Session) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: stateFileURL, options: .atomic)
    }

    /// A missing or corrupt state file loads as no session.
    private static func load(from url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Session.self, from: data)
    }
}
