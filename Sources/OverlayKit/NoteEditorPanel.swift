import AppKit

@MainActor
final class NoteTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var onSave: (() -> Void)?
    var onUnmark: (() -> Void)?
    var onPreviewChange: (() -> Void)?
    var onToggleActions: (() -> Void)?
    var onShortcut: ((NoteActionID) -> Void)?
    var onMouseDown: (() -> Void)?
    var showsGalleryCaret = false
    private let history = UndoManager()
    override var undoManager: UndoManager? { history }
    /// Test hooks: how many carets were painted, and how often the system's own caret drawing was reached.
    private(set) var caretPaintCount = 0
    private(set) var systemCaretCount = 0
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsGalleryCaret, let caret = galleryCaretRect() else { return }
        paintCaret(caret)
    }

    /// Where the system would put the caret (1pt wide, one line fragment tall), derived from the layout. The real
    /// caret gets this rect from AppKit; snapshots, where nothing draws it, build it here.
    func layoutCaretRect() -> NSRect? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage else { return nil }
        manager.ensureLayout(for: container)
        let length = storage.length
        let caret = min(selectedRange().location, length)
        let origin = textContainerOrigin
        let extra = manager.extraLineFragmentRect
        if length == 0 || (caret == length && extra.height > 0) {
            return NSRect(x: origin.x + extra.minX, y: origin.y + extra.minY, width: 1, height: extra.height)
        }
        let index = caret < length ? caret : length - 1
        let glyph = manager.glyphIndexForCharacter(at: index)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let advance = caret == length ? manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).width : 0
        return NSRect(x: origin.x + line.minX + manager.location(forGlyphAt: glyph).x + advance, y: origin.y + line.minY, width: 1, height: line.height)
    }
    /// The tight caret snapshots draw: nothing for a selection (marked text keeps its caret).
    func galleryCaretRect() -> NSRect? {
        guard hasMarkedText() || selectedRange().length == 0, let system = layoutCaretRect() else { return nil }
        return tightCaretRect(forSystemRect: system)
    }

    /// The caret is a short rounded bar tied to the font at the insertion point, not to the (taller) line fragment.
    /// The line is the one under the system's own rect (at a soft wrap the caret can sit at the end of the upper
    /// line while its character belongs to the lower one), and the x is the system's.
    func tightCaretRect(forSystemRect rect: NSRect) -> NSRect? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage else { return nil }
        manager.ensureLayout(for: container)
        let origin = textContainerOrigin
        let point = NSPoint(x: rect.minX - origin.x, y: rect.midY - origin.y)
        let extra = manager.extraLineFragmentRect
        let layoutFont = (typingAttributes[.font] as? NSFont) ?? OverlayTheme.editorFont
        var caretFont = layoutFont
        let baseline: CGFloat
        if storage.length == 0 || (extra.height > 0 && point.y >= extra.minY) {
            // Empty text or a trailing newline: no glyph, so place the baseline from the typing font's metrics.
            baseline = extra.minY + extra.height - ceil(-layoutFont.descender + layoutFont.leading) * OverlayTheme.editorLineHeightMultiple
            // Typing attributes are reset to the body font, but an empty line inside an open fence is code.
            if storage.length > 0, isInsideFencedCode(before: storage.length) { caretFont = OverlayTheme.editorCodeFont }
        } else {
            let glyph = manager.glyphIndex(for: point, in: container)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            baseline = line.minY + manager.location(forGlyphAt: glyph).y
            let index = min(manager.characterIndexForGlyph(at: glyph), storage.length - 1)
            caretFont = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? layoutFont
        }
        let size = caretFont.pointSize
        let height = size * OverlayTheme.editorCaretHeightFactor
        let bottom = origin.y + baseline + size * OverlayTheme.editorCaretDescentFactor
        return NSRect(x: rect.minX, y: bottom - height, width: OverlayTheme.editorCaretWidth, height: height)
    }
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let system = super.firstRect(forCharacterRange: range, actualRange: actualRange)
        guard range.length == 0, range.location != NSNotFound, let window else { return system }
        let local = convert(window.convertFromScreen(system), from: nil)
        guard let tight = tightCaretRect(forSystemRect: local) else { return system }
        return window.convertToScreen(convert(tight, to: nil))
    }
    private func paintCaret(_ rect: NSRect) {
        caretPaintCount += 1
        OverlayTheme.editorInsertionColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: OverlayTheme.editorCaretRadius, yRadius: OverlayTheme.editorCaretRadius).fill()
    }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if flag {
            // A selection has no caret; never fall back to the system's tall one. Marked (IME) text keeps its caret.
            guard hasMarkedText() || selectedRange().length == 0, let caret = tightCaretRect(forSystemRect: rect) else { return }
            paintCaret(caret)
        } else {
            // Erase whatever was painted for this rect, in any state (the selection may have just changed).
            systemCaretCount += 1
            super.drawInsertionPoint(in: tightCaretRect(forSystemRect: rect) ?? rect, color: color, turnedOn: false)
        }
    }
    /// The system invalidates a 1pt-wide, line-high caret rect; the bar is wider and can poke a fraction of a point
    /// past the line fragment, so widen every invalidation to cover it.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(invalidRect.insetBy(dx: -OverlayTheme.editorCaretWidth, dy: -1), avoidAdditionalLayout: flag)
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func pasteAsPlainText(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { insertText(text, replacementRange: selectedRange()) }
    }
    private var markdownLayout: MarkdownLayoutManager? { layoutManager as? MarkdownLayoutManager }
    private func prepareSelection(_ ranges: [NSRange]) {
        if markdownLayout?.updateSelection(ranges, markedRange: hasMarkedText() ? markedRange() : NSRange(location: NSNotFound, length: 0)) == true {
            onPreviewChange?()
        }
    }
    override func setSelectedRange(_ charRange: NSRange) {
        prepareSelection([charRange]); super.setSelectedRange(charRange)
    }
    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        prepareSelection([charRange]); super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        prepareSelection(ranges.map(\.rangeValue)); super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markdownLayout?.prepareComposition()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markdownLayout?.synchronize(self)
        onPreviewChange?()
    }
    override func unmarkText() {
        super.unmarkText(); markdownLayout?.synchronize(self); onUnmark?()
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if !hasMarkedText(), let input = insertString as? String, input == " ",
           selectedRange().length == 0, let correction = taskAutocorrectionRange(before: selectedRange().location) {
            breakUndoCoalescing()
            super.insertText("[ ] ", replacementRange: correction)
            breakUndoCoalescing()
            markdownLayout?.synchronize(self)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
        markdownLayout?.synchronize(self)
    }
    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0,
              let correction = taskMarkerBackspaceRange(at: selectedRange().location) else {
            super.deleteBackward(sender)
            return
        }
        breakUndoCoalescing()
        if shouldChangeText(in: correction, replacementString: "") {
            textStorage?.replaceCharacters(in: correction, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: correction.location, length: 0))
        }
        breakUndoCoalescing()
    }
    /// The checkbox range under a point in this view's coordinates; nil unless one is rendered there.
    func checkbox(at point: NSPoint) -> NSRange? {
        guard !hasMarkedText(), let container = textContainer, let manager = markdownLayout else { return nil }
        return manager.checkbox(at: NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y), in: container)
    }
    /// True when the point is scrolled into view and the panel's hit test lands on this view, not a card or chrome.
    func isExposed(at point: NSPoint) -> Bool {
        guard visibleRect.contains(point), let host = window?.contentView?.superview else { return false }
        return window?.contentView?.hitTest(host.convert(point, from: self)) === self
    }
    func isOverCheckbox(at point: NSPoint) -> Bool { isExposed(at: point) && checkbox(at: point) != nil }
    /// One answer per position: over a rendered checkbox only the hand is set, so super's I-beam never flashes first;
    /// over a card or band the first-responder text view must not set its I-beam at all, `updatePointer` owns those.
    private func pointerEvent(_ event: NSEvent, _ forward: (NSEvent) -> Void) {
        let point = convert(event.locationInWindow, from: nil)
        if isOverCheckbox(at: point) { NSCursor.pointingHand.set() } else if isExposed(at: point) { forward(event) }
    }
    override func cursorUpdate(with event: NSEvent) { pointerEvent(event) { super.cursorUpdate(with: $0) } }
    override func mouseEntered(with event: NSEvent) { pointerEvent(event) { super.mouseEntered(with: $0) } }
    override func mouseMoved(with event: NSEvent) { pointerEvent(event) { super.mouseMoved(with: $0) } }
    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        let point = convert(event.locationInWindow, from: nil)
        guard let state = checkbox(at: point) else { super.mouseDown(with: event); return }
        let old = (self.string as NSString).substring(with: state)
        let replacement = old == " " ? "x" : " "
        breakUndoCoalescing()
        if shouldChangeText(in: state, replacementString: replacement) {
            textStorage?.replaceCharacters(in: state, with: replacement)
            didChangeText()
        }
        breakUndoCoalescing()
        window?.makeFirstResponder(self)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !hasMarkedText(), handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), handle(event) { return }
        super.keyDown(with: event)
    }
    func handle(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if let action = noteShortcutAction(for: event) { onShortcut?(action); return true }
            switch event.keyCode {
            case 6: if event.modifierFlags.contains(.shift) { history.redo() } else { history.undo() }
            case 9: paste(nil)
            case 8: copy(nil)
            case 40: onToggleActions?()
            case 7: cut(nil)
            case 0: selectAll(nil)
            case 36, 76: onSave?()
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 36, 76:
            if event.modifierFlags.contains(.shift) { insertText("\n", replacementRange: selectedRange()) }
            else { insertLineBreak() }
            return true
        case 48: indentList(outdent: event.modifierFlags.contains(.shift)); return true
        default: return false
        }
    }
    private func taskAutocorrectionRange(before caret: Int) -> NSRange? {
        let source = string as NSString
        guard caret >= 0, caret <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        guard caret >= line.location, !isInsideFencedCode(before: line.location) else { return nil }
        let prefixRange = NSRange(location: line.location, length: caret - line.location)
        let prefix = source.substring(with: prefixRange)
        let pattern = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+]) \[\]$"#)
        guard pattern?.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) != nil else { return nil }
        let brackets = (prefix as NSString).range(of: "[]", options: .backwards)
        guard brackets.location != NSNotFound else { return nil }
        return NSRange(location: line.location + brackets.location, length: brackets.length)
    }

    private func taskMarkerBackspaceRange(at caret: Int) -> NSRange? {
        let source = string as NSString
        guard caret >= 0, caret <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        let value = source.substring(with: line).trimmingCharacters(in: .newlines)
        let lineText = value as NSString
        let pattern = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+] )\[[ xX]\] "#)
        guard let match = pattern?.firstMatch(in: value, range: NSRange(location: 0, length: lineText.length)) else { return nil }
        let markerStart = line.location + NSMaxRange(match.range(at: 1))
        let markerEnd = line.location + match.range.location + match.range.length
        guard caret == markerEnd, markdownLayout?.isBlockMarkerActive(at: markerStart) != true else { return nil }
        let deletion = NSRange(location: markerStart + match.range(at: 2).length, length: 4)
        guard NSMaxRange(deletion) == caret else { return nil }
        return deletion
    }

    private func isInsideFencedCode(before lineStart: Int) -> Bool {
        let source = string as NSString
        if lineStart > 0, lineStart <= source.length, !hasMarkedText(),
           let storage = textStorage, storage.length > 0,
           let state = storage.attribute(MarkdownStyler.fenceStateAfter,
                                         at: min(lineStart - 1, storage.length - 1),
                                         effectiveRange: nil) as? MarkdownStyler.FenceState {
            return state.isOpen
        }
        var offset = 0
        var fence: (character: unichar, length: Int)?
        while offset < lineStart {
            let line = source.lineRange(for: NSRange(location: offset, length: 0))
            let value = source.substring(with: line).trimmingCharacters(in: .newlines) as NSString
            var indent = 0
            while indent < value.length, value.character(at: indent) == 32 { indent += 1 }
            var run = 0
            let first: unichar = indent < value.length ? value.character(at: indent) : 0
            if indent <= 3, first == 96 || first == 126 {
                while indent + run < value.length, value.character(at: indent + run) == first { run += 1 }
            }
            let rest = value.substring(from: min(value.length, indent + run))
            if let current = fence {
                if first == current.character, run >= current.length,
                   rest.trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
            } else if run >= 3, first != 96 || !rest.contains("`") {
                fence = (first, run)
            }
            let next = NSMaxRange(line)
            if next <= offset { break }
            offset = next
        }
        return fence != nil
    }
    private func listMatch(_ line: String) -> NSTextCheckingResult? {
        let regex = try? NSRegularExpression(pattern: #"^([ \t]*)([-*+] (?:\[[ xX]\] )?|([0-9]+)\. )(.*)$"#)
        return regex?.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }
    private func insertLineBreak() {
        let source = string as NSString
        let selection = selectedRange()
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        if isInsideFencedCode(before: lineRange.location) {
            insertText("\n", replacementRange: selection)
            return
        }
        let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard let match = listMatch(line) else { insertText("\n", replacementRange: selection); return }
        let value = line as NSString
        let indent = value.substring(with: match.range(at: 1))
        let marker = value.substring(with: match.range(at: 2))
        if value.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces).isEmpty {
            insertText("", replacementRange: NSRange(location: lineRange.location, length: match.range(at: 4).location))
            return
        }
        let next: String
        if match.range(at: 3).location != NSNotFound, let number = Int(value.substring(with: match.range(at: 3))), number < Int.max {
            next = "\(number + 1). "
        } else if marker.contains("[") { next = String(marker.prefix(2)) + "[ ] " }
        else { next = marker }
        insertText("\n" + indent + next, replacementRange: selection)
    }
    private func indentList(outdent: Bool) {
        let source = string as NSString
        let selection = selectedRange()
        // Exclude the next paragraph when a selection ends at its very beginning.
        let selected = NSRange(location: selection.location, length: max(0, selection.length - (selection.length > 0 ? 1 : 0)))
        let range = source.lineRange(for: selected)
        let original = source.substring(with: range)
        var changed = false
        let replacement = original.components(separatedBy: "\n").map { line -> String in
            guard listMatch(line) != nil else { return line }
            if outdent {
                let spaces = line.prefix(while: { $0 == " " }).count
                guard spaces > 0 else { return line }
                changed = true; return String(line.dropFirst(min(2, spaces)))
            }
            changed = true; return "  " + line
        }.joined(separator: "\n")
        guard changed else { return }
        insertText(replacement, replacementRange: range)
        let delta = (replacement as NSString).length - range.length
        if selection.length == 0 {
            setSelectedRange(NSRange(location: max(range.location, selection.location + delta), length: 0))
        } else { setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length)) }
    }
}


