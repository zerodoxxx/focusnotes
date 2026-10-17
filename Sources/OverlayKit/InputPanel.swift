import AppKit

public struct Suggestion: Sendable {
    public var title: String
    public var secondary: String?
    public var symbolName: String?
    public var value: String?
    public init(title: String, secondary: String? = nil, symbolName: String? = nil, value: String? = nil) {
        self.title = title; self.secondary = secondary; self.symbolName = symbolName; self.value = value
    }
}

@MainActor
final class InputPanelView: OverlaySurface {
    let field: OverlayTextField
    private let titleLabel: NSTextField?
    private let secondaryLabel: NSTextField?
    private var contextHeight: CGFloat {
        (titleLabel == nil ? 0 : OverlayTheme.headerHeight) + (secondaryLabel == nil ? 0 : OverlayTheme.metaLineHeight + OverlayTheme.padding / 2)
    }
    private let separator = SeparatorView()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var rows: [ChoiceRowView] = []
    var onSelect: ((Int) -> Void)?
    var desiredSize: NSSize {
        NSSize(width: OverlayTheme.inputWidth,
               height: OverlayTheme.padding * 2 + contextHeight + OverlayTheme.inputFieldHeight
               + (rows.isEmpty ? 0 : OverlayTheme.borderWidth + CGFloat(min(rows.count, OverlayTheme.maxSuggestions)) * OverlayTheme.suggestionHeight))
    }
    init(placeholder: String, text: String, suggestions: [Suggestion], selection: Int?, title: String? = nil, secondary: String? = nil) {
        titleLabel = title.map { label($0, font: OverlayTheme.titleFont, color: OverlayTheme.textColor) }
        secondaryLabel = secondary.map { label($0, font: OverlayTheme.metaFont, color: OverlayTheme.secondaryColor) }
        field = OverlayTextField(placeholder: placeholder)
        field.stringValue = text
        super.init(size: NSSize(width: OverlayTheme.inputWidth, height: OverlayTheme.inputFieldHeight + OverlayTheme.padding * 2))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        if let titleLabel { addSubview(titleLabel) }
        if let secondaryLabel { addSubview(secondaryLabel) }
        field.setAccessibilityLabel(title ?? placeholder)
        if let secondary { field.setAccessibilityHelp(secondary) }
        addSubview(field); addSubview(separator); addSubview(scroll)
        update(suggestions: suggestions, selection: selection)
        setFrameSize(desiredSize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func update(suggestions: [Suggestion], selection: Int?) {
        rows.forEach { $0.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, suggestion in
            let selected = selection == index
            let row = ChoiceRowView(
                title: attributed(suggestion.title, font: OverlayTheme.suggestionTitleFont,
                                  color: selected ? OverlayTheme.selectedText : OverlayTheme.textColor),
                secondary: attributed(suggestion.secondary ?? "", font: OverlayTheme.metaFont,
                                      color: selected ? OverlayTheme.selectedSecondary : OverlayTheme.tertiaryColor),
                meta: "", iconName: suggestion.symbolName, selected: selected, suggestion: true)
            row.onClick = { [weak self] in self?.onSelect?(index) }
            document.addSubview(row)
            return row
        }
        separator.isHidden = rows.isEmpty
        scroll.isHidden = rows.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let selection, rows.indices.contains(selection) { document.scrollToVisible(rows[selection].frame) }
    }
    override func layout() {
        super.layout()
        let p = OverlayTheme.padding
        let line = field.intrinsicContentSize.height
        titleLabel?.frame = NSRect(x: p, y: p, width: bounds.width - p * 2, height: OverlayTheme.titleLineHeight)
        secondaryLabel?.frame = NSRect(x: p, y: p + (titleLabel == nil ? 0 : OverlayTheme.headerHeight),
                                      width: bounds.width - p * 2, height: OverlayTheme.metaLineHeight)
        field.frame = NSRect(x: p, y: p + contextHeight + (OverlayTheme.inputFieldHeight - line) / 2,
                             width: bounds.width - p * 2, height: line)
        let y = p + contextHeight + OverlayTheme.inputFieldHeight
        separator.frame = NSRect(x: p, y: y, width: bounds.width - p * 2, height: OverlayTheme.borderWidth)
        scroll.frame = NSRect(x: p, y: y + OverlayTheme.borderWidth,
                              width: bounds.width - p * 2,
                              height: max(0, bounds.height - y - OverlayTheme.borderWidth - p))
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                                height: CGFloat(rows.count) * OverlayTheme.suggestionHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * OverlayTheme.suggestionHeight,
                               width: document.bounds.width, height: OverlayTheme.suggestionHeight)
        }
    }
}

