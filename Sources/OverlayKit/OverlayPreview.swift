import AppKit

/// Offscreen snapshots use the production view hierarchy with a solid material
/// substitute. These views do not create or order windows and never take focus.
public enum NoteEditorOverlay {
    case none
    case actions(query: String = "", selected: Int? = nil)
    case browse(items: [BrowseItem], query: String = "", selected: Int? = nil)
}

@MainActor
public enum OverlayPreview {
    public static func toast(_ toast: Toast) -> NSView {
        let view = ToastView(toast)
        view.usesGalleryBackground = true
        return view
    }
    public static func input(placeholder: String, text: String = "", suggestions: [Suggestion] = [], selection: Int? = nil, title: String? = nil, secondary: String? = nil) -> NSView {
        let view = InputPanelView(placeholder: placeholder, text: text, suggestions: suggestions, selection: selection, title: title, secondary: secondary)
        view.usesGalleryBackground = true
        return view
    }
    public static func noteEditor(destination: String? = nil, fallbackTitle: String? = nil, text: String = "", restoredDraft: Bool = false, selection: NSRange? = nil,
                                  revealed: Bool = false, isPinned: Bool = false, overlay: NoteEditorOverlay = .none,
                                  appendsTo existingTitle: String? = nil) -> NSView {
        let view = NoteEditorView(destination: destination, fallbackTitle: fallbackTitle, text: text, restoredDraft: restoredDraft)
        view.usesGalleryBackground = true
        if let existingTitle { view.existingTitleForText = { _ in existingTitle } } // preview: the text names this note
        view.setDestination(destination, isPinned: isPinned)
        if let selection { view.setPreviewSelection(selection); view.textView.showsGalleryCaret = true }
        switch overlay {
        case .none: break
        case let .actions(query, selected): view.showActions(query: query, selectedIndex: selected)
        case let .browse(items, query, selected): view.showBrowse(items: items, query: query, selectedIndex: selected)
        }
        view.windowOverflowHeight = view.desiredSize.height - view.noteSize.height
        view.setFrameSize(view.desiredSize)
        view.setRevealed(revealed || view.holdsReveal, animated: false)
        return view
    }
    @_spi(Checks)
    public static func previewInvalidations(in view: NSView) -> [NSRange] {
        ((view as? NoteEditorView)?.textView.layoutManager as? MarkdownLayoutManager)?.lastSelectionInvalidations ?? []
    }
    @_spi(Checks)
    public static func previewSelectionRevision(in view: NSView) -> Int {
        ((view as? NoteEditorView)?.textView.layoutManager as? MarkdownLayoutManager)?.selectionRevision ?? 0
    }
    @_spi(Checks)
    public static func caretRect(in view: NSView) -> NSRect? {
        (view as? NoteEditorView)?.textView.galleryCaretRect()
    }
    /// System-style caret rects (as AppKit would supply them) at the end of each laid-out line, in text view coordinates.
    @_spi(Checks)
    public static func lineEndSystemRects(in view: NSView) -> [NSRect] {
        guard let text = (view as? NoteEditorView)?.textView, let manager = text.layoutManager, let container = text.textContainer else { return [] }
        manager.ensureLayout(for: container)
        var rects: [NSRect] = []
        let origin = text.textContainerOrigin
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, used, _, _, _ in
            rects.append(NSRect(x: origin.x + used.maxX, y: origin.y + rect.minY, width: 1, height: rect.height))
        }
        return rects
    }
    @_spi(Checks)
    public static func tightCaret(in view: NSView, systemRect: NSRect) -> NSRect? {
        (view as? NoteEditorView)?.textView.tightCaretRect(forSystemRect: systemRect)
    }
    /// What the real caret path does for a rect AppKit supplied: how many bars were painted and how often the
    /// system's own drawing was reached (the latter only for erasing).
    @_spi(Checks)
    public static func drawCaret(in textView: NSTextView, systemRect: NSRect, turnedOn: Bool) -> (painted: Int, system: Int) {
        guard let text = textView as? NoteTextView else { return (0, 0) }
        let (paintedBefore, systemBefore) = (text.caretPaintCount, text.systemCaretCount)
        text.drawInsertionPoint(in: systemRect, color: OverlayTheme.editorInsertionColor, turnedOn: turnedOn)
        return (text.caretPaintCount - paintedBefore, text.systemCaretCount - systemBefore)
    }
    @_spi(Checks)
    public static func layoutCaretRect(in textView: NSTextView) -> NSRect? { (textView as? NoteTextView)?.layoutCaretRect() }
    @_spi(Checks)
    public static func textHeight(in view: NSView) -> CGFloat { (view as? NoteEditorView)?.textHeight ?? 0 }
    @_spi(Checks)
    public static func chromeSymbol(in view: NSView) -> String? { (view as? ChromeButton)?.symbolName }
    @_spi(Checks)
    public static func noteRect(in view: NSView) -> NSRect { (view as? NoteEditorView)?.noteRect ?? view.bounds }
    @_spi(Checks)
    public static func noteFrame(in panel: OverlayPanel) -> NSRect { panel.noteFrame }
    @_spi(Checks)
    public static func limitCardHeight(in view: NSView, noteTop: CGFloat, visibleBottom: CGFloat) {
        guard let editor = view as? NoteEditorView else { return }
        editor.limitCardHeight(noteTop: noteTop, visibleBottom: visibleBottom)
        editor.windowOverflowHeight = editor.desiredSize.height - editor.noteSize.height
        editor.setFrameSize(editor.desiredSize)
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
    }
    @_spi(Checks)
    public static func screenChanged(in panel: OverlayPanel, to visibleFrame: NSRect) { panel.screenChanged(to: visibleFrame) }
    @_spi(Checks)
    public static func selectedCardID(in view: NSView) -> String? {
        if let menu = view as? NoteActionMenuView { return menu.selectedID.map { String(describing: $0) } }
        return (view as? NoteBrowseView)?.selectedID
    }
    @_spi(Checks)
    public static func isDragHandle(in view: NSView, at point: NSPoint) -> Bool {
        (view as? NoteEditorView)?.isDragHandle(at: point) ?? false
    }
    @_spi(Checks)
    public static func panelFrame(topCenter: CGPoint, size: NSSize, in visible: NSRect) -> NSRect {
        OverlayPanel.frame(topCenter: topCenter, size: size, in: visible)
    }
    @_spi(Checks)
    public static func topCenter(of frame: NSRect, in visible: NSRect) -> CGPoint { OverlayPanel.topCenter(of: frame, in: visible) }
    @_spi(Checks)
    public static func resizedFrame(_ frame: NSRect, to size: NSSize, in visible: NSRect) -> NSRect {
        OverlayPanel.resized(frame, to: size, in: visible)
    }
    @_spi(Checks)
    public static let positionDefaultsKey = OverlayPanel.positionKey
    public static func search(sections: [SearchSection], query: String = "", selection: Int? = 0, loading: Bool = false) async -> NSView {
        let view = SearchPanelView(query: query)
        view.usesGalleryBackground = true
        view.update(sections: sections, selection: selection, query: query)
        view.setFrameSize(view.desiredSize)
        view.setLoading(loading)
        await view.waitForThumbnails()
        return view
    }
}
