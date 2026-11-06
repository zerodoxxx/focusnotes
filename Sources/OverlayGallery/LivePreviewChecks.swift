import AppKit
import CoreText
@_spi(Checks) import OverlayKit

@MainActor
private func editorText(in root: NSView) throws -> NSTextView {
    guard let text = descendants(root).compactMap({ $0 as? NSTextView }).first else { throw GalleryError("Live-preview text view missing") }
    return text
}
@MainActor
private func glyph(_ manager: NSLayoutManager, character: Int) -> (CGGlyph, Int) {
    var value: CGGlyph = 0
    var index = 0
    let glyph = manager.glyphIndexForCharacter(at: character)
    _ = manager.getGlyphs(in: NSRange(location: glyph, length: 1), glyphs: &value, properties: nil, characterIndexes: &index, bidiLevels: nil)
    return (value, index)
}
@MainActor
private func fontGlyph(_ character: UniChar, font: NSFont) -> CGGlyph {
    var character = character, value: CGGlyph = 0
    CTFontGetGlyphsForCharacters(font as CTFont, &character, &value, 1)
    return value
}
@MainActor
private func hidden(_ manager: NSLayoutManager, character: Int) -> Bool {
    let properties = manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: character))
    return properties.contains(.null) || properties.contains(.controlCharacter)
}