@MainActor
public final class InputPanelController: NSObject, NSTextFieldDelegate {
    private var panel: OverlayPanel?
    private var content: InputPanelView?
    private var provider: ((String) -> [Suggestion])?
    private var submit: ((String) -> Void)?
    private var accept: ((String) -> Void)?
    private var cancel: (() -> Void)?
    private var selectionOnly = false
    private var suggestions: [Suggestion] = []
    private var selection: Int?
    private var submittedText: String?
    public var isVisible: Bool { panel?.isVisible == true }
    public override init() { super.init() }

    public func present(placeholder: String, initialText: String = "", title: String? = nil, secondary: String? = nil,
                        selectionOnly: Bool = false, suggestions: @escaping (String) -> [Suggestion],
                        onAccept: ((String) -> Void)? = nil,
                        onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        panel?.dismiss(animated: false)
        provider = suggestions; accept = onAccept; submit = onSubmit; cancel = onCancel
        self.selectionOnly = selectionOnly
        submittedText = nil; selection = nil
        self.suggestions = suggestions(initialText)
        let view = InputPanelView(placeholder: placeholder, text: initialText, suggestions: self.suggestions, selection: nil, title: title, secondary: secondary)
        content = view
        view.field.delegate = self
        view.onSelect = { [weak self] index in
            guard let self else { return }
            self.selection = index
            self.refresh()
        }
        let panel = OverlayPanel(interactive: true, size: view.desiredSize)
        self.panel = panel
        panel.onClose = { [weak self] in self?.didClose() }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        panel.present(content: view)
        panel.makeFirstResponder(view.field)
    }
    public func dismiss() { panel?.dismiss() }
    public func controlTextDidChange(_ obj: Notification) {
        guard let content else { return }
        selection = nil
        suggestions = provider?(content.field.stringValue) ?? []
        refresh()
    }
    private func refresh() {
        guard let content else { return }
        content.update(suggestions: suggestions, selection: selection)
        panel?.resizeContent(to: content.desiredSize)
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125, 126:
            guard !suggestions.isEmpty else { return true }
            let next = selection.map { $0 + (event.keyCode == 125 ? 1 : -1) }
                ?? (event.keyCode == 125 ? 0 : suggestions.count - 1)
            selection = min(suggestions.count - 1, max(0, next))
            refresh()
            return true
        case 48:
            guard !suggestions.isEmpty, let content else { return true }
            let title = suggestions[selection ?? 0].title
            content.field.stringValue = title
            content.field.currentEditor()?.string = title
            content.field.currentEditor()?.selectedRange = NSRange(location: (title as NSString).length, length: 0)
            selection = nil
            suggestions = provider?(title) ?? []
            refresh()
            return true
        case 36, 76:
            guard let content else { return true }
            if selectionOnly, selection == nil { return true }
            let text = selection.map { suggestions[$0].value ?? suggestions[$0].title }
                ?? content.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            submittedText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            if let submittedText { accept?(submittedText) }
            panel?.dismiss()
            return true
        default: return false
        }
    }
    private func didClose() {
        let text = submittedText
        let onSubmit = submit
        let onCancel = cancel
        content?.field.delegate = nil
        content = nil; panel = nil; provider = nil; accept = nil; submit = nil; cancel = nil; selectionOnly = false
        suggestions = []; selection = nil; submittedText = nil
        if let text { onSubmit?(text) } else { onCancel?() }
    }
}
