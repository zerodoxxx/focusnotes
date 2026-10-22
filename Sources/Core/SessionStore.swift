import Foundation

public struct ManagedFileIdentity: Codable, Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
    public init(_ snapshot: VaultFileSnapshot) { self.init(device: snapshot.device, inode: snapshot.inode) }
}

public struct SessionRenameStage: Codable, Sendable {
    public let original: ManagedFileIdentity
    public let installed: ManagedFileIdentity
    public let temporaryName: String
}

public struct SessionRenameOutcome: Sendable {
    public let session: Session
    public let identityUpdatePending: Bool
    public init(session: Session, identityUpdatePending: Bool) {
        self.session = session; self.identityUpdatePending = identityUpdatePending
    }
}

@_spi(Checks) public enum SessionRenameInterruption: Error { case afterSwap }

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

/// A session that can be selected when a bare name matches more than one note.
public struct SessionCandidate: Sendable, Equatable {
    public let name: String
    /// Vault-relative path, including the `Sessions/` prefix.
    public let notePath: String
    public let modifiedAt: Date

    public init(name: String, notePath: String, modifiedAt: Date) {
        self.name = name
        self.notePath = notePath
        self.modifiedAt = modifiedAt
    }
}

public enum SessionStoreError: Error, Sendable, LocalizedError {
    case ambiguous([SessionCandidate])
    case candidateNoLongerExists(String)
    case invalidRename
    case renameConflict
    case caseOnlyRename

    public var errorDescription: String? {
        switch self {
        case .ambiguous:
            return "Several sessions match this name."
        case .candidateNoLongerExists(let path):
            return "The selected session no longer exists at \(path)."
        case .invalidRename:
            return "Enter a session name without folder separators."
        case .renameConflict:
            return "A file with that name already exists in this folder."
        case .caseOnlyRename:
            return "Choose a name that changes more than letter casing."
        }
    }
}

