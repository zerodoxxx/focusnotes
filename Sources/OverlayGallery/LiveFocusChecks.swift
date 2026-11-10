import AppKit
@_spi(Checks) import OverlayKit

// Runs with the focus seam off: these checks depend on real OS key focus, so they
// take the user's keyboard focus and must be run once, deliberately.
@MainActor
func runLiveFocusChecks() async throws {
    let frontmostApplication = NSWorkspace.shared.frontmostApplication
    let frontmost = frontmostApplication?.processIdentifier
    let canCheckFocus = frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
    if !canCheckFocus { print("Live keyboard-focus assertions skipped: macOS session is locked.") }
    func requireFrontmost(_ name: String) throws {
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "\(name) activated another application")
    }

    let input = InputPanelController()
    input.present(placeholder: "Input", suggestions: { _ in [] }, onSubmit: { _ in }, onCancel: {})
    let inputPanel = try currentPanel()
    if canCheckFocus {
        try require(inputPanel.isKeyWindow, "Input did not borrow real keyboard focus")
    }
    try requireFrontmost("Input")
    // Release must be synchronous: no settle before asserting or presenting the next panel.
    input.dismiss()
    try require(!inputPanel.isVisible && !inputPanel.isKeyWindow, "Input retained real key status during closing")

    input.present(placeholder: "Input", suggestions: { _ in [] }, onSubmit: { _ in }, onCancel: {})
    let search = SearchPanelController()
    search.present(query: { _ in [] }, actions: SearchActions(primary: { _ in }, open: { _ in }, reveal: { _ in }, onClose: {}))
    try await settle()
    let searchPanel = try currentPanel()
    if canCheckFocus {
        try require(!input.isVisible, "Input survived real key loss to Search")
        try require(searchPanel.isKeyWindow, "Search did not take real keyboard focus")
    }
    try requireFrontmost("Search")
    search.dismiss()
    try require(!searchPanel.isVisible && !searchPanel.isKeyWindow, "Search retained real key status during closing")

    let editor = NoteEditorPanel()
    let initial = String(repeating: "line\n", count: 35)
    editor.present(destination: nil, isPinned: false, draft: initial, handlers: NoteEditorHandlers(
        onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
        onBrowse: { _, _ in }, onTogglePin: { true }, onClose: {}, onError: { _ in }))
    // Initial on-screen layout can adjust the clip origin before the first key-loss check.
    try await settle()
    let stickyPanel = try currentPanel()
    guard let root = stickyPanel.contentView, let text = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }),
          let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first(where: { $0.documentView === text }) else {
        throw GalleryError("Sticky editor missing")
    }
    let frame = OverlayPreview.noteFrame(in: stickyPanel)
    let selection = NSRange(location: 10, length: 0)
    text.setSelectedRange(selection)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
    let scrollOrigin = scroll.contentView.bounds.origin
    // Both sticky cards (Actions, Browse) must close on a real resign to Input.
    for code: UInt16 in [40, 35] where canCheckFocus {
        editor.focus()
        try await settle()
        try key(code, modifiers: .command)
        try checkCardButtonState(in: root, open: code == 40 ? "Actions" : "Browse notes", context: "Live card before real key loss")
        input.present(placeholder: "Input", suggestions: { _ in [] }, onSubmit: { _ in }, onCancel: {})
        try await settle()
        try require(editor.isVisible && OverlayPreview.noteFrame(in: stickyPanel) == frame && stickyPanel.firstResponder === text,
                    "Real key loss must keep the sticky note and its frame, and restore the note first responder")
        try require(views(named: "NoteActionMenuView", in: root).isEmpty && views(named: "NoteBrowseView", in: root).isEmpty,
                    "Real key loss must close the sticky card")
        try checkCardButtonState(in: root, open: nil, context: "Real key loss closes card")
        input.dismiss()
        editor.focus()
        try await settle()
        try require(stickyPanel.isKeyWindow && stickyPanel.firstResponder === text, "Sticky note did not refocus its text after real key loss")
        try require(text.string == initial, "Real re-focus must preserve the draft")
        try require(text.selectedRange() == selection,
                    "Real re-focus must preserve the caret: expected \(selection), got \(text.selectedRange())")
        try require(scroll.contentView.bounds.origin == scrollOrigin,
                    "Real re-focus must preserve the scroll: expected \(scrollOrigin), got \(scroll.contentView.bounds.origin)")
    }
    try requireFrontmost("Sticky editor")
    editor.dismiss()

    try await checkLivePreviewInteraction()
    try requireFrontmost("Live preview")
    try await settle()
    try requireFrontmost("Live-focus checks")
    print("Live-focus checks passed: real key borrow, synchronous release, real key-loss dismissal, sticky card close/refocus/caret/scroll, live-preview focus.")
}