@MainActor
private final class PassiveView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class PassiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class NoteEditorView: FlippedView, NSTextViewDelegate, @MainActor NSTextStorageDelegate {
    let textView = NoteTextView(usingTextLayoutManager: false)
    let noteSurface = OverlaySurface(size: .zero, radius: OverlayTheme.quickPanelRadius)
    var usesGalleryBackground: Bool {
        get { noteSurface.usesGalleryBackground }
        set { noteSurface.usesGalleryBackground = newValue }
    }
    /// The window can extend below the note; only its surface is clipped and painted.
    var windowOverflowHeight: CGFloat = 0
    var noteRect: NSRect { noteSurface.frame }
    private let scroll = NSScrollView()
    private let placeholder = label("Start writing…", font: OverlayTheme.editorFont, color: OverlayTheme.tertiaryColor)
    private let title = PassiveLabel(labelWithString: "")
    private let titlePin = symbol("pin.fill", color: OverlayTheme.textColor)
    private let chrome = NoteChromeBar()
    private let footer = PassiveView()
    private let saveHint = KeycapView(key: "⌘↩", caption: "Create note")
    private let hints = [KeycapView(key: "⌘K", caption: "Actions"), KeycapView(key: "esc", caption: "Close")]
    private let restoredDraft: Bool
    private let draftLabel = label("Draft kept", font: OverlayTheme.metaFont, color: OverlayTheme.tertiaryColor)
    private var editedRange: NSRange?
    private var editedDelta = 0
    private var styling = false
    private var restyleForAppearance = false
    private var measurementTask: Task<Void, Never>?
    private var pendingMeasuredWidth: CGFloat = 0
    private var lastMeasuredAt = Date.distantPast
    private(set) var textHeight: CGFloat = 0
    private var documentHeight: CGFloat = 0
    private var currentWidth = OverlayTheme.quickMinWidth
    private var pointerInside = false
    private(set) var destination: String?
    private(set) var isPinned = false
    var holdsReveal = false { didSet { if holdsReveal != oldValue { applyReveal(animated: true) } } }
    var visibleScreenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 900 { didSet { if visibleScreenHeight != oldValue { measure() } } }
    var onChange: ((String) -> Void)?
    /// The name a new note gets for this text; the host supplies the real rule.
    var titleForText: (String) -> String = NoteEditorHandlers.defaultTitle { didSet { updateTitle() } }
    /// The title of an existing note that the text names, if saving would append to it; nil otherwise.
    var existingTitleForText: (String) -> String? = { _ in nil } { didSet { updateTitle() } }
    /// True while the typed title names an existing note, so saving appends to it rather than creating one.
    private(set) var appendsToExisting = false
    var onResize: ((NSSize, Bool) -> Void)?
    private func resize(animated: Bool = true) { onResize?(desiredSize, animated) }
    var onAction: ((NoteActionID) -> Void)?
    var hasActiveSession = false
    var onClose: (() -> Void)?
    var onBrowseChoice: ((BrowseItem, BrowseChoice) -> Void)?
    var browseItems: () -> [BrowseItem] = { [] }
    private var actionMenu: NoteActionMenuView? { didSet { chrome.isActionsOpen = actionMenu != nil } }
    private var browseView: NoteBrowseView? { didSet { chrome.isBrowseOpen = browseView != nil } }
    private var cardSize = NSSize.zero
    private var cardHeightLimit: CGFloat = .greatestFiniteMagnitude
    private var card: NoteCardView? { actionMenu ?? browseView }
    private var lineHeight: CGFloat { ceil((textView.layoutManager?.defaultLineHeight(for: OverlayTheme.editorFont) ?? OverlayTheme.editorFont.pointSize) * OverlayTheme.editorLineHeightMultiple) }
    private var bandsHeight: CGFloat { OverlayTheme.quickTopBandHeight + OverlayTheme.quickFooterHeight }
    var noteSize: NSSize { NSSize(width: currentWidth, height: ceil(bandsHeight + textHeight)) }
    var desiredSize: NSSize { windowSize(for: noteSize) }
    func windowSize(for note: NSSize) -> NSSize {
        guard let card else { return note }
        let bottom = OverlayTheme.quickTopBandHeight + OverlayTheme.cardTopGap + card.desiredSize.height + OverlayTheme.cardEdgeMargin
        return NSSize(width: note.width, height: max(note.height, ceil(bottom)))
    }
    /// Budget from the note's top edge to the visible screen bottom. Never move the note for a card.
    func limitCardHeight(noteTop: CGFloat, visibleBottom: CGFloat) {
        cardHeightLimit = max(0, noteTop - visibleBottom - OverlayTheme.quickTopBandHeight
                              - OverlayTheme.cardTopGap - OverlayTheme.cardEdgeMargin)
        card?.maximumHeight = cardHeightLimit
    }
    func updateCardSpace() {
        guard let panel = window as? OverlayPanel, let visible = panel.visibleScreenFrame else { return }
        limitCardHeight(noteTop: panel.noteFrame.maxY, visibleBottom: visible.minY)
        if card != nil { resize(animated: false) }
    }

