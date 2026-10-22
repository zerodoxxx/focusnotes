import AppKit

struct NoteActionItem {
    var id: NoteActionID
    var title: String
    var symbolName: String
    var shortcut: String
    var isEnabled: Bool
    /// Rows in different groups are divided by a separator.
    var group: Int

    /// `appendsToExisting`: the typed title names an existing note, so saving would append; the escape row is then live.
    @MainActor static func standard(isPinned: Bool, hasText: Bool, appendsToExisting: Bool = false, hasActiveSession: Bool = false) -> [NoteActionItem] {
        var items = [
            NoteActionItem(id: .newNote, title: "New Note", symbolName: "plus", shortcut: "⌘N", isEnabled: true, group: 0),
            NoteActionItem(id: .saveAsNewNote, title: "Save as New Note", symbolName: "doc.badge.plus", shortcut: "⌥⌘↩",
                           isEnabled: appendsToExisting, group: 0),
            NoteActionItem(id: .pin, title: isPinned ? "Remove from Pinned" : "Add to Pinned", symbolName: isPinned ? "pin.slash" : "pin",
                           shortcut: "⇧⌘P", isEnabled: true, group: 0),
            NoteActionItem(id: .openAsNote, title: "Open as Note", symbolName: "arrow.up.left.and.arrow.down.right",
                           shortcut: "⌘O", isEnabled: true, group: 1),
            NoteActionItem(id: .copyMarkdown, title: "Copy as Markdown", symbolName: "doc.on.doc", shortcut: "⇧⌘C", isEnabled: hasText, group: 1),
            NoteActionItem(id: .discardDraft, title: "Discard Draft", symbolName: "trash", shortcut: "⇧⌘⌫", isEnabled: hasText, group: 1),
        ]
        if hasActiveSession {
            items.insert(NoteActionItem(id: .writeOutsideSession, title: "Write outside session", symbolName: "arrow.turn.up.right",
                                        shortcut: "⇧⌘N", isEnabled: true, group: 0), at: 1)
        }
        return items
    }
}

/// The surface shared by the Actions and Browse cards: fill, border, shadow and the filter-field header.
@MainActor
class NoteCardView: FlippedView, NSTextFieldDelegate {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    let field: NSTextField
    private let headerSeparator = SeparatorView()
    var maximumHeight: CGFloat = .greatestFiniteMagnitude { didSet { needsLayout = true } }
    func cappedHeight(_ height: CGFloat) -> CGFloat { min(height, maximumHeight) }
    func tintFieldCaret() { (field.currentEditor() as? NSTextView)?.insertionPointColor = OverlayTheme.brandAccent }
    func controlTextDidBeginEditing(_ obj: Notification) { tintFieldCaret() }

    /// Where the card's content starts, below the filter field and its separator.
    var contentTop: CGFloat { OverlayTheme.cardFieldHeight + OverlayTheme.borderWidth }
    /// The size the card needs for its current content.
    var desiredSize: NSSize { NSSize(width: OverlayTheme.menuWidth, height: contentTop) }

    init(placeholder: String, query: String) {
        field = OverlayTextField(placeholder: placeholder)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = OverlayTheme.cardRadius
        layer?.borderWidth = OverlayTheme.borderWidth
        layer?.shadowRadius = OverlayTheme.menuShadowRadius
        layer?.shadowOpacity = OverlayTheme.menuShadowOpacity
        layer?.shadowOffset = OverlayTheme.menuShadowOffset
        field.font = OverlayTheme.cardFieldFont
        field.stringValue = query
        field.delegate = self
        addSubview(field)
        addSubview(headerSeparator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func controlTextDidChange(_ obj: Notification) {}

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = OverlayTheme.cardFill.cgColor
            layer?.borderColor = OverlayTheme.cardBorder.cgColor
        }
        layer?.shadowColor = NSColor.black.cgColor
        let fieldHeight = labelFittingSize(of: field).height
        let inset = OverlayTheme.cardFieldInset
        field.frame = NSRect(x: inset, y: (OverlayTheme.cardFieldHeight - fieldHeight) / 2,
                             width: bounds.width - inset * 2, height: fieldHeight)
        headerSeparator.frame = NSRect(x: 0, y: OverlayTheme.cardFieldHeight, width: bounds.width, height: OverlayTheme.borderWidth)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true; tintFieldCaret() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The transparent window casts one shadow from the union of the visible shapes.
        layer?.shadowOpacity = window?.hasShadow == true ? 0 : OverlayTheme.menuShadowOpacity
    }
}

