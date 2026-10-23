import AppKit

@MainActor
private final class BrowseRowView: NoteCardRowView {
    let item: BrowseItem
    let icon: NSImageView
    let title: NSTextField
    let detail: NSTextField
    let pin: NSImageView?
    var isSelected = false { didSet { needsLayout = true; setAccessibilityValue(isSelected ? "Selected" : "") } }
    var onClick: (() -> Void)?

    init(item: BrowseItem) {
        self.item = item
        icon = symbol(item.symbolName, color: OverlayTheme.secondaryColor)
        title = label(item.title, font: OverlayTheme.browseTitleFont, color: OverlayTheme.textColor)
        detail = label(item.detail, font: OverlayTheme.metaFont, color: OverlayTheme.secondaryColor)
        pin = item.isPinned ? symbol("pin.fill", color: OverlayTheme.tertiaryColor) : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = OverlayTheme.menuRowRadius
        [icon, title, detail].forEach(addSubview)
        if let pin { addSubview(pin) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([item.title, item.detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelected ? OverlayTheme.menuSelectedFill.cgColor : nil
        }
        // The row sits menuRowInset inside the card; content insets are measured from the card's edges.
        let inset = OverlayTheme.menuContentInset - OverlayTheme.menuRowInset
        let iconSize = OverlayTheme.browseIconSize
        icon.frame = NSRect(x: inset, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        var trailing = bounds.width - inset
        if let pin {
            let size = OverlayTheme.browsePinSize
            pin.frame = NSRect(x: trailing - size, y: (bounds.height - size) / 2, width: size, height: size)
            trailing -= size + OverlayTheme.browseRowTextInset
        }
        let x = inset + iconSize + OverlayTheme.browseRowTextInset
        let hasDetail = !detail.stringValue.isEmpty
        let titleHeight = labelFittingSize(of: title).height
        let detailHeight = hasDetail ? labelFittingSize(of: detail).height : 0
        let gap = hasDetail ? OverlayTheme.browseDetailGap : 0
        let y = (bounds.height - (titleHeight + gap + detailHeight)) / 2
        let width = max(0, trailing - x)
        title.frame = NSRect(x: x, y: y, width: width, height: titleHeight)
        detail.frame = NSRect(x: x, y: y + titleHeight + gap, width: width, height: detailHeight)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
}

@MainActor
final class NoteBrowseView: NoteCardView {
    var onChoose: ((BrowseItem, BrowseChoice) -> Void)?
    var onBack: (() -> Void)?

    private var items: [BrowseItem]
    private var shown: [BrowseItem] = []
    private var rows: [BrowseRowView] = []
    private var headers: [(label: NSTextField, beforeRow: Int)] = []
    private var selection: Int?
    var selectedID: String? { selection.flatMap { shown.indices.contains($0) ? shown[$0].id : nil } }
    private let scroll = NSScrollView()
    private let document = NoteCardDocumentView()
    private let footer = NoteCardDocumentView()
    private let footerSeparator = SeparatorView()
    private let footerHints = [("↩", "Write here"), ("⌘↩", "Open"), ("⌥↩", "Reveal")].map { KeycapView(key: $0.0, caption: $0.1) }
    private var footerHeight: CGFloat { OverlayTheme.borderWidth + OverlayTheme.browseFooterHeight }
    private let message = label("", font: OverlayTheme.messageFont, color: OverlayTheme.secondaryColor)

    /// Row and header origins inside the document, the document height and the height of the visible window
    /// onto it (at most `browseVisibleRows` rows, with their section headers).
    private var metrics: (rowY: [CGFloat], headerY: [CGFloat], document: CGFloat, visible: CGFloat) {
        let pad = OverlayTheme.cardVerticalPadding
        var y = pad
        var rowY: [CGFloat] = [], headerY: [CGFloat] = []
        var visibleEnd = pad
        var header = 0
        for index in rows.indices {
            if header < headers.count, headers[header].beforeRow == index {
                headerY.append(y)
                y += OverlayTheme.browseHeaderHeight
                header += 1
            }
            rowY.append(y)
            y += OverlayTheme.browseRowHeight
            if index < OverlayTheme.browseVisibleRows { visibleEnd = y }
        }
        return (rowY, headerY, y + pad, min(y, visibleEnd) + pad)
    }
    override var desiredSize: NSSize {
        NSSize(width: OverlayTheme.browseCardWidth,
               height: cappedHeight(contentTop + (shown.isEmpty ? OverlayTheme.browseEmptyHeight : metrics.visible) + footerHeight))
    }

    /// `selectedID` wins over `selectedIndex` when it matches a shown row; otherwise `selectedIndex` applies.
    init(items: [BrowseItem], query: String = "", selectedIndex: Int? = nil, selectedID: String? = nil) {
        self.items = items
        super.init(placeholder: "Search notes…", query: query)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        message.alignment = .center
        [scroll, message, footerSeparator, footer].forEach { addSubview($0) }
        footerHints.forEach(footer.addSubview)
        rebuild(preferred: selectedIndex, preferredID: selectedID)
        setFrameSize(desiredSize)
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        if let selection, selection > 0 { document.scrollToVisible(rows[selection].frame) }
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125, 126:
            guard !shown.isEmpty else { return true }
            select(min(shown.count - 1, max(0, (selection ?? (event.keyCode == 125 ? -1 : shown.count)) + (event.keyCode == 125 ? 1 : -1))))
            return true
        case 36, 76:
            guard let selection, shown.indices.contains(selection) else { return true }
            let flags = event.shortcutFlags
            choose(selection, flags.contains(.command) ? .open : (flags.contains(.option) ? .reveal : .write))
            return true
        case 53: onBack?(); return true
        case 35 where event.shortcutFlags == .command: onBack?(); return true
        default: return false
        }
    }

    override func controlTextDidChange(_ obj: Notification) {
        rebuild(preferred: nil)
        setFrameSize(desiredSize)
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func choose(_ index: Int, _ choice: BrowseChoice) {
        guard shown.indices.contains(index) else { return }
        onChoose?(shown[index], choice)
    }

    private func rebuild(preferred: Int?, preferredID: String? = nil) {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        var pinned: [BrowseItem] = []
        var recent: [BrowseItem] = []
        for item in items where query.isEmpty || item.title.localizedCaseInsensitiveContains(query) {
            if item.isPinned {
                if pinned.count < OverlayTheme.browseMaxRows { pinned.append(item) }
            } else if recent.count < OverlayTheme.browseMaxRows {
                recent.append(item)
            }
        }
        // Stable pinned-first order with bounded storage and at most browseMaxRows visible rows.
        shown = Array((pinned + recent).prefix(OverlayTheme.browseMaxRows))
        let pinnedCount = shown.prefix { $0.isPinned }.count, recentCount = shown.count - pinnedCount
        rows.forEach { $0.removeFromSuperview() }
        headers.forEach { $0.label.removeFromSuperview() }
        rows = shown.enumerated().map { index, item in
            let row = BrowseRowView(item: item)
            row.onClick = { [weak self] in self?.select(index); self?.choose(index, .write) }
            row.onHover = { [weak self] in self?.select(index, scrollIntoView: false) }
            document.addSubview(row)
            return row
        }
        headers = []
        for (title, start) in [("Pinned", 0), ("Recent", pinnedCount)] where (title == "Pinned" ? pinnedCount > 0 : recentCount > 0) {
            let text = label(title, font: OverlayTheme.browseHeaderFont, color: OverlayTheme.tertiaryColor)
            document.addSubview(text)
            headers.append((text, start))
        }
        message.stringValue = shown.isEmpty ? (items.isEmpty ? "No notes yet" : "No matching notes") : ""
        scroll.isHidden = shown.isEmpty
        message.isHidden = !shown.isEmpty
        if let preferredID, let index = shown.firstIndex(where: { $0.id == preferredID }) { selection = index }
        else if let preferred, shown.indices.contains(preferred) { selection = preferred }
        else { selection = shown.isEmpty ? nil : 0 }
        for (index, row) in rows.enumerated() { row.isSelected = index == selection }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let selection, selection > 0 { document.scrollToVisible(rows[selection].frame) }
        else { scroll.contentView.scroll(to: .zero) }
    }

    private func select(_ index: Int, scrollIntoView: Bool = true) {
        guard rows.indices.contains(index) else { return }
        selection = index
        for (i, row) in rows.enumerated() { row.isSelected = i == index }
        if scrollIntoView { document.scrollToVisible(rows[index].frame) }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let measured = metrics
        let areaHeight = max(0, bounds.height - contentTop - footerHeight)
        scroll.frame = NSRect(x: 0, y: contentTop, width: width, height: areaHeight)
        footerSeparator.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: width, height: OverlayTheme.borderWidth)
        footer.frame = NSRect(x: 0, y: bounds.height - OverlayTheme.browseFooterHeight, width: width, height: OverlayTheme.browseFooterHeight)
        var hintX = OverlayTheme.browseFooterInset
        for hint in footerHints {
            hint.frame = NSRect(x: hintX, y: (footer.bounds.height - OverlayTheme.hintHeight) / 2,
                                width: hint.desiredWidth, height: OverlayTheme.hintHeight)
            hintX = hint.frame.maxX + OverlayTheme.footerHintGap
        }
        let messageHeight = labelFittingSize(of: message).height
        message.frame = NSRect(x: 0, y: contentTop + (areaHeight - messageHeight) / 2, width: width, height: messageHeight)
        let inset = OverlayTheme.menuRowInset
        let docWidth = scroll.contentSize.width
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: inset, y: measured.rowY[index], width: docWidth - inset * 2, height: OverlayTheme.browseRowHeight)
        }
        for (index, header) in headers.enumerated() {
            let size = labelFittingSize(of: header.label)
            header.label.frame = NSRect(x: OverlayTheme.menuContentInset, y: measured.headerY[index] + (OverlayTheme.browseHeaderHeight - size.height) / 2,
                                        width: max(0, docWidth - OverlayTheme.menuContentInset * 2), height: size.height)
        }
        document.frame = NSRect(x: 0, y: 0, width: docWidth, height: max(measured.document, measured.visible))
    }
}
