import AppKit

/// Match ranges are UTF-16 NSRanges, as used by NSAttributedString.
public struct SearchRow: Sendable {
    public enum Kind: Sendable { case text, image, note }
    public var id: String
    public var title: String
    public var titleMatches: [NSRange]
    public var snippet: String
    public var snippetMatches: [NSRange]
    public var meta: String
    public var kind: Kind
    public var thumbnailLoader: (@MainActor () async -> NSImage?)?
    public init(id: String, title: String, titleMatches: [NSRange] = [], snippet: String = "",
                snippetMatches: [NSRange] = [], meta: String = "", kind: Kind = .text,
                thumbnailLoader: (@MainActor () async -> NSImage?)? = nil) {
        self.id = id; self.title = title; self.titleMatches = titleMatches; self.snippet = snippet
        self.snippetMatches = snippetMatches; self.meta = meta; self.kind = kind; self.thumbnailLoader = thumbnailLoader
    }
}

public struct SearchSection: Sendable {
    public var title: String
    public var rows: [SearchRow]
    public var errorMessage: String?
    public init(title: String, rows: [SearchRow], errorMessage: String? = nil) {
        self.title = title; self.rows = rows; self.errorMessage = errorMessage
    }
}

@MainActor
public struct SearchActions {
    public enum Action { case primary, open, reveal }
    /// Resolve the selected model synchronously, before dismissal invalidates results.
    public var freeze: ((SearchRow, Action) -> (() -> Void)?)?
    public var primary: (SearchRow) -> Void
    public var open: (SearchRow) -> Void
    public var reveal: (SearchRow) -> Void
    public var onClose: () -> Void
    public init(primary: @escaping (SearchRow) -> Void, open: @escaping (SearchRow) -> Void,
                reveal: @escaping (SearchRow) -> Void, onClose: @escaping () -> Void = {},
                freeze: ((SearchRow, Action) -> (() -> Void)?)? = nil) {
        self.primary = primary; self.open = open; self.reveal = reveal; self.onClose = onClose
        self.freeze = freeze
    }
}

