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
