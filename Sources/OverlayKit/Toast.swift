import AppKit

public struct Toast: Sendable {
    public struct Action: Sendable {
        public var title: String
        public var handler: @MainActor @Sendable () -> Void
        public init(title: String, handler: @escaping @MainActor @Sendable () -> Void) { self.title = title; self.handler = handler }
    }
    public enum Style: Sendable, CaseIterable { case success, warning, session, copied }
    public struct Hint: Sendable {
        public var key: String
        public var label: String
        public init(key: String, label: String = "") { self.key = key; self.label = label }
    }
    public var style: Style
    public var title: String
    public var subtitle: String?
    public var hint: Hint?
    public var duration: TimeInterval
    public var action: Action?
    public init(style: Style, title: String, subtitle: String? = nil, hint: Hint? = nil, duration: TimeInterval? = nil, action: Action? = nil) {
        self.style = style; self.title = title; self.subtitle = subtitle; self.hint = hint
        self.duration = duration ?? (style == .warning ? OverlayTheme.warningToastDuration : OverlayTheme.defaultToastDuration)
        self.action = action
    }
}

@MainActor
final class ToastView: OverlaySurface {
    private let icon: NSImageView
    private let title: NSTextField
    private let subtitle: NSTextField
    private let hint: KeycapView?
    private let actionButton: NSButton?
    var onAction: (() -> Void)?
    var onPointerEnter: (() -> Void)?
    var onPointerExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    init(_ toast: Toast) {
        let name: String
        let color: NSColor
        switch toast.style {
        case .success: name = OverlayTheme.successSymbol; color = OverlayTheme.successColor
        case .warning: name = OverlayTheme.warningSymbol; color = OverlayTheme.warningColor
        case .session: name = OverlayTheme.sessionSymbol; color = OverlayTheme.sessionColor
        case .copied: name = OverlayTheme.copiedSymbol; color = OverlayTheme.copiedColor
        }
        icon = symbol(name, color: color)
        title = label(toast.title, font: OverlayTheme.toastTitleFont, color: OverlayTheme.textColor)
        subtitle = label(toast.subtitle ?? "", font: OverlayTheme.toastSubtitleFont, color: OverlayTheme.secondaryColor)
        hint = toast.hint.map { KeycapView(key: $0.key, caption: $0.label) }
        if let action = toast.action {
            let button = NSButton(title: action.title, target: nil, action: nil)
            button.isBordered = false
            button.font = OverlayTheme.hintFont
            button.contentTintColor = OverlayTheme.brandAccent
            button.sizeToFit()
            actionButton = button
        } else { actionButton = nil }
        let textWidth = max(labelFittingSize(of: title).width, labelFittingSize(of: subtitle).width)
        let hintWidth = hint.map { $0.desiredWidth + OverlayTheme.iconGap } ?? 0
        let actionWidth = actionButton.map { $0.frame.width + OverlayTheme.iconGap } ?? 0
        let width = min(OverlayTheme.toastMaxWidth, max(OverlayTheme.toastMinWidth,
            OverlayTheme.padding * 2 + OverlayTheme.iconSize + OverlayTheme.iconGap + textWidth + hintWidth + actionWidth))
        super.init(size: NSSize(width: width, height: OverlayTheme.toastHeight), radius: OverlayTheme.toastRadius)
        addSubview(icon); addSubview(title); addSubview(subtitle)
        if let hint { addSubview(hint) }
        if let actionButton { addSubview(actionButton) }
        actionButton?.target = self
        actionButton?.action = #selector(actionClicked)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([toast.title, toast.subtitle].compactMap { $0 }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard actionButton != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { onPointerEnter?() }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }
    @objc private func actionClicked() { onAction?() }
    override func layout() {
        super.layout()
        let p = OverlayTheme.padding
        icon.frame = NSRect(x: p, y: (bounds.height - OverlayTheme.iconSize) / 2,
                            width: OverlayTheme.iconSize, height: OverlayTheme.iconSize)
        let hintWidth = hint?.desiredWidth ?? 0
        let actionWidth = actionButton?.frame.width ?? 0
        actionButton?.frame.origin = NSPoint(x: bounds.width - p - actionWidth, y: (bounds.height - (actionButton?.frame.height ?? 0)) / 2)
        hint?.frame = NSRect(x: bounds.width - p - actionWidth - (actionWidth > 0 ? OverlayTheme.iconGap : 0) - hintWidth, y: p, width: hintWidth, height: bounds.height - p * 2)
        let x = p + OverlayTheme.iconSize + OverlayTheme.iconGap
        let width = max(0, bounds.width - p - x - (hint == nil ? 0 : hintWidth + OverlayTheme.iconGap) - (actionWidth + (actionWidth > 0 ? OverlayTheme.iconGap : 0)))
        let subtitleHeight = subtitle.stringValue.isEmpty ? 0 : OverlayTheme.metaLineHeight + OverlayTheme.toastLineGap
        let y = (bounds.height - OverlayTheme.titleLineHeight - subtitleHeight) / 2
        title.frame = NSRect(x: x, y: y, width: width, height: OverlayTheme.titleLineHeight)
        subtitle.frame = NSRect(x: x, y: y + OverlayTheme.titleLineHeight + OverlayTheme.toastLineGap,
                                width: width, height: subtitleHeight == 0 ? 0 : OverlayTheme.metaLineHeight)
    }
}

@MainActor
public final class ToastController {
    private var panel: OverlayPanel?
    private var expiryTask: Task<Void, Never>?
    private var generation = 0
    public private(set) var isVisible = false
    public var onExpire: (() -> Void)?
    public init() {}

    public func show(_ toast: Toast) {
        // Replacing a toast neither stacks nor commits the superseded pending work.
        dismiss(expire: false, animated: false)
        generation += 1
        let token = generation
        let view = ToastView(toast)
        let panel = OverlayPanel(interactive: false, size: view.frame.size)
        panel.ignoresMouseEvents = toast.action == nil
        self.panel = panel
        isVisible = true
        panel.onClose = { [weak self] in
            guard let self, self.generation == token else { return }
            self.panel = nil
            self.isVisible = false
            self.expiryTask?.cancel()
            self.expiryTask = nil
        }
        view.onAction = { [weak self] in
            guard let self, self.generation == token else { return }
            self.dismiss(expire: false)
            toast.action?.handler()
        }
        view.onPointerEnter = { [weak self] in
            guard let self, self.generation == token else { return }
            self.expiryTask?.cancel()
            self.expiryTask = nil
        }
        view.onPointerExit = { [weak self, weak panel] in
            guard let self, let panel, self.generation == token else { return }
            self.startExpiry(duration: toast.duration, token: token, panel: panel)
        }
        panel.present(content: view)
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: toast.title, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        startExpiry(duration: toast.duration, token: token, panel: panel)
    }
    private func startExpiry(duration: TimeInterval, token: Int, panel: OverlayPanel) {
        expiryTask?.cancel()
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, duration)))
            guard !Task.isCancelled else { return }
            // A freed controller can't dismiss its toast, so the expired panel closes itself.
            guard let self else { panel.dismiss(); return }
            guard self.generation == token else { return }
            self.dismiss(expire: true)
        }
    }
    public func dismiss(expire: Bool) { dismiss(expire: expire, animated: true) }
    private func dismiss(expire: Bool, animated: Bool) {
        guard let panel else { return }
        let wasVisible = isVisible
        isVisible = false
        expiryTask?.cancel(); expiryTask = nil
        panel.dismiss(animated: animated)
        if expire && wasVisible { onExpire?() }
    }
}
