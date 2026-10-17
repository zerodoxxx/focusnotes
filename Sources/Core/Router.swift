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

public enum Router {
    /// The note, session or Inbox that a title names, by title or file name. Nil when none does.
    /// Order: a root note, then a session, then Inbox. Within a kind, a title match beats a file-name match.
    public static func existing(title: String, notes: [NoteRef], vault: Vault) -> Destination? {
        let cleaned = NoteTitle.cleanTitle(title)
        guard !cleaned.isEmpty else { return nil }
        if let note = bestMatch(cleaned, kind: .note, in: notes) {
            return Destination(url: note.url, title: note.title, kind: .note)
        }
        if let session = bestMatch(cleaned, kind: .session, in: notes) {
            return Destination(url: session.url, title: session.title, kind: .session)
        }
        if NoteTitle.matchKey(cleaned) == NoteTitle.matchKey(Vault.inboxTitle) {
            return Destination(url: vault.inboxURL, title: Vault.inboxTitle, kind: .inbox)
        }
        return nil
    }

    /// Picks the note a capture goes to.
    /// 1. A non-empty note title matches a note's title or file name, then a session, then Inbox, else creates a new root note.
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
            let pathName = try NoteTitle.pathName(for: cleaned)
            let qualifiedPath = pathName.scope == .home || pathName.components.count > 1
            if qualifiedPath {
                let location = try vault.resolveNoteName(pathName)
                let leafTitle = String(cleaned.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
                return Destination(url: location.url, title: NoteTitle.cleanTitle(leafTitle), kind: .note)
            }

            if let match = existing(title: cleaned, notes: notes, vault: vault) { return match }
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

    /// The first note of `kind` that the query names. A title match is preferred over a file-name match.
    private static func bestMatch(_ query: String, kind: NoteKind, in notes: [NoteRef]) -> NoteRef? {
        let key = NoteTitle.matchKey(query)
        let matches = notes.filter { note in
            note.kind == kind && NoteTitle.names(
                query, title: note.title, stem: note.url.deletingPathExtension().lastPathComponent
            )
        }
        return matches.first { NoteTitle.matchKey($0.title) == key } ?? matches.first
    }
}
