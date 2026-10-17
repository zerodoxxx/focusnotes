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
    /// Picks the note a capture goes to.
    /// 1. A non-empty note title matches a note, then a session, then Inbox, else creates a new root note.
    /// 2. Otherwise the active session's note.
    /// 3. Otherwise Inbox.md.
    public static func destination(
        noteTitle: String?,
        activeSession: Session?,
        notes: [NoteRef],
        vault: Vault
    ) -> Destination {
        let cleaned = NoteTitle.cleanTitle(noteTitle ?? "")
        if !cleaned.isEmpty {
            let key = NoteTitle.matchKey(cleaned)
            if let note = notes.first(where: { $0.kind == .note && NoteTitle.matchKey($0.title) == key }) {
                return Destination(url: note.url, title: note.title, kind: .note)
            }
            if let session = notes.first(where: { $0.kind == .session && NoteTitle.matchKey($0.title) == key }) {
                return Destination(url: session.url, title: session.title, kind: .session)
            }
            if key == NoteTitle.matchKey(Vault.inboxTitle) {
                return Destination(url: vault.inboxURL, title: Vault.inboxTitle, kind: .inbox)
            }
            return Destination(url: vault.uniqueNoteURL(forTitle: cleaned), title: cleaned, kind: .note)
        }

        if let activeSession {
            return Destination(
                url: vault.url(forRelativePath: activeSession.notePath),
                title: activeSession.name,
                kind: .session
            )
        }

        return Destination(url: vault.inboxURL, title: Vault.inboxTitle, kind: .inbox)
    }
}
