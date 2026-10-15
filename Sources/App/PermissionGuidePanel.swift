import AppKit
import CaptureKit

/// Floating helper that sits beside System Settings and lets the user drag the app icon into a privacy list.
/// Created and driven by `PermissionGuide`; it never activates the app, so System Settings keeps focus.
@MainActor
final class PermissionGuidePanel: NSPanel {
    static let contentWidth: CGFloat = 380
    static let baseHeight: CGFloat = 84
    static let relaunchHeight: CGFloat = 100

    var onClose: (() -> Void)?

    private let effectView = NSVisualEffectView()
    private let rootStack = NSStackView()
    private let textStack = NSStackView()
    private let iconContainer = NSView()
    private let dragIcon = AppDragIconView()
    private let successIcon = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let relaunchButton = NSButton()
    private let closeButton = HoverSymbolButton()

    private var permission: CapturePermission = .accessibility

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.baseHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        buildContent()
        configure(for: .accessibility)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Sets the copy and layout for one permission and leaves the success state.
    func configure(for permission: CapturePermission) {
        self.permission = permission
        let app = AppInfo.name
        let title: String
        let body: String
        switch permission {
        case .accessibility:
            title = "Allow \(app) to read your selection"
            body = "Drag the icon into the Accessibility list, then switch \(app) on. Already listed? Just switch it on."
        case .screenCapture:
            title = "Allow \(app) to capture screen areas"
            body = "Drag the icon into the Screen Recording list, then switch \(app) on. macOS may ask you to relaunch."
        }
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        bodyLabel.isHidden = false
        dragIcon.isHidden = false
        successIcon.isHidden = true
        relaunchButton.isHidden = permission != .screenCapture
        closeButton.isHidden = false
        setContentSize(NSSize(width: Self.contentWidth, height: permission == .screenCapture ? Self.relaunchHeight : Self.baseHeight))
    }

    /// Replaces the icon with a green check and the title with the confirmation text.
    func showSuccess() {
        titleLabel.stringValue = permission == .accessibility ? "Accessibility is on" : "Screen Recording is on"
        bodyLabel.isHidden = true
        relaunchButton.isHidden = true
        dragIcon.isHidden = true
        successIcon.isHidden = false
        setContentSize(NSSize(width: Self.contentWidth, height: Self.baseHeight))
    }

    // MARK: - Layout

    private func buildContent() {
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        contentView = effectView

        let app = AppInfo.name
        dragIcon.setAccessibilityLabel("\(app) app icon. Drag it into the list in System Settings.")
        dragIcon.translatesAutoresizingMaskIntoConstraints = false
        successIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 40, weight: .regular))
        successIcon.contentTintColor = .systemGreen
        successIcon.isHidden = true
        successIcon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(dragIcon)
        iconContainer.addSubview(successIcon)
        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 52),
            iconContainer.heightAnchor.constraint(equalToConstant: 52),
            dragIcon.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            dragIcon.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            dragIcon.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            dragIcon.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
            successIcon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            successIcon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 2

        relaunchButton.isBordered = false
        relaunchButton.attributedTitle = NSAttributedString(
            string: "Relaunch \(app)",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.controlAccentColor]
        )
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunchTapped)
        relaunchButton.isHidden = true

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setViews([titleLabel, bodyLabel, relaunchButton], in: .leading)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel("Close")
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = 12
        rootStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.setViews([iconContainer, textStack, closeButton], in: .leading)
        effectView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: effectView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
    }

    @objc private func closeTapped() {
        onClose?()
    }

    /// Starts a detached relaunch after a short delay, then quits. The shell survives this process exiting.
    @objc private func relaunchTapped() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}

/// Icon that can be dragged into a System Settings privacy list as a copy of the app bundle.
@MainActor
final class AppDragIconView: NSImageView, NSDraggingSource {
    private var hovered = false
    private var pressed = false
    private var mouseDownPoint: NSPoint?
    private var dragBegun = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        image = NSApp.applicationIconImage
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        setScale(1.06)
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        setScale(1)
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        (pressed ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        dragBegun = false
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        dragBegun = false
        mouseDownPoint = nil
        if hovered { NSCursor.openHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed, !dragBegun, let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        dragBegun = true
        pressed = false
        let writer = NSPasteboardItem()
        writer.setString(Bundle.main.bundleURL.absoluteString, forType: .fileURL)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: image ?? NSImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pressed = false
        (hovered ? NSCursor.openHand : NSCursor.arrow).set()
    }

    /// Hover scale with a 120 ms ease-out. Reduced motion keeps the icon at its natural size.
    private func setScale(_ scale: CGFloat) {
        guard let layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.transform = CATransform3DMakeScale(reduceMotion ? 1 : scale, reduceMotion ? 1 : scale, 1)
        CATransaction.commit()
    }
}

/// Borderless symbol button that tints to labelColor on hover.
@MainActor
private final class HoverSymbolButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }
}