/// One bordered box per key glyph (⇧ ⌘ P is three boxes).
@MainActor
private final class KeycapBoxesView: FlippedView {
    private let glyphs: [String]
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: OverlayTheme.keycapGlyphFont, .foregroundColor: OverlayTheme.secondaryColor]

    init(shortcut: String) {
        glyphs = shortcut.map(String.init)
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func boxWidth(_ glyph: String) -> CGFloat {
        max(OverlayTheme.keycapBoxMin, ceil(glyph.size(withAttributes: Self.attributes).width) + OverlayTheme.keycapBoxPadding * 2)
    }
    var desiredWidth: CGFloat {
        glyphs.reduce(0) { $0 + boxWidth($1) } + OverlayTheme.keycapBoxGap * CGFloat(max(0, glyphs.count - 1))
    }
    override func draw(_ dirtyRect: NSRect) {
        let height = OverlayTheme.keycapBoxMin
        var x: CGFloat = 0
        for glyph in glyphs {
            let width = boxWidth(glyph)
            let box = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: OverlayTheme.borderWidth / 2, dy: OverlayTheme.borderWidth / 2),
                                    xRadius: OverlayTheme.keycapBoxRadius, yRadius: OverlayTheme.keycapBoxRadius)
            path.lineWidth = OverlayTheme.borderWidth
            OverlayTheme.keycapBoxBorder.setStroke()
            path.stroke()
            let size = glyph.size(withAttributes: Self.attributes)
            glyph.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: Self.attributes)
            x += width + OverlayTheme.keycapBoxGap
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Decorative labels and symbols must not intercept a row's mouse click in an inactive app.
@MainActor
class NoteCardRowView: FlippedView {
    var onHover: (() -> Void)?
    func hover() { onHover?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

@MainActor
private final class ActionRowView: NoteCardRowView {
    let item: NoteActionItem
    let icon: NSImageView
    let title: NSTextField
    let keys: KeycapBoxesView
    var isSelected = false { didSet { needsLayout = true; icon.contentTintColor = isSelected ? OverlayTheme.textColor : OverlayTheme.secondaryColor; setAccessibilityValue(isSelected ? "Selected" : "") } }
    var onClick: (() -> Void)?

    init(item: NoteActionItem) {
        self.item = item
        icon = symbol(item.symbolName, color: OverlayTheme.secondaryColor)
        title = label(item.title, font: OverlayTheme.menuFont, color: OverlayTheme.textColor)
        keys = KeycapBoxesView(shortcut: item.shortcut)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = OverlayTheme.menuRowRadius
        [icon, title, keys].forEach { addSubview($0); $0.alphaValue = item.isEnabled ? 1 : OverlayTheme.menuDisabledAlpha }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityEnabled(item.isEnabled)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func accessibilityPerformPress() -> Bool { guard item.isEnabled else { return false }; onClick?(); return true }
    override func mouseDown(with event: NSEvent) { if item.isEnabled { onClick?() } }
    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected ? OverlayTheme.menuSelectedFill.cgColor : nil
        }
        // The row sits menuRowInset inside the card; content insets are measured from the card's edges.
        let inset = OverlayTheme.menuContentInset - OverlayTheme.menuRowInset
        let size = OverlayTheme.menuIconSize
        icon.frame = NSRect(x: inset, y: (bounds.height - size) / 2, width: size, height: size)
        let keysWidth = keys.desiredWidth
        keys.frame = NSRect(x: bounds.width - inset - keysWidth, y: 0, width: keysWidth, height: bounds.height)
        let x = inset + size + OverlayTheme.menuIconGap
        let height = labelFittingSize(of: title).height
        title.frame = NSRect(x: x, y: (bounds.height - height) / 2,
                             width: max(0, keys.frame.minX - OverlayTheme.iconGap - x), height: height)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
}

@MainActor
final class NoteActionMenuView: NoteCardView {
    var onRun: ((NoteActionID) -> Void)?
    var onClose: (() -> Void)?
    var selectedID: NoteActionID? { selection.flatMap { visible.indices.contains($0) ? visible[$0].id : nil } }
    override var desiredSize: NSSize {
        NSSize(width: OverlayTheme.menuWidth, height: cappedHeight(contentTop + OverlayTheme.cardVerticalPadding * 2 + listHeight))
    }

    private var items: [NoteActionItem]
    private var visible: [NoteActionItem] = []
    private var rows: [ActionRowView] = []
    private var dividers: [SeparatorView] = []
    private var selection: Int?
    private let rowsContainer = NoteCardDocumentView()
    private let scroll = NSScrollView()

    private var dividerHeight: CGFloat { OverlayTheme.menuGroupMargin * 2 + OverlayTheme.borderWidth }
    private var groupBreaks: Int { zip(visible, visible.dropFirst()).filter { $0.group != $1.group }.count }
    private var listHeight: CGFloat { CGFloat(visible.count) * OverlayTheme.menuRowHeight + CGFloat(groupBreaks) * dividerHeight }

    init(items: [NoteActionItem], query: String = "", selectedIndex: Int? = nil) {
        self.items = items
        super.init(placeholder: "Search actions…", query: query)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rowsContainer
        addSubview(scroll)
        rebuild(preferred: selectedIndex)
        setFrameSize(desiredSize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125, 126: move(event.keyCode == 125 ? 1 : -1); return true
        case 36, 76:
            if let index = selection, visible.indices.contains(index), visible[index].isEnabled { onRun?(visible[index].id) }
            return true
        case 53: onClose?(); return true
        case 40 where event.shortcutFlags == .command: onClose?(); return true
        default: return false
        }
    }

    override func controlTextDidChange(_ obj: Notification) { rebuild(preferred: nil); setFrameSize(desiredSize) }

    private func rebuild(preferred: Int?) {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        visible = query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) }
        rows.forEach { $0.removeFromSuperview() }
        dividers.forEach { $0.removeFromSuperview() }
        rows = visible.enumerated().map { index, item in
            let row = ActionRowView(item: item)
            row.onClick = { [weak self] in self?.onRun?(item.id) }
            row.onHover = { [weak self] in
                guard item.isEnabled else { return }
                self?.selection = index; self?.applySelection()
            }
            rowsContainer.addSubview(row)
            return row
        }
        dividers = (0..<groupBreaks).map { _ in
            let divider = SeparatorView()
            rowsContainer.addSubview(divider)
            return divider
        }
        if let preferred, visible.indices.contains(preferred), visible[preferred].isEnabled { selection = preferred }
        else { selection = visible.firstIndex(where: \.isEnabled) }
        applySelection()
        needsLayout = true
    }