    init(destination: String?, text: String, restoredDraft: Bool) {
        self.restoredDraft = restoredDraft
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(noteSurface)
        let manager = MarkdownLayoutManager()
        manager.enablePreview()
        textView.textContainer?.replaceLayoutManager(manager)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.font = OverlayTheme.editorFont
        textView.defaultParagraphStyle = bodyParagraphStyle
        textView.textColor = OverlayTheme.textColor
        textView.insertionPointColor = OverlayTheme.editorInsertionColor
        textView.textContainerInset = OverlayTheme.editorTextInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Note text")
        textView.string = text
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.onUnmark = { [weak self] in self?.refreshText() }
        textView.onPreviewChange = { [weak self] in
            guard let self, !self.styling else { return }
            self.measure()
        }
        textView.onToggleActions = { [weak self] in self?.toggleActions() }
        textView.onShortcut = { [weak self] in self?.perform($0) }
        textView.onMouseDown = { [weak self] in self?.hideCard() }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        draftLabel.isHidden = true // shown by updateDraftVisibility once the width is known
        title.font = OverlayTheme.quickTitleFont
        title.textColor = OverlayTheme.textColor
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.wraps = false
        title.cell?.isScrollable = false
        title.setAccessibilityElement(true)
        title.setAccessibilityRole(.staticText)
        chrome.onClose = { [weak self] in self?.hideCard(); self?.onClose?() }
        chrome.onOpenAsNote = { [weak self] in self?.hideCard(); self?.perform(.openAsNote) }
        chrome.onActions = { [weak self] in self?.toggleActions() }
        chrome.onBrowse = { [weak self] in self?.perform(.browse) }
        chrome.onNew = { [weak self] in self?.hideCard(); self?.perform(.newNote) }
        for view in [scroll, placeholder, title, titlePin, footer, chrome] { noteSurface.addSubview(view) }
        for view in [saveHint] + hints + [draftLabel] { footer.addSubview(view) }
        for view in [chrome, footer] { view.wantsLayer = true; view.alphaValue = 0 }
        titlePin.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: OverlayTheme.quickTitlePinSize, weight: .medium)
        titlePin.imageScaling = .scaleNone
        titlePin.setAccessibilityIdentifier("QuickNote.pinned")
        titlePin.isHidden = true
        titlePin.wantsLayer = true
        titlePin.alphaValue = OverlayTheme.quickTitleRestAlpha
        title.wantsLayer = true
        title.alphaValue = OverlayTheme.quickTitleRestAlpha
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        setDestination(destination, isPinned: false)
        refreshText()
        setFrameSize(desiredSize)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setDestination(_ title: String?, isPinned: Bool) {
        destination = title
        self.isPinned = isPinned
        titlePin.isHidden = !isPinned
        updateTitle()
        footer.needsLayout = true
        needsLayout = true
        measure() // the caption can raise the minimum width
    }
    /// Destination title, else the title the text will be saved under, else a placeholder name.
    private func updateTitle() {
        let text = textView.string
        var value = destination ?? OverlayTheme.quickEmptyTitle
        var appends = destination != nil
        if destination == nil, let first = text.firstIndex(where: { !$0.isWhitespace }) {
            // Only the head of the note can name it, so keep this cheap for long drafts: skip leading blank
            // lines, then hand over a bounded slice.
            let head = String(text[first...].prefix(2_000))
            // An existing note with this title wins; otherwise the title the text will be saved under.
            if let existing = existingTitleForText(head), !existing.isEmpty {
                value = existing
                appends = true
            } else {
                let named = titleForText(head)
                if !named.isEmpty { value = named }
            }
        }
        appendsToExisting = destination == nil && appends
        let caption = appends ? "Add to note" : "Create note"
        if saveHint.caption.stringValue != caption {
            saveHint.caption.stringValue = caption
            footer.needsLayout = true
            needsLayout = true
        }
        guard title.stringValue != value else { return }
        title.stringValue = value
        title.setAccessibilityValue(value)
        needsLayout = true
    }
    private func footerNaturalWidth(includeDraft: Bool) -> CGFloat {
        let items = [saveHint] + hints
        var width = OverlayTheme.quickFooterLeadingInset * 2 + items.reduce(0) { $0 + $1.desiredWidth }
            + OverlayTheme.footerHintGap * CGFloat(items.count - 1)
        if includeDraft { width += OverlayTheme.footerHintGap + labelFittingSize(of: draftLabel).width }
        return ceil(width)
    }
    /// "Draft kept" is the first thing dropped when the footer cannot fit even at the widest panel.
    private func updateDraftVisibility() {
        draftLabel.isHidden = !restoredDraft || footerNaturalWidth(includeDraft: true) > currentWidth
    }

