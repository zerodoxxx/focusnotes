import Core
import Foundation

/// Per-panel state of the quick note editor: where the next save goes, and whether a
/// note that does not exist yet should be pinned when it is created.
@MainActor
final class QuickNoteState {
    var destination: Destination?
    let folder: NoteFolder?
    /// A chosen session or Browse note; nil while the typed name picks the note, as in a folder quick note.
    var destinationLabel: String? { destination?.title }
    /// The title shown while a folder quick note is blank; typed text then names the note in that folder.
    var folderLabel: String? { folder.map { "Folder: \($0.rawValue)" } }
    var outsideSession = false
    /// Opened by the outside-session shortcut; blank ⌘N returns here instead of to the session.
    let launchedOutside: Bool
    private(set) var pinOnSave = false
    var suggestions: [NoteSuggestion] = []
    var kinds: [String: NoteKind] {
        Dictionary(suggestions.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }
    private var defaultOutsideSession: Bool { folder != nil || launchedOutside }
    init(destination: Destination?, pinOnSave: Bool = false, folder: NoteFolder? = nil, outsideSession launchedOutside: Bool = false) {
        self.destination = launchedOutside ? nil : destination
        self.folder = folder
        self.launchedOutside = launchedOutside
        self.outsideSession = defaultOutsideSession
        self.pinOnSave = self.destination == nil && pinOnSave
    }
    /// What a save asks Core for; a chosen session or Browse note is replayed unchanged.
    func intent() -> CaptureIntent {
        CaptureIntent(destination.map { .resolved($0) } ?? .automatic, outsideSession: outsideSession, folder: folder)
    }
    /// The chosen note when its file exists on disk.
    var existingDestination: Destination? {
        destination.flatMap { FileManager.default.fileExists(atPath: $0.url.path) ? $0 : nil }
    }
    func togglePinOnSave(in drafts: NoteDraftStore) throws -> Bool {
        try drafts.setPinOnSave(!pinOnSave)
        pinOnSave.toggle()
        return pinOnSave
    }
    func resetPinOnSave(in drafts: NoteDraftStore) throws {
        try drafts.setPinOnSave(false)
        pinOnSave = false
    }
    /// The pin intent a draft write stores; a blank draft carries none.
    func pinOnSave(forDraft text: String) -> Bool {
        CaptureFormat.isBlank(text) ? false : pinOnSave
    }
    /// Forgets the intent after a blank draft was stored; the draft file needs no update.
    func dropPinOnSaveForBlankDraft() { pinOnSave = false }
    func toggleOutsideSession(sessionDestination: Destination, drafts: NoteDraftStore) throws {
        try resetPinOnSave(in: drafts)
        outsideSession.toggle()
        destination = outsideSession ? nil : sessionDestination
    }
    func restoreSessionDestination(_ sessionDestination: Destination?, drafts: NoteDraftStore) throws {
        try resetPinOnSave(in: drafts)
        outsideSession = defaultOutsideSession
        destination = outsideSession ? nil : sessionDestination
    }
}
