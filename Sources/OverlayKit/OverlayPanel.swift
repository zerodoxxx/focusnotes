import AppKit
import QuartzCore

/// A permanently nonactivating panel. AppKit's nonactivating key-focus mechanism
/// returns keyboard focus to the previous application/window when ordered out.
/// Never change its nonactivating style bit after initialization.
@MainActor
public final class OverlayPanel: NSPanel, NSWindowDelegate {
    private let interactive: Bool
    private let appearDuration: TimeInterval
    private let disappearDuration: TimeInterval
    /// Only the note editor lets the user drag it; it then remembers where it was left.
    private let userMovable: Bool
    /// Explicitly retained across focus and Space changes; only the quick-note editor opts in.
    public var isSticky = false
    var onResignKey: (() -> Void)?
    /// UserDefaults key for the remembered top-centre, as fractions of the screen's visible frame.
    static let positionKey = "NoteEditorPanel.topCenter"
    private var closing = false
    private var finished = false
    private var opacityTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var resizeTarget: NSRect?
    private var settingGeometry = false
    /// The visible note rect in screen coordinates, excluding the transparent card overflow.
    var noteFrame: NSRect {
        guard let editor = contentView as? NoteEditorView else { return frame }
        return NSRect(x: frame.minX, y: frame.minY + editor.windowOverflowHeight,
                      width: frame.width, height: frame.height - editor.windowOverflowHeight)
    }
    public var onClose: (() -> Void)?
    /// Interactive editors can retain their window if durable draft storage fails.
    public var shouldDismiss: (() -> Bool)?
    var onDismiss: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    /// A movable panel stays open when dragged to another screen and reports the new screen instead.
    var onScreenChange: ((NSRect) -> Void)?
    private var reportedVisibleFrame: NSRect?
    var visibleScreenFrame: NSRect? { reportedVisibleFrame ?? (screen ?? NSScreen.main)?.visibleFrame }

    public init(interactive: Bool, size: NSSize, movable: Bool = false) {
        self.interactive = interactive
        appearDuration = interactive ? OverlayTheme.panelAppear : OverlayTheme.toastAppear
        disappearDuration = interactive ? OverlayTheme.panelDisappear : OverlayTheme.toastDisappear
        self.userMovable = movable
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = OverlayTheme.windowBackground
        hasShadow = OverlayTheme.windowShadow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = movable
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        level = interactive ? .modalPanel : .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        ignoresMouseEvents = !interactive
        acceptsMouseMovedEvents = interactive
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        delegate = self
    }

    public override var canBecomeKey: Bool { interactive && !closing }
    public override var canBecomeMain: Bool { false }