    // MARK: Reveal
    func setRevealed(_ revealed: Bool, animated: Bool) {
        chrome.isActive = revealed
        let titleValue = revealed ? OverlayTheme.quickTitleRevealAlpha : OverlayTheme.quickTitleRestAlpha
        for (view, value) in [(chrome, revealed ? 1 : 0), (footer, revealed ? 1 : 0), (title, titleValue), (titlePin, titleValue)] as [(NSView, CGFloat)] {
            guard let layer = view.layer else { continue }
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.removeAnimation(forKey: "reveal")
            view.alphaValue = value
            guard animated, !OverlayTheme.reduceMotion else { continue }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = Float(value)
            animation.duration = revealed ? OverlayTheme.quickRevealIn : OverlayTheme.quickRevealOut
            animation.timingFunction = revealed ? OverlayTheme.easeOut : OverlayTheme.easeIn
            layer.add(animation, forKey: "reveal")
        }
    }
    private func applyReveal(animated: Bool) { setRevealed(pointerInside || holdsReveal, animated: animated) }
    /// Cursor rects and NSTextView's automatic unhide assume an active application. This panel borrows
    /// focus while its agent remains inactive, so handle the first movement explicitly, after AppKit.
    /// Scrolling passes `hover: false` so a list scrolling under a still pointer keeps its selection.
    func updatePointer(at point: NSPoint, hover: Bool = true) {
        let inside = noteRect.contains(point)
        if inside != pointerInside { pointerInside = inside; applyReveal(animated: true) }
        NSCursor.setHiddenUntilMouseMoves(false)
        let hit = hitTest(convert(point, to: superview))
        var ancestor = hover ? hit : nil
        while let view = ancestor, view !== self {
            if let row = view as? NoteCardRowView { row.hover(); break }
            ancestor = view.superview
        }
        let overFilter = card.map { $0.field.frame.contains($0.convert(point, from: self)) } ?? false
        let overText = card?.frame.contains(point) != true && scroll.frame.contains(noteSurface.convert(point, from: self))
        let overCheckbox = overText && textView.isOverCheckbox(at: textView.convert(point, from: self))
        (overCheckbox ? NSCursor.pointingHand : overFilter || overText ? NSCursor.iBeam : NSCursor.arrow).set()
    }
    override func mouseEntered(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerInside = false; applyReveal(animated: true) }
    /// Only the note's bands move it, never the card or the transparent overflow.
    func isDragHandle(at point: NSPoint) -> Bool {
        guard noteRect.contains(point) else { return false }
        let inBand = point.y < OverlayTheme.quickTopBandHeight || point.y >= noteRect.maxY - OverlayTheme.quickFooterHeight
        guard inBand, card?.frame.contains(point) != true else { return false }
        return !(chrome.isActive && chrome.hitTest(noteSurface.convert(point, from: self)) != nil)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let card, card.frame.contains(local) { return card.hitTest(local) }
        if !noteRect.contains(local) { return self } // A transparent click closes the card; never drags.
        let hit = super.hitTest(point)
        if hit === titlePin || hit === noteSurface || hit is NSVisualEffectView { return self }
        return hit ?? self
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let handle = isDragHandle(at: point)
        if let card, !card.frame.contains(point) { hideCard() }
        if handle, let panel = window as? OverlayPanel { panel.performMove(with: event); return }
        super.mouseDown(with: event)
    }
    /// Called once the panel is positioned and on screen; gallery hosts never call it and stay at rest.
    func revealIfPointerInside() {
        guard let window, noteRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        pointerInside = true
        applyReveal(animated: false)
    }

