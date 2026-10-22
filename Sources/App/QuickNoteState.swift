import Core

/// Per-panel state of the quick note editor: where the next save goes, and whether a
/// note that does not exist yet should be pinned when it is created.
@MainActor
final class QuickNoteState {
    var destination: Destination?
    let folder: NoteFolder?
    var destinationLabel: String? { destination?.title ?? folder.map { "Folder: \($0.rawValue)" } }
    var outsideSession = false
    /// Opened by the outside-session shortcut; blank ⌘N returns here instead of to the session.
    let launchedOutside: Bool
    var pinOnSave = false
    var suggestions: [NoteSuggestion] = []
    var kinds: [String: NoteKind] {
        Dictionary(suggestions.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }
    init(destination: Destination?, pinOnSave: Bool = false, folder: NoteFolder? = nil, outsideSession launchedOutside: Bool = false) {
        self.destination = launchedOutside ? nil : destination
        self.folder = folder
        self.launchedOutside = launchedOutside
        self.outsideSession = folder != nil || launchedOutside
        self.pinOnSave = self.destination == nil && pinOnSave
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
    func toggleOutsideSession(sessionDestination: Destination, drafts: NoteDraftStore) throws {
        try resetPinOnSave(in: drafts)
        outsideSession.toggle()
        destination = outsideSession ? nil : sessionDestination
    }
    func restoreSessionDestination(_ sessionDestination: Destination?, drafts: NoteDraftStore) throws {
        try resetPinOnSave(in: drafts)
        outsideSession = folder != nil || launchedOutside
        destination = outsideSession ? nil : sessionDestination
    }
}
