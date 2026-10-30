import Foundation

/// One exact note chosen in a picker or Browse. `noteID` is a vault note ID (vault-relative path or HOME file URL).
public struct NotePick: Sendable, Equatable {
    public var noteID: String
    public var title: String
    public var kind: NoteKind

    public init(noteID: String, title: String, kind: NoteKind) {
        self.noteID = noteID
        self.title = title
        self.kind = kind
    }
}

/// What the user asked for when saving a capture; `CaptureService.resolve` turns it into a destination.
public struct CaptureIntent: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// Session default, Inbox, or a typed note's own name.
        case automatic
        /// A typed title from the picker, routed by Router.
        case title(String)
        /// An exact note that must still exist.
        case pick(NotePick)
        /// A destination fixed by an earlier resolution, replayed unchanged.
        case resolved(Destination)
    }

    public var target: Target
    /// Bypasses the active session for this capture only.
    public var outsideSession: Bool
    public var folder: NoteFolder?
    /// Save as New; typed notes only.
    public var newNote: Bool

    public init(_ target: Target = .automatic, outsideSession: Bool = false, folder: NoteFolder? = nil, newNote: Bool = false) {
        self.target = target
        self.outsideSession = outsideSession
        self.folder = folder
        self.newNote = newNote
    }
}