    // MARK: Actions
    func perform(_ id: NoteActionID) {
        switch id {
        case .copyMarkdown:
            guard !textView.string.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textView.string, forType: .string)
        case .discardDraft:
            let length = (textView.string as NSString).length
            guard length > 0 else { return }
            textView.insertText("", replacementRange: NSRange(location: 0, length: length)) // undoable; fires textDidChange
        case .browse: toggleBrowse()
        case .pin, .newNote, .openAsNote: onAction?(id)
        case .writeOutsideSession: if hasActiveSession { onAction?(id) }
        case .saveAsNewNote: if appendsToExisting { onAction?(id) } else { textView.onSave?() } // nothing to escape: plain save
        }
    }

    // MARK: Overlays
    // At most one card (Actions or Browse) is open. It hangs from the top-right corner under the band, the
    // note keeps its own extent; the transparent window grows down only to fit overflow, without animation.
    func toggleActions() { if actionMenu == nil { showActions() } else { hideActions() } }
    func showActions(query: String = "", selectedIndex: Int? = nil) {
        guard actionMenu == nil else { return }
        detachBrowse()
        let menu = NoteActionMenuView(items: NoteActionItem.standard(isPinned: isPinned, hasText: !textView.string.isEmpty,
                                                                     appendsToExisting: appendsToExisting, hasActiveSession: hasActiveSession),
                                      query: query, selectedIndex: selectedIndex)
        menu.onRun = { [weak self] id in self?.hideActions(); self?.perform(id) }
        menu.onClose = { [weak self] in self?.hideActions() }
        actionMenu = menu
        attach(menu)
    }
    func hideActions() {
        guard actionMenu != nil else { return }
        detachActions()
        cardClosed()
    }
    func showBrowse(items: [BrowseItem], query: String = "", selectedIndex: Int? = nil) {
        guard browseView == nil else { return }
        detachActions()
        let browse = NoteBrowseView(items: items, query: query, selectedIndex: selectedIndex)
        browse.onChoose = { [weak self] item, choice in self?.onBrowseChoice?(item, choice) }
        browse.onBack = { [weak self] in self?.hideBrowse() }
        browseView = browse
        attach(browse)
    }
    func refreshBrowseItems() {
        guard let current = browseView else { return }
        let query = current.field.stringValue
        let selectedID = current.selectedID
        let items = browseItems()
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        let matches = trimmedQuery.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
        let shown = Array((matches.filter(\.isPinned) + matches.filter { !$0.isPinned }).prefix(OverlayTheme.browseMaxRows))
        let selectedIndex = selectedID.flatMap { id in shown.firstIndex(where: { $0.id == id }) }
        detachBrowse()
        let browse = NoteBrowseView(items: items, query: query, selectedIndex: selectedIndex)
        browse.onChoose = { [weak self] item, choice in self?.onBrowseChoice?(item, choice) }
        browse.onBack = { [weak self] in self?.hideBrowse() }
        browseView = browse
        attach(browse)
    }
    func hideBrowse() {
        guard browseView != nil else { return }
        detachBrowse()
        cardClosed()
    }
    func toggleBrowse() { if browseView == nil { showBrowse(items: browseItems()) } else { hideBrowse() } }
    /// Closes whichever card is open.
    private func hideCard() { hideActions(); hideBrowse() }
    private func attach(_ card: NoteCardView) {
        if let panel = window as? OverlayPanel, let visible = panel.visibleScreenFrame {
            limitCardHeight(noteTop: panel.noteFrame.maxY, visibleBottom: visible.minY)
        }
        card.maximumHeight = cardHeightLimit
        card.setFrameSize(card.desiredSize)
        cardSize = card.frame.size
        addSubview(card)
        NotificationCenter.default.addObserver(self, selector: #selector(cardFrameChanged), name: NSView.frameDidChangeNotification, object: card)
        holdsReveal = true
        resize(animated: false)
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(card.field)
        card.tintFieldCaret()
        window?.invalidateShadow()
    }
    private func detachActions() {
        guard let menu = actionMenu else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: menu)
        menu.removeFromSuperview()
        actionMenu = nil
    }
    private func detachBrowse() {
        guard let browse = browseView else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: browse)
        browse.removeFromSuperview()
        browseView = nil
    }
    private func cardClosed() {
        holdsReveal = false
        needsLayout = true
        resize(animated: false)
        window?.makeFirstResponder(textView)
        window?.invalidateShadow()
    }
    @objc private func cardFrameChanged(_ note: Notification) {
        guard let card, card.frame.size != cardSize else { return }
        cardSize = card.frame.size
        needsLayout = true
        resize(animated: false)
        layoutSubtreeIfNeeded()
        window?.invalidateShadow()
    }
    /// Closes the topmost overlay; false when none is open.
    func closeOverlay() -> Bool {
        guard card != nil else { return false }
        hideCard()
        return true
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if let card {
            // Only the card's own field editor owns the keyboard; otherwise the card is stale.
            if let editor = card.field.currentEditor(), window?.firstResponder === editor {
                if let browse = card as? NoteBrowseView {
                    if browse.handle(event) { return true }
                    guard event.keyCode == 40, event.shortcutFlags == .command else { return false }
                    showActions() // closes Browse first
                    return true
                }
                if let menu = card as? NoteActionMenuView {
                    if menu.handle(event) { return true }
                    guard let action = noteShortcutAction(for: event) else { return false }
                    hideActions()
                    perform(action)
                    return true
                }
            }
            if event.keyCode == 53 || (event.keyCode == 40 && event.shortcutFlags == .command) { hideCard(); return true }
        }
        guard !textView.hasMarkedText() else { return false }
        return textView.handle(event)
    }

    func textDidChange(_ notification: Notification) { refreshText(); onChange?(textView.string) }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !styling, let manager = textView.layoutManager as? MarkdownLayoutManager else { return }
        manager.synchronize(textView)
    }
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        if !styling, editedMask.contains(.editedCharacters) {
            // The active AppKit SDK reports the affected character range in post-edit
            // coordinates; changeInLength recovers the replaced pre-edit span.
            editedRange = range
            editedDelta = delta
            (textView.layoutManager as? MarkdownLayoutManager)?.textDidEdit(range: range, changeInLength: delta)
        }
    }
    private func refreshText() {
        placeholder.isHidden = !textView.string.isEmpty
        updateTitle()
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        let source = text as NSString
        if editedDelta != 0, let safe = editedRange.map({ NSIntersectionRange($0, NSRange(location: 0, length: source.length)) }),
           source.length > 0 {
            let probe = min(safe.location, source.length - 1)
            let changedLine = source.paragraphRange(for: NSRange(location: probe, length: min(max(1, safe.length), source.length - probe)))
            MarkdownStyler.rebaseElementRanges(in: storage, after: NSMaxRange(changedLine), by: editedDelta)
            editedDelta = 0
        }
        guard !textView.hasMarkedText() else { return }
        let manager = textView.layoutManager as? MarkdownLayoutManager
        let localEdit = !restyleForAppearance && source.length > OverlayTheme.editorRestyleLimit ? editedRange : nil
        let safeEdit = localEdit.map { NSIntersectionRange($0, NSRange(location: 0, length: source.length)) }
        let changedParagraph: NSRange? = safeEdit.map { safe in
            let probe = min(safe.location, max(0, source.length - 1))
            return source.paragraphRange(for: NSRange(location: probe, length: min(max(1, safe.length), source.length - probe)))
        }
        let fullRestyle = changedParagraph == nil
        let start = changedParagraph?.location ?? 0
        let incomingFence = start > 0
            ? storage.attribute(MarkdownStyler.fenceStateAfter, at: start - 1, effectiveRange: nil) as? MarkdownStyler.FenceState ?? .outside
            : .outside
        let scan: MarkdownStyler.ScanResult
        if let changedParagraph, let safeEdit {
            let minimumEnd = max(NSMaxRange(changedParagraph), NSMaxRange(safeEdit))
            scan = MarkdownStyler.scan(text, from: start, startingFence: incomingFence) { line, state in
                guard NSMaxRange(line) >= minimumEnd, line.location < source.length,
                      let previousState = storage.attribute(MarkdownStyler.fenceStateAfter, at: line.location,
                                                            effectiveRange: nil) as? MarkdownStyler.FenceState else { return false }
                return state == previousState
            }
        } else {
            scan = MarkdownStyler.scan(text, from: 0, startingFence: .outside)
        }
        styling = true
        textView.undoManager?.disableUndoRegistration()
        storage.beginEditing()
        storage.setAttributes(typingAttributes, range: scan.processedRange)
        for span in scan.spans { storage.addAttributes(span.attributes, range: span.range) }
        normalizeLineHeights(in: scan.processedRange)
        storage.endEditing()
        manager?.finishTextEdit()
        manager?.synchronize(textView)
        manager?.applyParagraphs(in: scan.processedRange)
        if scan.processedRange.length > 0 {
            manager?.invalidateGlyphs(forCharacterRange: scan.processedRange, changeInLength: 0, actualCharacterRange: nil)
        }
        textView.undoManager?.enableUndoRegistration()
        styling = false; editedRange = nil; editedDelta = 0; restyleForAppearance = false
        textView.typingAttributes = typingAttributes
        if source.length > OverlayTheme.editorRestyleLimit {
            if let changedParagraph, !fullRestyle, currentWidth < OverlayTheme.quickMaxWidth {
                pendingMeasuredWidth = max(pendingMeasuredWidth, naturalTextWidth(in: changedParagraph))
            }
            scheduleMeasure(remeasureAllWidth: fullRestyle)
        } else {
            cancelPendingMeasure()
            measure()
        }
    }
    private var bodyParagraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
    }
    private var typingAttributes: [NSAttributedString.Key: Any] {
        var attributes = MarkdownStyler.baseAttributes
        attributes[.paragraphStyle] = bodyParagraphStyle
        return attributes
    }
    /// Body styling keeps the body line height even when every glyph uses the smaller code font.
    /// Normalize raw/preview variants too, so revealing task/quote syntax cannot change vertical layout.
    private func normalizeLineHeights(in range: NSRange) {
        guard let storage = textView.textStorage, let manager = textView.layoutManager, range.length > 0 else { return }
        let source = storage.string as NSString
        var offset = range.location
        while offset < NSMaxRange(range) {
            let line = NSIntersectionRange(source.lineRange(for: NSRange(location: offset, length: 0)), range)
            var height = lineHeight
            storage.enumerateAttribute(.font, in: line) { font, _, _ in
                if let font = font as? NSFont {
                    height = max(height, ceil(manager.defaultLineHeight(for: font) * OverlayTheme.editorLineHeightMultiple))
                }
            }
            for key in [NSAttributedString.Key.paragraphStyle, MarkdownStyler.rawParagraph, MarkdownStyler.previewParagraph] {
                var updates: [(NSRange, NSMutableParagraphStyle)] = []
                storage.enumerateAttribute(key, in: line) { value, run, _ in
                    guard let original = value as? NSParagraphStyle else { return }
                    let paragraph = original.mutableCopy() as! NSMutableParagraphStyle
                    paragraph.lineHeightMultiple = 1
                    paragraph.minimumLineHeight = height
                    paragraph.maximumLineHeight = height
                    updates.append((run, paragraph))
                }
                for (run, paragraph) in updates { storage.addAttribute(key, value: paragraph, range: run) }
            }
            offset = NSMaxRange(line)
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyleForAppearance = true
        refreshText() // Defer attributes until unmarkText if an IME is composing.
        textView.needsDisplay = true
    }
    /// Widest unwrapped paragraph (first N only) plus an allowance for list and quote indents.
    private func naturalTextWidth() -> CGFloat {
        guard let storage = textView.textStorage else { return 0 }
        let source = storage.string as NSString
        var widest: CGFloat = 0, seen = 0
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, stop in
            seen += 1
            if seen > OverlayTheme.quickMeasuredParagraphs { stop.pointee = true; return }
            widest = max(widest, self.naturalTextWidth(in: range))
        }
        return widest
    }
    private func naturalTextWidth(in range: NSRange) -> CGFloat {
        guard let storage = textView.textStorage, range.length > 0,
              range.location >= 0, NSMaxRange(range) <= storage.length else { return 0 }
        let box = storage.attributedSubstring(from: range).boundingRect(with: NSSize(width: 1_000_000, height: 1_000_000),
                                                                        options: [.usesLineFragmentOrigin])
        return ceil(box.width) + OverlayTheme.quickIndentAllowance
    }
    private func scheduleMeasure(remeasureAllWidth: Bool = false) {
        if remeasureAllWidth { pendingMeasuredWidth = max(pendingMeasuredWidth, naturalTextWidth()) }
        measurementTask?.cancel()
        let now = Date()
        let quietDeadline = now.addingTimeInterval(0.18)
        let maximumStalenessDeadline = lastMeasuredAt.addingTimeInterval(0.25)
        let wait = max(0, min(quietDeadline, maximumStalenessDeadline).timeIntervalSince(now))
        measurementTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(Int((wait * 1_000).rounded()))) } catch { return }
            guard let self else { return }
            let width = self.pendingMeasuredWidth
            self.pendingMeasuredWidth = 0
            self.measurementTask = nil
            self.measure(textWidth: width)
        }
    }
    func cancelPendingMeasure() {
        measurementTask?.cancel()
        measurementTask = nil
        pendingMeasuredWidth = 0
    }
    private func layoutText() {
        let inset = OverlayTheme.quickTextInset
        // Ends exactly at the top of the bottom band.
        let height = max(textHeight, noteSurface.bounds.height - bandsHeight)
        scroll.frame = NSRect(x: inset, y: OverlayTheme.quickTopBandHeight, width: currentWidth - inset * 2, height: height)
        textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(textHeight, documentHeight)))
    }
    private func measure(textWidth: CGFloat? = nil) {
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }
        // The width only ratchets up, so skip measuring once it is at the cap.
        let floor = max(OverlayTheme.quickMinWidth, footerNaturalWidth(includeDraft: restoredDraft))
        let width = currentWidth >= OverlayTheme.quickMaxWidth ? currentWidth
            : min(OverlayTheme.quickMaxWidth,
                  max(floor, (textWidth ?? naturalTextWidth()) + OverlayTheme.quickTextInset * 2))
        let grew = width > currentWidth
        if grew { currentWidth = width }
        updateDraftVisibility()
        layoutText()
        manager.ensureLayout(for: container)
        // usedRect already includes the trailing empty fragment that holds the caret.
        let used = manager.usedRect(for: container).height
        let minimum = lineHeight * CGFloat(OverlayTheme.editorMinLines)
        let maximum = max(minimum, min(visibleScreenHeight * OverlayTheme.quickMaxHeightFraction, OverlayTheme.quickMaxHeight) - bandsHeight)
        documentHeight = max(minimum, used)
        let height = min(maximum, documentHeight)
        scroll.hasVerticalScroller = used > maximum
        if textHeight != height || grew { textHeight = height; resize() }
        // `usedRect` follows a full accurate AppKit layout so every line remains scrollable.
        // Editor changes coalesce that necessary work to the quiet period / 250 ms cap above.
        lastMeasuredAt = Date()
        needsLayout = true
    }
    func setPreviewSelection(_ selection: NSRange) {
        textView.setSelectedRange(selection)
        measure(); setFrameSize(desiredSize)
    }
    override func layout() {
        super.layout()
        noteSurface.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - windowOverflowHeight))
        let inset = OverlayTheme.quickTextInset
        chrome.frame = NSRect(x: 0, y: 0, width: bounds.width, height: OverlayTheme.quickTopBandHeight)
        layoutText()
        let titleSize = labelFittingSize(of: title)
        let pinExtent = isPinned ? OverlayTheme.quickTitlePinSize + OverlayTheme.quickTitlePinGap : 0
        let available = max(0, bounds.width - 2 * (NoteChromeBar.widestExtent + OverlayTheme.quickTitleClusterGap))
        let titleWidth = min(titleSize.width, max(0, available - pinExtent))
        let leading = (bounds.width - titleWidth - pinExtent) / 2
        titlePin.frame = NSRect(x: leading, y: (OverlayTheme.quickTopBandHeight - OverlayTheme.quickTitlePinSize) / 2,
                                width: OverlayTheme.quickTitlePinSize, height: OverlayTheme.quickTitlePinSize)
        title.frame = NSRect(x: leading + pinExtent, y: (OverlayTheme.quickTopBandHeight - titleSize.height) / 2,
                             width: titleWidth, height: titleSize.height)
        placeholder.frame = NSRect(x: inset, y: OverlayTheme.quickTopBandHeight, width: currentWidth - inset * 2, height: lineHeight)
        footer.frame = NSRect(x: 0, y: noteSurface.bounds.height - OverlayTheme.quickFooterHeight, width: bounds.width, height: OverlayTheme.quickFooterHeight)
        let hintY = (OverlayTheme.quickFooterHeight - OverlayTheme.hintHeight) / 2
        var x = OverlayTheme.quickFooterLeadingInset
        for hint in [saveHint] + hints {
            hint.frame = NSRect(x: x, y: hintY, width: hint.desiredWidth, height: OverlayTheme.hintHeight)
            x = hint.frame.maxX + OverlayTheme.footerHintGap
        }
        if let card {
            cardSize = card.desiredSize
            card.setFrameSize(cardSize)
        }
        card?.setFrameOrigin(NSPoint(x: bounds.width - OverlayTheme.cardEdgeMargin - (card?.frame.width ?? 0),
                                     y: OverlayTheme.quickTopBandHeight + OverlayTheme.cardTopGap))
        let size = labelFittingSize(of: draftLabel)
        draftLabel.frame = NSRect(x: bounds.width - OverlayTheme.quickFooterLeadingInset - size.width,
                                  y: (OverlayTheme.quickFooterHeight - size.height) / 2, width: size.width, height: size.height)
    }
}

