import AppKit

/// A 26pt icon button that never takes focus, so the text view keeps the caret.
@MainActor
final class ChromeButton: FlippedView {
    var onClick: (() -> Void)?
    let symbolName: String
    private let icon: NSImageView
    private var hovering = false { didSet { updateAppearance() } }
    private var pressed = false { didSet { updateAppearance() } }
    var isOn = false {
        didSet {
            setAccessibilityValue(NSNumber(value: isOn))
            setAccessibilitySelected(isOn)
            updateAppearance()
        }
    }

    init(symbolName: String, tooltip: String, label: String) {
        self.symbolName = symbolName
        icon = symbol(symbolName, color: OverlayTheme.secondaryColor)
        super.init(frame: NSRect(x: 0, y: 0, width: OverlayTheme.quickButtonSize, height: OverlayTheme.quickButtonSize))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: OverlayTheme.quickSymbolSize, weight: .medium)
        icon.imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = OverlayTheme.quickButtonSize / 2
        toolTip = tooltip
        addSubview(icon)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityValue(NSNumber(value: false))
        setAccessibilitySelected(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func layout() { super.layout(); icon.frame = bounds; updateAppearance() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAppearance() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    private func updateAppearance() {
        icon.contentTintColor = hovering || pressed || isOn ? OverlayTheme.textColor : OverlayTheme.secondaryColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = pressed || isOn ? OverlayTheme.quickButtonPressedFill : hovering ? OverlayTheme.quickButtonHoverFill : nil
            // Resolve the system label colour here; the alpha-derived tokens can retain their initial appearance.
            layer?.backgroundColor = fill.map { NSColor.labelColor.withAlphaComponent($0.alphaComponent).cgColor }
        }
    }
}

/// The capsule behind the right-hand button trio.
@MainActor
private final class ChromeCluster: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = OverlayTheme.quickClusterRadius
        layer?.borderWidth = OverlayTheme.borderWidth
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() { super.layout(); updateAppearance() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = OverlayTheme.quickClusterFill.cgColor
            layer?.borderColor = OverlayTheme.quickClusterBorder.cgColor
        }
    }
}

/// Five icon buttons in the editor's top band: two plain on the left, three inside one capsule on the right.
/// Transparent to the mouse outside the buttons.
@MainActor
final class NoteChromeBar: FlippedView {
    var onClose: (() -> Void)? { didSet { close.onClick = onClose } }
    var onOpenAsNote: (() -> Void)? { didSet { open.onClick = onOpenAsNote } }
    var onActions: (() -> Void)? { didSet { actions.onClick = onActions } }
    var onBrowse: (() -> Void)? { didSet { browse.onClick = onBrowse } }
    var onNew: (() -> Void)? { didSet { new.onClick = onNew } }
    var isActionsOpen = false { didSet { actions.isOn = isActionsOpen } }
    var isBrowseOpen = false { didSet { browse.isOn = isBrowseOpen } }
    private let close = ChromeButton(symbolName: "xmark", tooltip: "Close (esc)", label: "Close")
    private let open = ChromeButton(symbolName: "arrow.up.left.and.arrow.down.right", tooltip: "Open as note (⌘O)", label: "Open as note")
    /// `rectangle.on.rectangle.angled` is newer than the deployment target; fall back where it is missing.
    static let browseSymbolName = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: nil) == nil
        ? "square.on.square" : "rectangle.on.rectangle.angled"
    private let cluster = ChromeCluster(frame: .zero)
    private let actions = ChromeButton(symbolName: "ellipsis", tooltip: "Actions (⌘K)", label: "Actions")
    private let browse = ChromeButton(symbolName: NoteChromeBar.browseSymbolName, tooltip: "Browse notes (⌘P)", label: "Browse notes")
    private let new = ChromeButton(symbolName: "plus", tooltip: "New note (⌘N)", label: "New note")
    /// False while the bar is faded out, so invisible buttons cannot be clicked.
    var isActive = false
    private var buttons: [ChromeButton] { [close, open, browse, new, actions] }

    init() {
        super.init(frame: .zero)
        addSubview(cluster)
        buttons.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard isActive else { return nil }
        return buttons.first { $0.frame.contains(local) }
    }
    private static var leftWidth: CGFloat { OverlayTheme.quickButtonSize * 2 + OverlayTheme.quickButtonGap }
    private static var clusterWidth: CGFloat { OverlayTheme.quickButtonSize * 3 + OverlayTheme.quickClusterPadding * 2 }
    /// Distance from a band edge to the inner side of the widest button group; the title must stay clear of it.
    static var widestExtent: CGFloat { OverlayTheme.quickChromeEdgeInset + max(leftWidth, clusterWidth) }
    override func layout() {
        super.layout()
        let size = OverlayTheme.quickButtonSize, gap = OverlayTheme.quickButtonGap, edge = OverlayTheme.quickChromeEdgeInset
        let y = (bounds.height - size) / 2
        var x = edge
        for button in [close, open] {
            button.frame = NSRect(x: x, y: y, width: size, height: size)
            x += size + gap
        }
        let padding = OverlayTheme.quickClusterPadding
        cluster.frame = NSRect(x: bounds.width - edge - Self.clusterWidth, y: (bounds.height - OverlayTheme.quickClusterHeight) / 2,
                               width: Self.clusterWidth, height: OverlayTheme.quickClusterHeight)
        x = cluster.frame.minX + padding
        for button in [browse, new, actions] {
            button.frame = NSRect(x: x, y: y, width: size, height: size)
            x += size
        }
    }
}

/// The editor shortcuts that map to note actions (⌘K is handled separately as a toggle).
func noteShortcutAction(for event: NSEvent) -> NoteActionID? {
    let flags = event.shortcutFlags
    guard flags.contains(.command) else { return nil }
    let shift = flags.contains(.shift)
    switch event.keyCode {
    case 8 where shift: return .copyMarkdown
    case 35: return shift ? .pin : .browse
    case 45 where flags == [.command, .shift]: return .writeOutsideSession
    case 45 where flags == .command: return .newNote
    case 31: return .openAsNote
    case 51 where shift: return .discardDraft
    case 36 where flags.contains(.option), 76 where flags.contains(.option): return .saveAsNewNote // Return, keypad Enter
    default: return nil
    }
}

extension NSEvent {
    /// Modifiers that matter for shortcuts: Caps Lock, numeric pad and function flags are ignored.
    var shortcutFlags: NSEvent.ModifierFlags {
        modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }
}