@MainActor
func checkLivePreviewGlyphs() throws {
    let markdown = "## Heading **bold**\n- fknl\n* abc\n+ def\n1. gh\n- [ ] todo\n- [x] done\n> quoted\n**bold** __strong__ *italic* _emphasis_ ~~strike~~ `code` [link](https://example.com)\n```\n- raw\n**code**\n```"
    let root = OverlayPreview.noteEditor(destination: "Inbox", text: markdown, selection: NSRange(location: 3, length: 0))
    let text = try editorText(in: root)
    guard let manager = text.layoutManager, let storage = text.textStorage, let container = text.textContainer else { throw GalleryError("TextKit 1 missing") }
    let source = markdown as NSString
    manager.ensureLayout(for: container)
    try require(text.textLayoutManager == nil, "Editor must explicitly use TextKit 1")
    try require(text.string == markdown && storage.length == source.length, "Live preview must preserve every stored character")
    for token in ["- fknl", "* abc", "+ def"] {
        let index = source.range(of: token).location
        let displayed = glyph(manager, character: index)
        try require(displayed.0 == fontGlyph(0x2022, font: OverlayTheme.editorBulletFont) && displayed.1 == index,
                   "Bullet substitution must keep the original character index: \(token)")
    }
    let ordered = source.range(of: "1. gh").location
    try require(glyph(manager, character: ordered).0 == fontGlyph(49, font: OverlayTheme.editorFont), "Ordered marker must stay text")
    let headingLine = source.lineRange(for: NSRange(location: 3, length: 0))
    for index in 0..<3 { try require(!manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: index)).contains(.null), "Caret heading syntax must stay visible") }
    let headingInline = source.range(of: "**bold**")
    for index in [headingInline.location, headingInline.location + 1, NSMaxRange(headingInline) - 2, NSMaxRange(headingInline) - 1] {
        try require(hidden(manager, character: index), "An inline delimiter elsewhere on the heading line must stay hidden")
    }
    for token in ["**bold** __strong__", "__strong__", "*italic*", "_emphasis_", "~~strike~~", "`code`", "[link]", "](https://example.com)", "> quoted", "- [ ] todo"] {
        let index = source.range(of: token).location
        try require(hidden(manager, character: index), "Off-caret syntax must be hidden: \(token)")
    }
    let fence = source.range(of: "```").location
    try require(!manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: fence)).contains(.null), "Fence lines must remain visible")
    let rawCode = source.range(of: "- raw").location
    try require(glyph(manager, character: rawCode).0 == fontGlyph(45, font: OverlayTheme.editorCodeFont), "No bullet substitution inside fenced code")

    let bullet = source.range(of: "- fknl").location
    text.setSelectedRange(NSRange(location: bullet + 2, length: 0))
    manager.ensureLayout(for: container)
    let headingElementRange = NSRange(location: headingLine.location, length: headingLine.length - 1)
    try require(OverlayPreview.previewInvalidations(in: root) == [headingElementRange], "Selection change must invalidate only the heading element whose active state changed")
    try require(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: 0)).contains(.null), "Leaving a heading must hide its syntax")
    try require(glyph(manager, character: bullet).0 == fontGlyph(0x2022, font: OverlayTheme.editorBulletFont), "Bullet must remain substituted on caret line")
    try require(text.selectedRange() == NSRange(location: bullet + 2, length: 0) && text.string == markdown, "Caret indices must remain raw Markdown indices")
    let revision = OverlayPreview.previewSelectionRevision(in: root)
    text.setSelectedRange(NSRange(location: bullet + 4, length: 0))
    try require(OverlayPreview.previewSelectionRevision(in: root) == revision, "Moving within one line must not invalidate preview glyphs")

    let task = source.range(of: "- [ ] todo").location
    let checked = source.range(of: "- [x] done").location
    text.setSelectedRange(NSRange(location: task, length: checked + 6 - task))
    manager.ensureLayout(for: container)
    for index in [task + 2, checked + 2] {
        try require(!manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: index)).contains(.null), "Selection overlapping a block marker must reveal its syntax")
    }
    try require(text.string == markdown, "Selection changes must not rewrite Markdown")

    let taskMarkdown = "- [ ] jdf"
    let taskRoot = OverlayPreview.noteEditor(destination: "Inbox", text: taskMarkdown, selection: NSRange(location: (taskMarkdown as NSString).length, length: 0))
    let taskText = try editorText(in: taskRoot)
    guard let taskManager = taskText.layoutManager, let taskStorage = taskText.textStorage,
          let taskContainer = taskText.textContainer else { throw GalleryError("Task preview missing") }
    taskManager.ensureLayout(for: taskContainer)
    for index in 0..<6 {
        try require(taskManager.propertyForGlyph(at: taskManager.glyphIndexForCharacter(at: index)).contains(.null),
                   "Task marker must be hidden at the item text caret")
    }
    let itemIndent = (taskStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
    let previewIndent = (taskStorage.attribute(MarkdownStyler.previewParagraph, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
    try require(itemIndent == previewIndent && itemIndent > 0, "Rendered task must use its preview paragraph indent")
    taskText.setSelectedRange(NSRange(location: 3, length: 0))
    taskManager.ensureLayout(for: taskContainer)
    for index in 0..<6 {
        try require(!taskManager.propertyForGlyph(at: taskManager.glyphIndexForCharacter(at: index)).contains(.null),
                   "Caret inside task marker must reveal the whole marker")
    }
    let rawIndent = (taskStorage.attribute(MarkdownStyler.rawParagraph, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
    let activeIndent = (taskStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
    try require(activeIndent == rawIndent, "Active task marker must use its raw paragraph style")
    taskText.setSelectedRange(NSRange(location: 6, length: 0))
    taskManager.ensureLayout(for: taskContainer)
    try require(taskManager.propertyForGlyph(at: taskManager.glyphIndexForCharacter(at: 2)).contains(.null),
               "Caret exactly after task marker must render the checkbox")

    let inlineMarkdown = "say **bold** now"
    let inlineRoot = OverlayPreview.noteEditor(destination: "Inbox", text: inlineMarkdown,
        selection: NSRange(location: (inlineMarkdown as NSString).length, length: 0))
    let inlineText = try editorText(in: inlineRoot)
    guard let inlineManager = inlineText.layoutManager, let inlineContainer = inlineText.textContainer else { throw GalleryError("Inline preview missing") }
    inlineManager.ensureLayout(for: inlineContainer)
    for index in 4..<6 { try require(hidden(inlineManager, character: index), "Off-caret emphasis delimiter must be hidden") }
    inlineText.setSelectedRange(NSRange(location: 6, length: 0))
    inlineManager.ensureLayout(for: inlineContainer)
    for index in 4..<6 { try require(!hidden(inlineManager, character: index), "Caret inside emphasis must reveal its delimiters") }
    inlineText.setSelectedRange(NSRange(location: 4, length: 0))
    inlineManager.ensureLayout(for: inlineContainer)
    for index in 4..<6 { try require(!hidden(inlineManager, character: index), "Caret touching emphasis boundary must reveal its delimiters") }

    let headingMarkdown = "# Title\nother"
    let headingRoot = OverlayPreview.noteEditor(destination: "Inbox", text: headingMarkdown, selection: NSRange(location: 7, length: 0))
    let headingText = try editorText(in: headingRoot)
    guard let headingManager = headingText.layoutManager else { throw GalleryError("Heading preview missing") }
    try require(!hidden(headingManager, character: 0), "Heading syntax stays visible at inclusive line end")
    headingText.setSelectedRange(NSRange(location: 8, length: 0))
    try require(hidden(headingManager, character: 0), "Heading syntax hides when caret moves to another line")

    let bulletsOnly = "plain\n- fknl\n* abc\n+ def\n1. gh"
    let bulletRoot = OverlayPreview.noteEditor(destination: "Inbox", text: bulletsOnly, selection: NSRange(location: 0, length: 0))
    let bulletText = try editorText(in: bulletRoot)
    try require(bulletText.layoutManager?.numberOfGlyphs == (bulletsOnly as NSString).length,
               "Bullet substitution must remain one character to one glyph")
    let composedMarkdown = "- **ime**\nother"
    let composedRoot = OverlayPreview.noteEditor(destination: "Inbox", text: composedMarkdown, selection: NSRange(location: 2, length: 0))
    let composed = try editorText(in: composedRoot)
    composed.setMarkedText("- **ime**", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 9))
    guard let composedManager = composed.layoutManager, let composedContainer = composed.textContainer else { throw GalleryError("IME preview missing") }
    composedManager.ensureLayout(for: composedContainer)
    try require(composed.hasMarkedText() && composed.string == composedMarkdown, "Live-preview layout must preserve marked text")
    let composedFont = (composed.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? OverlayTheme.editorFont
    try require(glyph(composedManager, character: 0).0 == fontGlyph(45, font: composedFont), "IME line must not substitute its bullet")
    for index in [2, 3, 7, 8] {
        try require(!composedManager.propertyForGlyph(at: composedManager.glyphIndexForCharacter(at: index)).contains(.null), "IME syntax must never be hidden")
    }
    composed.unmarkText()
    try require(glyph(composedManager, character: 0).0 == fontGlyph(0x2022, font: OverlayTheme.editorFont), "Bullet preview must resume after IME commit")
    for suffix in ["- [ ] ", "> "] {
        let emptyRoot = OverlayPreview.noteEditor(destination: "Inbox", text: "heading\n" + suffix, selection: NSRange(location: 0, length: 0))
        let emptyText = try editorText(in: emptyRoot)
        guard let emptyManager = emptyText.layoutManager, let emptyContainer = emptyText.textContainer else { throw GalleryError("Empty decoration missing") }
        emptyManager.ensureLayout(for: emptyContainer)
        let glyph = emptyManager.glyphIndexForCharacter(at: 8)
        try require(emptyManager.propertyForGlyph(at: glyph).contains(.controlCharacter), "Empty task/quote needs an invisible layout anchor")
        let rect = emptyManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        try require(rect.height > 0 && rect.minY > 0 && emptyText.string == "heading\n" + suffix, "Empty decoration must retain its own line without changing text")
    }
    print("Live-preview glyph checks passed (bullets/indices, hidden syntax, caret/selection reveal, paragraph-only invalidation, visible fences).")
}

@MainActor
func checkLivePreviewInteraction() async throws {
    let editor = NoteEditorPanel()
    let markdown = "## Heading\n- [ ] todo\n- [x] done"
    var draft = ""
    editor.present(destination: "Inbox", isPinned: false, draft: markdown, handlers: NoteEditorHandlers(
        onDraft: { draft = $0 }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
        onBrowse: { _, _ in }, onTogglePin: { false }, onClose: {}, onError: { _ in }))
    defer { editor.dismiss() }
    let panel = try currentPanel()
    guard let root = panel.contentView else { throw GalleryError("Live preview panel missing") }
    let text = try editorText(in: root)
    text.setSelectedRange(NSRange(location: 3, length: 0))
    let selection = text.selectedRange()
    guard let manager = text.layoutManager, let container = text.textContainer else { throw GalleryError("Checkbox layout missing") }
    manager.ensureLayout(for: container)
    let task = (markdown as NSString).range(of: "- [ ] todo").location
    let taskGlyph = manager.glyphIndexForCharacter(at: task + 6)
    let line = manager.lineFragmentRect(forGlyphAt: taskGlyph, effectiveRange: nil)
    let center = line.minY + manager.location(forGlyphAt: taskGlyph).y - OverlayTheme.editorFont.capHeight / 2
    let local = NSPoint(x: text.textContainerOrigin.x + OverlayTheme.editorCheckboxSize / 2, y: text.textContainerOrigin.y + center)
    let point = text.convert(local, to: nil)
    guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw GalleryError("Checkbox click event missing") }
    text.mouseDown(with: event)
    try require(text.string == "## Heading\n- [x] todo\n- [x] done" && draft == text.string, "Checkbox click must toggle the stored task and persist its draft")
    try require(text.selectedRange() == selection && panel.isKeyWindow && panel.firstResponder === text, "Checkbox click must preserve caret and panel keyboard focus")
    text.undoManager?.undo()
    try require(text.string == markdown && draft == markdown, "Checkbox edit must be undoable")
    text.undoManager?.redo()
    try require(text.string.contains("- [x] todo"), "Checkbox edit must be redoable")
    text.undoManager?.undo()
    let quoted = "## Heading\n> quote\n- [ ] item"
    text.selectAll(nil); text.insertText(quoted, replacementRange: text.selectedRange())
    text.setSelectedRange(NSRange(location: 3, length: 0))
    text.moveDown(nil)
    let quoteLine = (quoted as NSString).lineRange(for: NSRange(location: (quoted as NSString).range(of: "> quote").location, length: 0))
    try require(NSLocationInRange(text.selectedRange().location, quoteLine), "Arrow down must enter next rendered line")
    let quoteMarker = NSRange(location: quoteLine.location, length: 2)
    let quoteActive = quoteMarker.location < text.selectedRange().location && text.selectedRange().location < NSMaxRange(quoteMarker)
    for index in quoteLine.location..<(quoteLine.location + 2) {
        try require(hidden(manager, character: index) == !quoteActive,
                   "Arrow entry must follow quote-marker activation boundaries before caret drawing")
    }
    editor.dismiss()

    var taskDraft = ""
    editor.present(destination: "Inbox", isPinned: false, draft: "- [ ] jdf", handlers: NoteEditorHandlers(
        onDraft: { taskDraft = $0 }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
        onBrowse: { _, _ in }, onTogglePin: { false }, onClose: {}, onError: { _ in }))
    let singlePanel = try currentPanel()
    guard let singleRoot = singlePanel.contentView else { throw GalleryError("Single task panel missing") }
    let singleText = try editorText(in: singleRoot)
    guard let singleManager = singleText.layoutManager, let singleContainer = singleText.textContainer else { throw GalleryError("Single task layout missing") }
    singleManager.ensureLayout(for: singleContainer)
    let itemGlyph = singleManager.glyphIndexForCharacter(at: 6)
    let itemLine = singleManager.lineFragmentRect(forGlyphAt: itemGlyph, effectiveRange: nil)
    let checkboxCenter = itemLine.minY + singleManager.location(forGlyphAt: itemGlyph).y - OverlayTheme.editorFont.capHeight / 2
    let checkboxLocal = NSPoint(x: singleText.textContainerOrigin.x + OverlayTheme.editorCheckboxSize / 2,
                                y: singleText.textContainerOrigin.y + checkboxCenter)
    let checkboxPoint = singleText.convert(checkboxLocal, to: nil)
    guard let checkboxEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: checkboxPoint, modifierFlags: [], timestamp: 0,
        windowNumber: singlePanel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
        throw GalleryError("Single task checkbox event missing")
    }
    singleText.mouseDown(with: checkboxEvent)
    try require(singleText.string == "- [x] jdf" && taskDraft == singleText.string,
               "Checkbox must be drawn and clickable with the caret at the single-line item text end")
    print("Live-preview interaction checks passed (checkbox click/draft/undo/redo, caret/focus, arrow reveal, single-line end-caret checkbox).")
}