@MainActor
final class SearchPanelView: OverlaySurface {
    let field = OverlayTextField(placeholder: "Search notes")
    private let searchIcon = symbol(OverlayTheme.searchSymbol, color: OverlayTheme.secondaryColor)
    private let spinner = NSProgressIndicator()
    private let separator = SeparatorView()
    private let footerSeparator = SeparatorView()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let message = label("", font: OverlayTheme.messageFont, color: OverlayTheme.secondaryColor)
    private let footer = FlippedView()
    private let hints: [KeycapView] = [
        KeycapView(key: "↵", caption: "Copy", color: OverlayTheme.tertiaryColor),
        KeycapView(key: "⌘↵", caption: "Open", color: OverlayTheme.tertiaryColor),
        KeycapView(key: "⌥↵", caption: "Show in Finder", color: OverlayTheme.tertiaryColor),
        KeycapView(key: "esc", caption: "Close", color: OverlayTheme.tertiaryColor)
    ]
    private var entries: [(view: NSView, height: CGFloat)] = []
    private var rowViews: [ChoiceRowView] = []
    private var rowModels: [SearchRow] = []
    private var thumbnailTasks: [Task<Void, Never>] = []
    private var thumbnails: [Int: NSImage] = [:]
    private var renderedSections: [SearchSection] = []
    private var errorMessage: String?
    private var renderGeneration = 0
    private var selection: Int?
    private var listHeight: CGFloat = 0
    var onSelect: ((Int) -> Void)?
    var onPrimary: ((Int) -> Void)?
    var desiredSize: NSSize {
        NSSize(width: OverlayTheme.searchWidth, height: OverlayTheme.padding * 2 + OverlayTheme.searchFieldHeight
               + OverlayTheme.borderWidth * 2 + listHeight + OverlayTheme.footerHeight)
    }
    init(query: String = "") {
        super.init(size: NSSize(width: OverlayTheme.searchWidth, height: OverlayTheme.searchFieldHeight + OverlayTheme.padding * 2))
        field.stringValue = query
        spinner.style = .spinning
        spinner.controlSize = OverlayTheme.spinnerControlSize
        spinner.isDisplayedWhenStopped = false
        spinner.isIndeterminate = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        message.alignment = .center
        [field, searchIcon, spinner, separator, scroll, message, footerSeparator, footer].forEach { addSubview($0) }
        hints.forEach { footer.addSubview($0) }
        update(sections: [], selection: nil, query: query)
        setFrameSize(desiredSize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    func stopLoading() {
        setLoading(false)
        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks = []
        thumbnails = [:]
        renderedSections = []
        rowModels = []
    }
    func update(sections: [SearchSection], selection: Int?, query: String) {
        thumbnailTasks.forEach { $0.cancel() }; thumbnailTasks = []
        thumbnails = [:]
        renderGeneration += 1
        renderedSections = sections.filter { !$0.rows.isEmpty }
        errorMessage = sections.compactMap(\.errorMessage).first
        rowModels = renderedSections.flatMap(\.rows)
        self.selection = selection
        rebuildRows(query: query)
        let token = renderGeneration
        for (index, row) in rowModels.enumerated() where row.kind == .image {
            guard let loader = row.thumbnailLoader else { continue }
            // Capture the provider, never the view, across suspension.
            thumbnailTasks.append(Task { @MainActor [weak self] in
                let image = await loader()
                guard !Task.isCancelled, let self, self.renderGeneration == token, self.rowViews.indices.contains(index) else { return }
                if let image { self.thumbnails[index] = image }
                self.rowViews[index].icon.image = image
            })
        }
    }
    func waitForThumbnails() async {
        for task in thumbnailTasks { await task.value }
    }
    func select(_ selection: Int?, query: String) {
        self.selection = selection
        rebuildRows(query: query)
    }
    private func rebuildRows(query: String) {
        entries.forEach { $0.view.removeFromSuperview() }
        entries = []; rowViews = []
        var index = 0
        for section in renderedSections {
            let header = label("", font: OverlayTheme.headerFont, color: OverlayTheme.secondaryColor)
            header.attributedStringValue = NSAttributedString(string: section.title.uppercased(), attributes: [
                .font: OverlayTheme.headerFont, .foregroundColor: OverlayTheme.secondaryColor, .kern: OverlayTheme.headerTracking
            ])
            document.addSubview(header)
            entries.append((header, OverlayTheme.headerHeight))
            for model in section.rows {
                let rowIndex = index
                let selected = selection == rowIndex
                let title = attributed(model.title, font: OverlayTheme.titleFont,
                                       color: selected ? OverlayTheme.selectedText : OverlayTheme.textColor,
                                       matches: model.titleMatches, matchFont: OverlayTheme.titleFont)
                let snippet = attributed(model.snippet, font: OverlayTheme.snippetFont,
                                         color: selected ? OverlayTheme.selectedSecondary : OverlayTheme.secondaryColor,
                                         matches: model.snippetMatches, matchFont: OverlayTheme.matchedSnippetFont,
                                         matchColor: selected ? OverlayTheme.selectedSecondary : OverlayTheme.textColor)
                let row = ChoiceRowView(title: title, secondary: snippet, meta: model.meta,
                                        iconName: model.kind == .image ? nil : (model.kind == .note ? OverlayTheme.noteSymbol : OverlayTheme.textSymbol),
                                        selected: selected, kind: model.kind == .image ? .image : .note)
                row.icon.image = model.kind == .image ? thumbnails[rowIndex] : row.icon.image
                row.onClick = { [weak self] in
                    self?.onSelect?(rowIndex)
                    // Single clicks select; double clicks perform the primary action.
                    if NSApp.currentEvent?.clickCount == 2 { self?.onPrimary?(rowIndex) }
                }
                document.addSubview(row)
                entries.append((row, OverlayTheme.resultHeight))
                rowViews.append(row)
                index += 1
            }
        }
        if rowModels.isEmpty { listHeight = OverlayTheme.noResultsHeight }
        else {
            // Count rows across sections; include headers only for visible sections.
            var remaining = OverlayTheme.maxResults
            listHeight = 0
            for section in renderedSections where remaining > 0 {
                listHeight += OverlayTheme.headerHeight + CGFloat(min(remaining, section.rows.count)) * OverlayTheme.resultHeight
                remaining -= min(remaining, section.rows.count)
            }
        }
        message.stringValue = errorMessage ?? "No matches for “\(query)”"
        message.isHidden = !rowModels.isEmpty
        scroll.isHidden = rowModels.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let selection, rowViews.indices.contains(selection) { document.scrollToVisible(rowViews[selection].frame) }
    }
    override func layout() {
        super.layout()
        let p = OverlayTheme.padding
        let center = p + OverlayTheme.searchFieldHeight / 2
        searchIcon.frame = NSRect(x: p, y: center - OverlayTheme.iconSize / 2,
                                  width: OverlayTheme.iconSize, height: OverlayTheme.iconSize)
        let fieldX = p + OverlayTheme.iconSize + OverlayTheme.iconGap
        field.frame = NSRect(x: fieldX, y: center - field.intrinsicContentSize.height / 2,
                             width: bounds.width - fieldX - p - OverlayTheme.spinnerSize - OverlayTheme.iconGap,
                             height: field.intrinsicContentSize.height)
        spinner.frame = NSRect(x: bounds.width - p - OverlayTheme.spinnerSize, y: center - OverlayTheme.spinnerSize / 2,
                               width: OverlayTheme.spinnerSize, height: OverlayTheme.spinnerSize)
        let y = p + OverlayTheme.searchFieldHeight
        separator.frame = NSRect(x: p, y: y, width: bounds.width - p * 2, height: OverlayTheme.borderWidth)
        let listY = y + OverlayTheme.borderWidth
        let visibleHeight = max(0, bounds.height - listY - p - OverlayTheme.footerHeight - OverlayTheme.borderWidth)
        scroll.frame = NSRect(x: p, y: listY, width: bounds.width - p * 2, height: visibleHeight)
        message.frame = NSRect(x: p, y: listY + (visibleHeight - OverlayTheme.titleLineHeight) / 2,
                               width: bounds.width - p * 2, height: OverlayTheme.titleLineHeight)
        let documentHeight = entries.reduce(CGFloat.zero) { $0 + $1.height }
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: documentHeight)
        var offset: CGFloat = 0
        for entry in entries {
            let isHeader = entry.view is NSTextField
            entry.view.frame = NSRect(x: isHeader ? OverlayTheme.rowInset : 0,
                                      y: offset + (isHeader ? (OverlayTheme.headerHeight - OverlayTheme.metaLineHeight) / 2 : 0),
                                      width: document.bounds.width - (isHeader ? OverlayTheme.rowInset * 2 : 0),
                                      height: isHeader ? OverlayTheme.metaLineHeight : entry.height)
            offset += entry.height
        }
        footerSeparator.frame = NSRect(x: p, y: listY + visibleHeight,
                                       width: bounds.width - p * 2, height: OverlayTheme.borderWidth)
        footer.frame = NSRect(x: p, y: footerSeparator.frame.maxY, width: bounds.width - p * 2, height: OverlayTheme.footerHeight)
        var x: CGFloat = 0
        for hint in hints {
            hint.frame = NSRect(x: x, y: 0, width: hint.desiredWidth, height: OverlayTheme.footerHeight)
            x += hint.desiredWidth + OverlayTheme.footerHintGap
        }
    }
}

@MainActor
public final class SearchPanelController: NSObject, NSTextFieldDelegate {
    private var panel: OverlayPanel?
    private var content: SearchPanelView?
    private var provider: (@MainActor (String) async -> [SearchSection])?
    private var actions: SearchActions?
    private var pendingAction: (() -> Void)?
    private var queryTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private var generation = 0
    private var rows: [SearchRow] = []
    private var selection: Int?
    public var isVisible: Bool { panel?.isVisible == true }
    public override init() { super.init() }

