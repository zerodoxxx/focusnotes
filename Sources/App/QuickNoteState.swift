import Core

/// Per-panel state of the quick note editor: where the next save goes, and whether a
/// note that does not exist yet should be pinned when it is created.
@MainActor
final class QuickNoteState {
    var destination: Destination?
    var outsideSession = false
    var pinOnSave = false
    var suggestions: [NoteSuggestion] = []
    var kinds: [String: NoteKind] {
        Dictionary(suggestions.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }
    init(destination: Destination?, pinOnSave: Bool = false) { self.destination = destination; self.pinOnSave = destination == nil && pinOnSave }
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
        outsideSession = false
        destination = sessionDestination
    }
}