public struct NoteEditorHandlers {
    public var onDraft: (String) throws -> Void
    public var onSubmit: (String) -> Void
    public var onNew: (String) -> Void
    public var onOpenAsNote: (String) -> Void
    public var browseItems: () -> [BrowseItem]
    public var onBrowse: (BrowseItem, BrowseChoice) -> Void
    public var onTogglePin: () -> Bool
    public var onClose: () -> Void
    public var onError: (Error) -> Void
    /// The title a new note gets for this text, shown in the top band until a destination is chosen.
    public var titleForText: (String) -> String
    /// The title of the existing note this text would append to, or nil when saving creates a new note.
    public var existingTitleForText: (String) -> String?
    /// Fast, coalesced persistence path for edits; `onDraft` remains the synchronous flush barrier.
    public var onScheduleDraft: (String) -> Void
    /// Creates a new note from this text although its title names an existing one (the Save as New Note escape).
    public var onSaveAsNew: (String) -> Void
    public var onWriteOutsideSession: (() -> Void)?

    public init(onDraft: @escaping (String) throws -> Void, onSubmit: @escaping (String) -> Void,
                onNew: @escaping (String) -> Void, onOpenAsNote: @escaping (String) -> Void,
                browseItems: @escaping () -> [BrowseItem], onBrowse: @escaping (BrowseItem, BrowseChoice) -> Void,
                onTogglePin: @escaping () -> Bool, onClose: @escaping () -> Void, onError: @escaping (Error) -> Void,
                titleForText: @escaping (String) -> String = NoteEditorHandlers.defaultTitle,
                onScheduleDraft: ((String) -> Void)? = nil,
                existingTitleForText: @escaping (String) -> String? = { _ in nil },
                onSaveAsNew: @escaping (String) -> Void = { _ in },
                onWriteOutsideSession: (() -> Void)? = nil) {
        self.onDraft = onDraft; self.onSubmit = onSubmit; self.onNew = onNew; self.onOpenAsNote = onOpenAsNote
        self.browseItems = browseItems; self.onBrowse = onBrowse; self.onTogglePin = onTogglePin
        self.onClose = onClose; self.onError = onError; self.titleForText = titleForText
        self.existingTitleForText = existingTitleForText; self.onSaveAsNew = onSaveAsNew
        self.onWriteOutsideSession = onWriteOutsideSession
        self.onScheduleDraft = onScheduleDraft ?? { text in
            do { try onDraft(text) } catch { onError(error) }
        }
    }

