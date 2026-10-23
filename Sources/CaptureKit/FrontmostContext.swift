import AppKit
import ApplicationServices

public struct FrontmostContext: Equatable, Sendable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t
    public let windowTitle: String?
    public let url: String?

    public init(appName: String?, bundleIdentifier: String?, processIdentifier: pid_t, windowTitle: String?, url: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
        self.url = url
    }

    /// Call synchronously at hotkey entry, before scheduling capture work or opening any UI.
    /// A zero PID means that macOS did not report a frontmost application.
    @MainActor
    public static func capture() -> Self {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return Self(appName: nil, bundleIdentifier: nil, processIdentifier: 0, windowTitle: nil)
        }
        var title: String?
        var url: String?
        if AXIsProcessTrusted() {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.2)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                let element = unsafeDowncast(window, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(element, 0.2)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success {
                    title = value as? String
                }
                url = BrowserAddressURL.capture(bundleIdentifier: app.bundleIdentifier,
                                                processIdentifier: app.processIdentifier, window: element)
            }
        }
        return Self(appName: app.localizedName, bundleIdentifier: app.bundleIdentifier,
                    processIdentifier: app.processIdentifier, windowTitle: title, url: url)
    }
}
