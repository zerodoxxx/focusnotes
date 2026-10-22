import Foundation

/// The quick note's action-card commands. Raw values are stable identifiers.
public enum NoteActionID: String, Sendable, CaseIterable {
    case newNote, browse, pin, openAsNote, copyMarkdown, discardDraft, saveAsNewNote, writeOutsideSession
}

/// One row in the Browse list. Built by the app from its note index.
public struct BrowseItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var detail: String
    public var symbolName: String
    public var isPinned: Bool

    public init(id: String, title: String, detail: String, symbolName: String, isPinned: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.isPinned = isPinned
    }
}

/// What the user asked to do with a browsed note.
public enum BrowseChoice: Sendable, Equatable {
    case write, open, reveal
}