    public func present(content: NSView) {
        guard !closing else { return }
        contentView = content
        setContentSize(content.frame.size)
        positionOnMouseScreen()
        content.layoutSubtreeIfNeeded()
        alphaValue = 0
        orderFrontRegardless()
        if interactive {
            // This steals only keyboard focus, without activating this application.
            makeKey()
            NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: userMovable ? #selector(screenChanged(_:)) : #selector(environmentChanged),
                name: NSWindow.didChangeScreenNotification, object: self)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged),
                name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        }
        let duration = appearDuration
        let target = frame
        let moveToast = !interactive && !OverlayTheme.reduceMotion
        if !OverlayTheme.reduceMotion, interactive, let layer = content.layer {
            let scale = OverlayTheme.panelScale
            let transform = CATransform3DConcat(
                CATransform3DMakeScale(scale, scale, 1),
                CATransform3DMakeTranslation(content.bounds.width * (0.5 - layer.anchorPoint.x) * (1 - scale),
                                            content.bounds.height * (0.5 - layer.anchorPoint.y) * (1 - scale), 0))
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: transform)
            animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animation.duration = duration
            animation.timingFunction = OverlayTheme.easeOut
            layer.add(animation, forKey: "appear")
        }
        if moveToast { setFrameOrigin(NSPoint(x: target.minX, y: target.minY - OverlayTheme.toastTravel)) }
        opacityTask = motion(duration: duration, curve: OverlayTheme.easeOut, step: { [weak self] progress in
            self?.alphaValue = progress
            if moveToast {
                self?.setFrameOrigin(NSPoint(x: target.minX, y: target.minY - OverlayTheme.toastTravel * (1 - progress)))
            }
        })
    }

    @discardableResult
    public func dismiss(animated: Bool = true) -> Bool {
        guard !finished else { return true }
        guard closing || shouldDismiss?() != false else { return false }
        if closing {
            if !animated { finishDismissal() }
            return true
        }
        closing = true
        onDismiss?()
        onDismiss = nil
        stopObserving()
        // Interactive panels relinquish keyboard focus before any close callback.
        // Only passive toasts retain their closing fade.
        guard animated, !interactive else { finishDismissal(); return true }
        opacityTask?.cancel()
        resizeTask?.cancel(); resizeTask = nil
        let duration = disappearDuration
        let initial = alphaValue
        opacityTask = motion(duration: duration, curve: OverlayTheme.easeIn, step: { [weak self] progress in
            self?.alphaValue = initial * (1 - progress)
        }, completion: { [weak self] in self?.finishDismissal() })
        return true
    }

    public override func close() { dismiss() }
    /// Lets content (e.g. an open overlay) consume Escape before the panel closes.
    var cancelHandler: (() -> Bool)?
    public override func cancelOperation(_ sender: Any?) { if cancelHandler?() != true { dismiss() } }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let text = firstResponder as? NSTextView, text.hasMarkedText() { return super.performKeyEquivalent(with: event) }
        if !closing, event.type == .keyDown, onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            guard !closing else { return }
            if let text = firstResponder as? NSTextView, text.hasMarkedText() { super.sendEvent(event); return }
            if onKey?(event) == true { return }
            if event.keyCode == OverlayKeyCode.escape { dismiss(); return }
        }
        if isSticky && [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), !isKeyWindow { makeKey() }
        super.sendEvent(event)
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .scrollWheel].contains(event.type),
           let editor = contentView as? NoteEditorView {
            editor.updatePointer(at: editor.convert(event.locationInWindow, from: nil), hover: event.type != .scrollWheel)
        }
    }
    public func windowDidResignKey(_ notification: Notification) {
        guard interactive else { return }
        if isSticky { if !closing { onResignKey?() } } else { dismiss() }
    }

    public func windowDidMove(_ notification: Notification) {
        if !settingGeometry { (contentView as? NoteEditorView)?.updateCardSpace() }
    }

    @objc private func environmentChanged(_ notification: Notification) {
        guard isSticky else { dismiss(); return }
        guard notification.name == NSApplication.didChangeScreenParametersNotification,
              let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        screenChanged(to: visible)
        if let editor = contentView as? NoteEditorView {
            resizeTask?.cancel(); resizeTask = nil
            applyNoteFrame(Self.clamped(NSRect(x: noteFrame.minX, y: noteFrame.maxY - editor.noteSize.height,
                                              width: editor.noteSize.width, height: editor.noteSize.height), in: visible), editor: editor)
        }
    }
    @objc private func screenChanged(_ notification: Notification) { if let screen { screenChanged(to: screen.visibleFrame) } }
    /// The same callback path accepts a visible frame directly for deterministic screen-change checks.
    func screenChanged(to visibleFrame: NSRect) {
        reportedVisibleFrame = visibleFrame
        onScreenChange?(visibleFrame)
    }
    private func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    private func finishDismissal() {
        guard !finished else { return }
        finished = true
        opacityTask?.cancel(); opacityTask = nil
        resizeTask?.cancel(); resizeTask = nil
        (contentView as? NoteEditorView)?.cancelPendingMeasure()
        contentView?.layer?.removeAllAnimations()
        // Ordering out a key nonactivating panel releases AppKit's borrowed focus.
        // Explicitly activating the previous app would alter its window ordering.
        makeFirstResponder(nil)
        orderOut(nil)
        contentView = nil
        onKey = nil
        onResignKey = nil
        cancelHandler = nil
        shouldDismiss = nil
        delegate = nil
        // Remove the one-shot window from AppKit bookkeeping after releasing focus.
        super.close()
        let callback = onClose
        onClose = nil
        callback?()
    }
    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        if userMovable, let stored = Self.storedTopCenter() {
            setFrame(Self.frame(topCenter: stored, size: frame.size, in: visible), display: false)
            return
        }
        let y = interactive
            ? visible.maxY - visible.height * OverlayTheme.panelTopFraction - frame.height
            : visible.minY + OverlayTheme.toastBottomOffset
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: y))
    }

    // MARK: Moving
    /// The top-centre of `frame` as fractions of `visible` (x from the left, y from the bottom).
    static func topCenter(of frame: NSRect, in visible: NSRect) -> CGPoint {
        CGPoint(x: (frame.midX - visible.minX) / max(1, visible.width), y: (frame.maxY - visible.minY) / max(1, visible.height))
    }
    /// A frame of `size` whose top-centre sits at the fractions of `visible`, shifted fully inside it.
    static func frame(topCenter: CGPoint, size: NSSize, in visible: NSRect) -> NSRect {
        let origin = NSPoint(x: visible.minX + visible.width * topCenter.x - size.width / 2,
                             y: visible.minY + visible.height * topCenter.y - size.height)
        return clamped(NSRect(origin: origin, size: size), in: visible)
    }
    /// Shifts `frame` the minimum needed to lie inside `visible`. A taller frame keeps its top edge, a wider one its left edge.
    static func clamped(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var result = frame
        result.origin.x = max(visible.minX, min(result.origin.x, visible.maxX - result.width))
        result.origin.y = min(max(result.origin.y, visible.minY), visible.maxY - result.height)
        return result
    }
    /// Today's resize rule (top edge fixed, grows about the centre), kept on screen by the smallest shift.
    static func resized(_ frame: NSRect, to size: NSSize, in visible: NSRect?) -> NSRect {
        var target = frame
        target.origin.y += target.height - size.height
        target.origin.x -= (size.width - target.width) / 2
        target.size = size
        return visible.map { clamped(target, in: $0) } ?? target
    }
    static func storedTopCenter() -> CGPoint? {
        guard let values = UserDefaults.standard.array(forKey: positionKey) as? [Double], values.count == 2,
              values.allSatisfy(\.isFinite) else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }
    /// Drags the window with the mouse (blocks until the button is released), then remembers where it ended up.
    func performMove(with event: NSEvent) {
        guard userMovable, !closing else { return }
        // A pending animated resize would fight the drag: finish it first.
        if resizeTask != nil, let target = resizeTarget { resizeTask?.cancel(); resizeTask = nil; setFrame(target, display: true) }
        performDrag(with: event)
        rememberPosition()
    }
    private func rememberPosition() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let point = Self.topCenter(of: noteFrame, in: visible)
        UserDefaults.standard.set([Double(point.x), Double(point.y)], forKey: Self.positionKey)
    }

    func resizeContent(to size: NSSize, animated: Bool = true) {
        guard !closing else { return }
        if let editor = contentView as? NoteEditorView {
            resizeEditor(editor, animated: animated)
            return
        }
        resizeTask?.cancel()
        let initial = frame
        let target = Self.resized(initial, to: size, in: userMovable ? (screen ?? NSScreen.main)?.visibleFrame : nil)
        resizeTarget = target
        if !animated || OverlayTheme.reduceMotion { resizeTask = nil; setFrame(target, display: true); return }
        resizeTask = motion(duration: OverlayTheme.resizeDuration, curve: OverlayTheme.easeOut, step: { [weak self] progress in
            self?.setFrame(NSRect(x: initial.minX + (target.minX - initial.minX) * progress,
                                  y: initial.minY + (target.minY - initial.minY) * progress,
                                  width: initial.width + (target.width - initial.width) * progress,
                                  height: initial.height + (target.height - initial.height) * progress), display: true)
        }, completion: { [weak self] in self?.resizeTask = nil })
    }

    /// Cards change just the window extent. They must not finish/cancel an in-flight note resize.
    private func resizeEditor(_ editor: NoteEditorView, animated: Bool) {
        if !animated { applyNoteFrame(noteFrame, editor: editor); return }
        resizeTask?.cancel()
        let initial = noteFrame
        let target = Self.resized(initial, to: editor.noteSize, in: visibleScreenFrame)
        resizeTarget = target
        if OverlayTheme.reduceMotion { resizeTask = nil; applyNoteFrame(target, editor: editor); return }
        resizeTask = motion(duration: OverlayTheme.resizeDuration, curve: OverlayTheme.easeOut, step: { [weak self, weak editor] progress in
            guard let self, let editor else { return }
            self.applyNoteFrame(NSRect(x: initial.minX + (target.minX - initial.minX) * progress,
                                       y: initial.minY + (target.minY - initial.minY) * progress,
                                       width: initial.width + (target.width - initial.width) * progress,
                                       height: initial.height + (target.height - initial.height) * progress), editor: editor)
        }, completion: { [weak self] in self?.resizeTask = nil })
    }

    private func applyNoteFrame(_ note: NSRect, editor: NoteEditorView) {
        settingGeometry = true
        if let visible = visibleScreenFrame {
            editor.limitCardHeight(noteTop: note.maxY, visibleBottom: visible.minY)
        }
        let overflow = max(0, editor.windowSize(for: note.size).height - note.height)
        editor.windowOverflowHeight = overflow
        editor.needsLayout = true
        setFrame(NSRect(x: note.minX, y: note.minY - overflow, width: note.width, height: note.height + overflow), display: true)
        editor.layoutSubtreeIfNeeded()
        invalidateShadow()
        settingGeometry = false
    }

}

