import Foundation

public struct Destination: Codable, Sendable, Equatable {
    public var url: URL
    public var title: String
    public var kind: NoteKind

    public init(url: URL, title: String, kind: NoteKind) {
        self.url = url
        self.title = title
        self.kind = kind
    }
}

public enum RouterError: Error, Sendable, LocalizedError {
    case ambiguous([Destination])

    public var errorDescription: String? {
        switch self {
        case .ambiguous:
            return "Several notes match this title."
        }
    }
}

public enum Router {
    /// Picks the note a capture goes to.
    /// 1. A non-empty note title matches root-note headings, then session headings,
    ///    then Inbox, else creates a new root note. Ambiguous headings require a choice.
    /// 2. Otherwise the active session's note.
    /// 3. Otherwise Inbox.md.
    public static func destination(
        noteTitle: String?,
        activeSession: Session?,
        notes: [NoteRef],
        vault: Vault
    ) throws -> Destination {
        let cleaned = NoteTitle.cleanTitle(noteTitle ?? "")
        if !cleaned.isEmpty {
            let pathName = try NoteTitle.resolvedPathName(for: noteTitle ?? "")
            let qualifiedPath = pathName.scope == .home || pathName.components.count > 1
            if qualifiedPath {
                let location = try vault.resolveNoteName(pathName)
                let leafTitle = String(cleaned.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
                return Destination(url: location.url, title: NoteTitle.cleanTitle(leafTitle), kind: .note)
            }

            let key = NoteTitle.matchKey(cleaned)
            let vaultRoot = vault.root.standardizedFileURL.path
            let rootNotes = notes.filter {
                $0.kind == .note && $0.url.deletingLastPathComponent().standardizedFileURL.path == vaultRoot
                    && NoteTitle.matchKey($0.title) == key
            }
            if !rootNotes.isEmpty {
                let candidates = rootNotes.map { Destination(url: $0.url, title: $0.title, kind: .note) }
                    .sorted { $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path }
                guard candidates.count == 1 else { throw RouterError.ambiguous(candidates) }
                return candidates[0]
            }
            let sessions = notes.filter { $0.kind == .session && NoteTitle.matchKey($0.title) == key }
            if !sessions.isEmpty {
                let candidates = sessions.map { Destination(url: $0.url, title: $0.title, kind: .session) }
                    .sorted { $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path }
                guard candidates.count == 1 else { throw RouterError.ambiguous(candidates) }
                return candidates[0]
            }
            if key == NoteTitle.matchKey(Vault.inboxTitle) {
                return Destination(url: vault.inboxURL, title: Vault.inboxTitle, kind: .inbox)
            }
            let location = try vault.resolveNoteName(pathName)
            return Destination(url: location.url, title: cleaned, kind: .note)
        }

        if let activeSession {
            return Destination(
                url: try vault.managedURL(forRelativePath: activeSession.notePath),
                title: activeSession.name,
                kind: .session
            )
        }

        return Destination(url: vault.inboxURL, title: Vault.inboxTitle, kind: .inbox)
    }
}