    public func present(query: @escaping @MainActor (String) async -> [SearchSection], actions: SearchActions) {
        panel?.dismiss(animated: false)
        provider = query; self.actions = actions
        rows = []; selection = nil
        let view = SearchPanelView()
        content = view
        view.field.delegate = self
        view.onSelect = { [weak self] index in self?.select(index) }
        view.onPrimary = { [weak self] index in self?.perform(index: index, modifiers: []) }
        let panel = OverlayPanel(interactive: true, size: view.desiredSize)
        self.panel = panel
        panel.onDismiss = { [weak self] in self?.cancelQueries() }
        panel.onClose = { [weak self] in self?.didClose() }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        panel.present(content: view)
        panel.makeFirstResponder(view.field)
        scheduleQuery(debounce: false)
    }
    public func dismiss() { panel?.dismiss() }
    private func cancelQueries() {
        generation += 1
        queryTask?.cancel(); queryTask = nil
        spinnerTask?.cancel(); spinnerTask = nil
    }
    public func controlTextDidChange(_ obj: Notification) { scheduleQuery(debounce: true) }
    private func scheduleQuery(debounce: Bool) {
        queryTask?.cancel(); spinnerTask?.cancel()
        generation += 1
        let token = generation
        guard let provider, let content else { return }
        let text = content.field.stringValue
        content.setLoading(false)
        // Start the loading clock when the provider starts, after the debounce.
        queryTask = Task { @MainActor [weak self] in
            if debounce {
                do { try await Task.sleep(for: OverlayTheme.queryDebounce) } catch { return }
            }
            guard !Task.isCancelled, self?.generation == token else { return }
            self?.startSpinner(token: token)
            // Do not hold the controller or its view hierarchy while awaiting a provider.
            let sections = await provider(text)
            guard !Task.isCancelled else { return }
            self?.applyResults(sections, text: text, token: token)
        }
    }
    private func startSpinner(token: Int) {
        spinnerTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: OverlayTheme.loadingDelay) } catch { return }
            guard let self, self.generation == token else { return }
            self.content?.setLoading(true)
        }
    }
    private func applyResults(_ sections: [SearchSection], text: String, token: Int) {
        guard !Task.isCancelled, generation == token, let content else { return }
        spinnerTask?.cancel(); spinnerTask = nil
        content.setLoading(false)
        rows = sections.flatMap(\.rows)
        selection = rows.isEmpty ? nil : 0
        content.update(sections: sections, selection: selection, query: text)
        panel?.resizeContent(to: content.desiredSize)
        queryTask = nil
    }
    private func select(_ index: Int) {
        guard rows.indices.contains(index), let content else { return }
        selection = index
        content.select(index, query: content.field.stringValue)
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let command = OverlayKeyCommand(event) else { return false }
        switch command {
        case .moveDown, .moveUp:
            guard !rows.isEmpty else { return true }
            select(min(rows.count - 1, max(0, (selection ?? 0) + (command == .moveDown ? 1 : -1))))
            return true
        case .submit:
            if let selection { perform(index: selection, modifiers: event.modifierFlags) }
            return true
        case .cancel, .complete, .toggleActions, .toggleBrowse:
            return false
        }
    }
    private func perform(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index), let actions else { return }
        let row = rows[index]
        let action: SearchActions.Action = modifiers.contains(.command) ? .open : (modifiers.contains(.option) ? .reveal : .primary)
        if let freeze = actions.freeze { pendingAction = freeze(row, action) }
        else {
            switch action {
            case .primary: pendingAction = { actions.primary(row) }
            case .open: pendingAction = { actions.open(row) }
            case .reveal: pendingAction = { actions.reveal(row) }
            }
        }
        dismiss()
    }
    private func didClose() {
        generation += 1
        queryTask?.cancel(); queryTask = nil
        spinnerTask?.cancel(); spinnerTask = nil
        content?.stopLoading()
        content?.field.delegate = nil
        let onClose = actions?.onClose
        let action = pendingAction
        pendingAction = nil
        panel = nil; content = nil; provider = nil; actions = nil; rows = []; selection = nil
        onClose?()
        action?()
    }
}
