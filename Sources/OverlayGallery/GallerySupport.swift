import AppKit
@_spi(Checks) import OverlayKit

struct GalleryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
func currentPanel() throws -> OverlayPanel {
    try autoreleasepool {
        let panels = NSApp.windows.compactMap { $0 as? OverlayPanel }.filter { $0.isVisible && $0.canBecomeKey }
        // Sticky note panels may remain visible after losing key status. Synthetic input and
        // assertions must follow the active panel, not NSApp.windows enumeration order.
        let panel = panels.first(where: \.isKeyWindow)
            ?? panels.max(by: { $0.windowNumber < $1.windowNumber })
        guard let panel else {
            throw GalleryError("Interactive panel was not visible")
        }
        return panel
    }
}

@MainActor
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw GalleryError(message) }
}

@MainActor
func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

@MainActor
func views(named typeName: String, in root: NSView) -> [NSView] {
    descendants(root).filter { String(describing: type(of: $0)) == typeName }
}

// ChromeButton is internal to OverlayKit, so this is the single place its name is matched.
@MainActor
func chromeButtons(in root: NSView) -> [NSView] {
    views(named: "ChromeButton", in: root)
}

@MainActor
func labels(in view: NSView) -> [String] {
    descendants(view).compactMap { $0 as? NSTextField }.map(\.stringValue)
}

/// Records any real focus or on-screen event during a focus-free `--check` run.
@MainActor
final class FocusGuard: NSObject {
    private var violations: [String] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSApplication.didBecomeActiveNotification, NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(self, selector: #selector(observed(_:)), name: name, object: nil)
        }
    }

    @objc private func observed(_ note: Notification) {
        if note.name == NSWindow.didChangeOcclusionStateNotification,
           (note.object as? NSWindow)?.occlusionState.contains(.visible) != true { return }
        violations.append("\(note.name.rawValue): \(String(describing: note.object))")
    }

    func verify() throws {
        NotificationCenter.default.removeObserver(self)
        var found = violations
        if let key = NSApp.keyWindow { found.append("NSApp.keyWindow is \(key)") }
        if NSApp.isActive { found.append("NSApp is active") }
        let pid = Int(getpid())
        let onScreen = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
        if !onScreen.isEmpty { found.append("\(onScreen.count) on-screen window(s)") }
        guard found.isEmpty else { throw GalleryError("Focus-free check took focus: " + found.joined(separator: "; ")) }
        print("Focus-free guard passed: no key window, activation, or on-screen window.")
    }
}