    private func move(_ step: Int) {
        let enabled = visible.indices.filter { visible[$0].isEnabled }
        guard !enabled.isEmpty else { return }
        guard let current = selection, let position = enabled.firstIndex(of: current) else {
            selection = step > 0 ? enabled.first : enabled.last
            applySelection(); return
        }
        selection = enabled[min(enabled.count - 1, max(0, position + step))]
        applySelection()
        if let selection { rowsContainer.scrollToVisible(rows[selection].frame) }
    }

    private func applySelection() {
        for (index, row) in rows.enumerated() { row.isSelected = index == selection && row.item.isEnabled }
        let value = selectedID.map { id in visible.first { $0.id == id }?.title ?? "" } ?? ""
        field.setAccessibilityValue(value)
    }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: contentTop, width: bounds.width, height: max(0, bounds.height - contentTop))
        rowsContainer.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                                     height: listHeight + OverlayTheme.cardVerticalPadding * 2)
        var y = OverlayTheme.cardVerticalPadding
        var divider = 0
        for (index, row) in rows.enumerated() {
            if index > 0, visible[index].group != visible[index - 1].group {
                // Separators are inset like the filter field, measured from the card's edges.
                let inset = OverlayTheme.cardFieldInset
                dividers[divider].frame = NSRect(x: inset, y: y + OverlayTheme.menuGroupMargin,
                                                 width: rowsContainer.bounds.width - inset * 2, height: OverlayTheme.borderWidth)
                divider += 1
                y += dividerHeight
            }
            row.frame = NSRect(x: OverlayTheme.menuRowInset, y: y, width: rowsContainer.bounds.width - OverlayTheme.menuRowInset * 2, height: OverlayTheme.menuRowHeight)
            y += OverlayTheme.menuRowHeight
        }
    }
}