// Frame and opacity animation use weak ownership. AppKit's animator proxy can
// retain an empty, closed window until a paused display animation resumes.
@MainActor
private func motion(duration: TimeInterval, curve: CAMediaTimingFunction,
                    step: @escaping @MainActor (CGFloat) -> Void,
                    completion: @escaping @MainActor () -> Void = {}) -> Task<Void, Never> {
    Task { @MainActor in
        let start = CACurrentMediaTime()
        while !Task.isCancelled {
            let progress = min(1, (CACurrentMediaTime() - start) / duration)
            step(CGFloat(eased(progress, curve: curve)))
            if progress >= 1 { completion(); return }
            do { try await Task.sleep(for: OverlayTheme.motionFrameInterval) } catch { return }
        }
    }
}

private func eased(_ progress: Double, curve: CAMediaTimingFunction) -> Double {
    var first: [Float] = [0, 0]
    var second: [Float] = [0, 0]
    first.withUnsafeMutableBufferPointer { curve.getControlPoint(at: 1, values: $0.baseAddress!) }
    second.withUnsafeMutableBufferPointer { curve.getControlPoint(at: 2, values: $0.baseAddress!) }
    func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
        3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
    }
    if progress <= 0 { return 0 }
    if progress >= 1 { return 1 }
    var lower = 0.0
    var upper = 1.0
    for _ in 0..<16 {
        let t = (lower + upper) / 2
        if cubic(t, Double(first[0]), Double(second[0])) < progress { lower = t } else { upper = t }
    }
    return cubic((lower + upper) / 2, Double(first[1]), Double(second[1]))
}
