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

    let input = InputPanelController()
    input.present(placeholder: "Input", suggestions: { _ in [] }, onSubmit: { _ in }, onCancel: {})
    if canCheckFocus {
        try require(try currentPanel().isKeyWindow, "Input did not borrow real keyboard focus")
    }
    try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Input activated another application")
    try require(!NSApp.isActive, "Input activated the application")
    input.dismiss()

    input.present(placeholder: "Input", suggestions: { _ in [] }, onSubmit: { _ in }, onCancel: {})
    let search = SearchPanelController()
    search.present(query: { _ in [] }, actions: SearchActions(primary: { _ in }, open: { _ in }, reveal: { _ in }, onClose: {}))
    try await settle()
    if canCheckFocus {
        try require(!input.isVisible, "Input survived real key loss to Search")
        try require(try currentPanel().isKeyWindow, "Search did not take real keyboard focus")
    }
    search.dismiss()

    let editor = NoteEditorPanel()
    editor.present(destination: nil, isPinned: false, draft: "Sticky note", handlers: NoteEditorHandlers(
        onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
        onBrowse: { _, _ in }, onTogglePin: { true }, onClose: {}, onError: { _ in }))
    let stickyPanel = try currentPanel()
    guard let root = stickyPanel.contentView, let text = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }) else {
        throw GalleryError("Sticky editor missing")
    }
    input.present(placeholder: "Input", suggestions: { _ in [] }, onSubmit: { _ in }, onCancel: {})
    try await settle()
    if canCheckFocus {
        try require(editor.isVisible, "Sticky note did not survive real key loss")
    }
    input.dismiss()
    editor.focus()
    try await settle()
    if canCheckFocus {
        try require(stickyPanel.isKeyWindow && stickyPanel.firstResponder === text, "Sticky note did not refocus its text after real key loss")
    }
    editor.dismiss()

    try await checkLivePreviewInteraction()
    print("Live-focus checks passed: real key borrow, real key-loss dismissal, sticky refocus, live-preview focus.")
}