/// Holds the active session and persists it to `stateDirectory/session.json`.
public actor SessionStore {
    private static let stateFileName = "session.json"

    private struct ExistingSession {
        let note: NoteRef
        let notePath: String
    }

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

    /// Starts a session, resuming a unique matching filename or creating a note.
    /// Qualified names such as `archive/Standup` are rooted inside `Sessions/`.
    public func start(name: String) throws -> Session {
        try vault.prepare()
        let cleaned = NoteTitle.cleanTitle(name)

        if cleaned.contains("/") {
            let parsed: Result<NotePathName, NotePathNameError>
            do {
                parsed = .success(try NoteTitle.pathName(for: name))
            } catch let error as NotePathNameError {
                parsed = .failure(error)
            } catch { throw error }
            let pathName: NotePathName
            switch parsed {
            case .success(let value):
                if NoteTitle.canFallBackToFlatName(name, error: nil) {
                    return try startFlat(title: cleaned, existingSessions: existingSessions())
                }
                pathName = value
            case .failure(let error):
                guard NoteTitle.canFallBackToFlatName(name, error: error) else { throw error }
                return try startFlat(title: cleaned, existingSessions: existingSessions())
            }
            guard pathName.scope == .vault else { throw NotePathNameError.invalidComponent }
            let sessionPath = try NotePathName.validated(
                scope: .vault,
                components: [Vault.sessionsDirectoryName] + pathName.components
            )
            let location = try vault.resolveNoteName(sessionPath)
            let existing = try existingSessions().first { $0.notePath == location.relativePath }
            return try start(
                title: pathName.leafName,
                notePath: location.relativePath,
                existing: existing
            )
        }

        return try startFlat(title: cleaned, existingSessions: existingSessions())
    }

    private func startFlat(title rawTitle: String, existingSessions: [ExistingSession]) throws -> Session {
        let title = rawTitle.isEmpty ? "Session" : rawTitle
        let stem = NoteTitle.fileStem(for: title)
        let matches = existingSessions.filter { note in
            let existingStem = note.note.url.deletingPathExtension().lastPathComponent
            if existingStem.caseInsensitiveCompare(stem) == .orderedSame { return true }
            return Self.isDatedSession(existingStem, matching: stem)
        }

        if matches.count > 1 {
            throw SessionStoreError.ambiguous(try candidates(from: matches))
        }

        let existing = matches.first
        let notePath = existing?.notePath ?? "\(Vault.sessionsDirectoryName)/\(stem).md"
        return try start(title: existing?.note.title ?? title, notePath: notePath, existing: existing)
    }

    /// Resumes the exact candidate shown to the user. A deleted or changed
    /// candidate fails without creating a replacement note.
    public func resume(_ candidate: SessionCandidate) throws -> Session {
        try vault.prepare()
        guard let existing = try existingSessions().first(where: { $0.notePath == candidate.notePath }) else {
            throw SessionStoreError.candidateNoLongerExists(candidate.notePath)
        }
        return try start(title: existing.note.title, notePath: existing.notePath, existing: existing)
    }

    /// Renaming stays in the candidate's folder; this deliberately does not use
    /// start(name:), whose qualified names may create directories or new notes.
    public func rename(_ candidate: SessionCandidate, to rawName: String,
                       beforeInstall: @Sendable (SessionRenameStage) throws -> Void = { _ in },
                       afterSwap: (@Sendable () throws -> Void)? = nil) throws -> Session {
        let destination = try renameDestination(candidate, to: rawName)
        do {
            try NoteFile.renameSession(in: vault.rootAnchor, relativePath: candidate.notePath,
                                       newName: (destination.notePath as NSString).lastPathComponent,
                                       title: destination.name, beforeInstall: beforeInstall, afterSwap: afterSwap)
        } catch let error as POSIXError where error.code == .EEXIST { throw SessionStoreError.renameConflict }
        // The file is already committed. Keep the in-memory identity current even
        // if persisting state fails; the app's rename intent repairs it on retry.
        session = destination
        try persist(destination)
        return destination
    }

    public func renameDestination(_ candidate: SessionCandidate, to rawName: String) throws -> Session {
        try vault.prepare()
        guard !rawName.contains("/"), !rawName.contains("\\"), !rawName.contains("\0") else {
            throw SessionStoreError.invalidRename
        }
        let title = NoteTitle.cleanTitle(rawName)
        guard !title.isEmpty, title != ".", title != ".." else { throw SessionStoreError.invalidRename }
        let stem = NoteTitle.fileStem(for: title)
        guard !stem.hasPrefix("~$") else { throw SessionStoreError.invalidRename }
        try requireSession(at: candidate.notePath)
        let directory = (candidate.notePath as NSString).deletingLastPathComponent
        do {
            _ = try NotePathName.validated(scope: .vault, components: directory.split(separator: "/").map(String.init) + [stem])
        } catch { throw SessionStoreError.invalidRename }
        var renamed = Session(name: title, notePath: directory + "/" + stem + ".md", startedAt: now())
        renamed.resumed = true
        return renamed
    }

    /// Completes persisted identity migration after a committed file rename.
    public func recoverRenamedSession(_ renamed: Session) throws {
        try requireSession(at: renamed.notePath)
        session = renamed
        try persist(renamed)
    }

    private func requireSession(at path: String) throws {
        guard path.hasPrefix(Vault.sessionsDirectoryName + "/"),
              try existingSessions().contains(where: { $0.notePath == path }) else {
            throw SessionStoreError.candidateNoLongerExists(path)
        }
    }

    public func cleanupRenameTemporary(_ stage: SessionRenameStage, in session: Session) throws {
        let parent = (session.notePath as NSString).deletingLastPathComponent
        try NoteFile.removeSessionTemporary(in: vault.rootAnchor, relativePath: parent + "/" + stage.temporaryName,
                                            identities: [stage.original, stage.installed])
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

    private func existingSessions() throws -> [ExistingSession] {
        try vault.listNotes().filter { $0.kind == .session }.map { note in
            ExistingSession(note: note, notePath: try vault.noteID(for: note.url))
        }
    }

    private func candidates(from matches: [ExistingSession]) throws -> [SessionCandidate] {
        var modifiedByPath: [String: Date] = [:]
        for file in try vault.listNoteFiles() where file.kind == .session {
            guard let snapshot = file.snapshot else { continue }
            modifiedByPath[file.id] = snapshot.modifiedAt
        }

        return matches.map { match in
            SessionCandidate(
                name: match.note.title,
                notePath: match.notePath,
                modifiedAt: modifiedByPath[match.notePath] ?? .distantPast
            )
        }.sorted { left, right in
            if left.modifiedAt != right.modifiedAt { return left.modifiedAt > right.modifiedAt }
            return left.notePath < right.notePath
        }
    }

    private func start(title: String, notePath: String, existing: ExistingSession?) throws -> Session {
        let current = now()
        let displayTitle: String
        if let existing {
            displayTitle = try readTitle(at: notePath) ?? existing.note.title
        } else {
            displayTitle = title
        }
        let directory = (notePath as NSString).deletingLastPathComponent
        if directory != Vault.sessionsDirectoryName {
            try NoteFile.prepareManagedDirectory(directory, in: vault.rootAnchor)
        }
        beforeNoteWrite(notePath)
        try NoteFile.create(Data(CaptureFormat.noteHeader(title: title).utf8), in: vault.rootAnchor,
                            relativePath: notePath)

        var started = Session(name: displayTitle, notePath: notePath, startedAt: current)
        started.resumed = existing != nil
        try persist(started)
        session = started
        return started
    }

    private func readTitle(at notePath: String) throws -> String? {
        guard let prefix = try NoteFile.readManagedPrefix(4096, in: vault.rootAnchor, relativePath: notePath) else {
            return nil
        }
        let firstLineData = prefix.prefix { $0 != 0x0A }
        var firstLine = String(decoding: firstLineData, as: UTF8.self)
        if firstLine.hasPrefix("\u{FEFF}") { firstLine.removeFirst() }
        guard firstLine.hasPrefix("# ") else { return nil }
        let title = NoteTitle.cleanTitle(String(firstLine.dropFirst(2)))
        return title.isEmpty ? nil : title
    }

    private static func isDatedSession(_ existingStem: String, matching stem: String) -> Bool {
        let prefix = existingStem.prefix(11)
        guard prefix.count == 11, prefix.last == " ", prefix.dropLast().enumerated().allSatisfy({
            [4, 7].contains($0.offset) ? $0.element == "-" : $0.element.isNumber
        }) else { return false }
        return String(existingStem.dropFirst(11)).caseInsensitiveCompare(stem) == .orderedSame
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