    /// First non-blank line with leading Markdown markers (heading, list, task box, quote, number) removed.
    public static func defaultTitle(_ text: String) -> String {
        guard var line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains { !$0.isWhitespace } }).map(String.init) else { return "" }
        let marker = #"^[ \t]*(?:#+[ \t]+|[-*+][ \t]+(?:\[[ xX]\][ \t]*)?|[0-9]+[.)][ \t]+|>[ \t]*)"#
        while let range = line.range(of: marker, options: .regularExpression) { line.removeSubrange(range) }
        line = line.trimmingCharacters(in: .whitespaces)
        let limit = OverlayTheme.quickTitleLimit
        return line.count > limit ? String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

/// Shares OverlayPanel's borrowed keyboard focus and synchronous focus release.
@MainActor
public final class NoteEditorPanel {
    private var panel: OverlayPanel?
    private var content: NoteEditorView?
    public var isVisible: Bool { panel?.isVisible == true }
    public var isKey: Bool { panel?.isKeyWindow == true }
    /// Borrow focus again without rebuilding the editor or changing selection/scroll position.
    public func focus() { if isVisible { panel?.makeKey(); panel?.orderFrontRegardless() } }
    public init() {}

    public func present(destination: String?, isPinned: Bool, draft: String, handlers: NoteEditorHandlers) {
        let view = NoteEditorView(destination: destination, text: draft, restoredDraft: !draft.isEmpty)
        view.setDestination(destination, isPinned: isPinned)
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            view.visibleScreenHeight = screen.visibleFrame.height
        }
        let panel = OverlayPanel(interactive: true, size: view.desiredSize, movable: true)
        panel.isSticky = true
        panel.onResignKey = { [weak view, weak panel] in
            _ = view?.closeOverlay()
            if let text = view?.textView { panel?.makeFirstResponder(text) }
        }
        panel.onDismiss = { [weak view] in _ = view?.closeOverlay() }
        content = view; self.panel = panel
        panel.setAccessibilityTitle("Write a note")
        panel.onKey = { [weak view] event in
            view?.handleKey(event) ?? false
        }
        panel.onScreenChange = { [weak view] visible in
            view?.visibleScreenHeight = visible.height
            view?.updateCardSpace()
        }
        panel.cancelHandler = { [weak view] in view?.closeOverlay() ?? false }
        view.titleForText = handlers.titleForText
        view.existingTitleForText = handlers.existingTitleForText
        view.hasActiveSession = handlers.onWriteOutsideSession != nil
        view.browseItems = handlers.browseItems
        view.onBrowseChoice = { [weak panel, weak view] item, choice in
            if choice == .write { handlers.onBrowse(item, choice); view?.hideBrowse(); return }
            guard let panel else { return }
            panel.dismiss()
            if !panel.isVisible { handlers.onBrowse(item, choice) }
        }
        panel.shouldDismiss = { [weak view] in
            guard let view else { return true }
            do { try handlers.onDraft(view.textView.string); return true }
            catch { handlers.onError(error); return false }
        }
        view.onChange = handlers.onScheduleDraft
        view.onResize = { [weak panel] size, animated in panel?.resizeContent(to: size, animated: animated) }
        view.onClose = { [weak panel] in panel?.dismiss() }
        view.textView.onSave = { [weak panel, weak view] in
            guard let panel, let view else { return }
            let text = view.textView.string
            panel.dismiss()
            if !panel.isVisible { handlers.onSubmit(text) }
        }
        view.onAction = { [weak panel, weak view] id in
            guard let panel, let view else { return }
            let text = view.textView.string
            switch id {
            case .newNote:
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { handlers.onNew("") }
                else { panel.dismiss(); if !panel.isVisible { handlers.onNew(text) } }
            case .openAsNote:
                panel.dismiss()
                if !panel.isVisible { handlers.onOpenAsNote(text) }
            case .saveAsNewNote: // the editor view only forwards this while saving would append
                panel.dismiss()
                if !panel.isVisible { handlers.onSaveAsNew(text) }
            case .pin:
                view.setDestination(view.destination, isPinned: handlers.onTogglePin())
            case .writeOutsideSession:
                handlers.onWriteOutsideSession?()
            case .browse, .copyMarkdown, .discardDraft:
                break // Browse is wired with the overlays; copy and discard are handled by the editor view.
            }
        }
        panel.onClose = { [weak self] in self?.content = nil; self?.panel = nil; handlers.onClose() }
        panel.present(content: view)
        view.revealIfPointerInside()
        panel.makeFirstResponder(view.textView)
        view.textView.scrollRangeToVisible(view.textView.selectedRange())
    }

    public func setDestination(_ title: String?, isPinned: Bool) { content?.setDestination(title, isPinned: isPinned) }
    @discardableResult
    public func dismiss() -> Bool {
        guard let panel else { return true }
        return panel.dismiss()
    }

    /// Refresh an open Browse card after its asynchronous note snapshot arrives. Keep its
    /// filter text and selected item when that item is still present in the new snapshot.
    public func refreshBrowseItems() { content?.refreshBrowseItems() }
}
