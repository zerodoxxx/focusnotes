import AppKit
import CaptureKit
import CoreGraphics

/// Shows the permission helper panel beside System Settings and tracks the grant until it succeeds or is dismissed.
@MainActor
final class PermissionGuide {
    private enum Phase {
        case idle
        case waiting
        case succeeded
    }

    /// Called after the success state has faded out.
    var onGranted: ((CapturePermission) -> Void)?
    var onRelaunch: (() -> Void)?

    private static let timeout: TimeInterval = 10 * 60
    private static let screenInset: CGFloat = 8

    private var panel: PermissionGuidePanel?
    private var permission: CapturePermission?
    private var phase: Phase = .idle
    private var openedAt = Date()
    private var absentSince = Date()
    private var settingsSeen = false
    private var pollTimer: Timer?
    private var positionTimer: Timer?
    private var successTask: Task<Void, Never>?

    /// Requests access where needed, opens the matching Settings pane and docks the helper to it.
    func show(for permission: CapturePermission) {
        guard !PermissionGuide.isGranted(permission) else { return }
        // Screen Recording registers the app in the list first. The system dialog appears only the first time.
        if permission == .screenCapture {
            CapturePermissions.requestScreenCapture()
        }
        // Accessibility never uses the prompting AX API: the panel is the only UI.
        CapturePermissions.openSettings(for: permission)

        let panel = panel ?? makePanel()
        cancelSuccess()
        self.permission = permission
        phase = .waiting
        openedAt = Date()
        absentSince = openedAt
        settingsSeen = false
        panel.configure(for: permission)
        panel.alphaValue = PermissionGuide.reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        reposition()
        animateAlpha(to: 1)
        startTimers()
    }

    /// Hides the panel and stops all timers. Safe to call when nothing is shown.
    func dismiss() {
        stopTimers()
        cancelSuccess()
        permission = nil
        phase = .idle
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func makePanel() -> PermissionGuidePanel {
        let panel = PermissionGuidePanel()
        panel.onClose = { [weak self] in self?.dismiss() }
        panel.onRelaunch = { [weak self] in self?.onRelaunch?() }
        self.panel = panel
        return panel
    }

    private func reposition() {
        guard let panel, panel.isVisible else { return }
        let target = PermissionGuide.targetOrigin(for: panel.frame.size, settings: PermissionGuide.settingsWindowFrame())
        let current = panel.frame.origin
        guard abs(target.x - current.x) >= 1 || abs(target.y - current.y) >= 1 else { return }
        panel.setFrameOrigin(target)
    }

    private func animateAlpha(to value: CGFloat) {
        guard let panel else { return }
        guard !PermissionGuide.reduceMotion else {
            panel.alphaValue = value
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = value
        }
    }

    // MARK: - Timers and state

    private func startTimers() {
        if pollTimer == nil {
            pollTimer = makeTimer(interval: 1.0) { [weak self] in self?.pollTick() }
        }
        if positionTimer == nil {
            positionTimer = makeTimer(interval: 0.1) { [weak self] in self?.reposition() }
        }
    }

    private func stopTimers() {
        pollTimer?.invalidate()
        pollTimer = nil
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func makeTimer(interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func pollTick() {
        guard phase == .waiting, let permission else { return }
        let now = Date()
        if PermissionGuide.isGranted(permission) {
            succeed(permission)
            return
        }
        if now.timeIntervalSince(openedAt) >= PermissionGuide.timeout {
            dismiss()
            return
        }
        if PermissionGuide.settingsWindowFrame() != nil {
            settingsSeen = true
            absentSince = now
        } else if now.timeIntervalSince(absentSince) >= (settingsSeen ? 3 : 5) {
            // Settings was closed (3 s after it had appeared) or never showed up (5 s after open).
            dismiss()
        }
    }

    private func succeed(_ permission: CapturePermission) {
        phase = .succeeded
        pollTimer?.invalidate()
        pollTimer = nil
        positionTimer?.invalidate()
        positionTimer = nil
        panel?.showSuccess()
        cancelSuccess()
        successTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, self.phase == .succeeded else { return }
            self.animateAlpha(to: 0)
            let fade: Duration = PermissionGuide.reduceMotion ? .milliseconds(0) : .milliseconds(180)
            try? await Task.sleep(for: fade)
            guard !Task.isCancelled, self.phase == .succeeded else { return }
            self.finish(permission)
        }
    }

    private func finish(_ permission: CapturePermission) {
        dismiss()
        onGranted?(permission)
    }

    private func cancelSuccess() {
        successTask?.cancel()
        successTask = nil
    }

    // MARK: - Helpers

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static func isGranted(_ permission: CapturePermission) -> Bool {
        switch permission {
        case .accessibility: CapturePermissions.accessibilityTrusted
        case .screenCapture: CapturePermissions.screenCaptureAllowed
        }
    }

    /// Frame of the largest on-screen System Settings window, converted to AppKit coordinates.
    private static func settingsWindowFrame() -> NSRect? {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .map(\.processIdentifier)
        )
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first
        else { return nil }

        var best: CGRect?
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 320, bounds.height >= 240
            else { continue }
            if bounds.width * bounds.height > (best.map { $0.width * $0.height } ?? 0) {
                best = bounds
            }
        }
        guard let cg = best else { return nil }
        // CG windows use a top-left origin; AppKit uses bottom-left relative to the primary screen.
        return NSRect(x: cg.minX, y: primary.frame.height - cg.maxY, width: cg.width, height: cg.height)
    }

    private static func targetOrigin(for size: NSSize, settings: NSRect?) -> NSPoint {
        if let settings {
            let visible = screen(containing: settings)?.visibleFrame ?? .zero
            var origin = NSPoint(x: settings.midX - size.width / 2, y: settings.minY - 12 - size.height)
            if origin.y < visible.minY || origin.y + size.height > visible.maxY {
                // No room below the window: sit inside it, bottom-aligned with a 16 pt inset.
                origin.y = settings.minY + 16
            }
            return clamped(origin, size: size, to: visible)
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 120)
        return clamped(origin, size: size, to: visible)
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    private static func clamped(_ origin: NSPoint, size: NSSize, to visible: NSRect) -> NSPoint {
        let x = min(max(origin.x, visible.minX + screenInset), visible.maxX - screenInset - size.width)
        let y = min(max(origin.y, visible.minY + screenInset), visible.maxY - screenInset - size.height)
        return NSPoint(x: x, y: y)
    }
}
