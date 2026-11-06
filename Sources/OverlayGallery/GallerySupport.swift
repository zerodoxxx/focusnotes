import AppKit

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
