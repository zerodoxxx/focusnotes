import AppKit
import ApplicationServices

public struct FrontmostContext: Equatable, Sendable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t
    public let windowTitle: String?
    public let url: String?
    public let documentURL: String?

    public init(appName: String?, bundleIdentifier: String?, processIdentifier: pid_t, windowTitle: String?,
                url: String? = nil, documentURL: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
        self.url = url
        self.documentURL = documentURL
    }

    /// The PDF page is read from the window title, so it is only meaningful alongside a PDF document.
    public var page: Int? {
        documentURL == nil ? nil : Self.pdfPage(inWindowTitle: windowTitle)
    }

    @_spi(Testing)
    public static func pdfDocumentURL(_ raw: Any?) -> String? {
        let url: URL?
        if let string = raw as? String {
            url = URL(string: string)
        } else {
            url = raw as? URL
        }
        guard let url, url.isFileURL, !url.path.isEmpty, url.pathExtension.lowercased() == "pdf" else { return nil }
        return url.absoluteString
    }

    @_spi(Testing)
    public static func pdfPage(inWindowTitle title: String?) -> Int? {
        guard let title, let regex = try? NSRegularExpression(pattern: #"\bpage\s+(\d{1,6})(?:\s+of\s+\d{1,6})?\b"#,
                                                              options: [.caseInsensitive]),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title),
              let page = Int(title[range]), page >= 1 else { return nil }
        return page
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
        var documentURL: String?
        if AXIsProcessTrusted() {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, AccessibilityTimeout.messaging)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                let element = unsafeDowncast(window, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(element, AccessibilityTimeout.messaging)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success {
                    title = value as? String
                }
                if AXUIElementCopyAttributeValue(element, kAXDocumentAttribute as CFString, &value) == .success {
                    documentURL = pdfDocumentURL(value)
                }
                url = BrowserAddressURL.capture(bundleIdentifier: app.bundleIdentifier,
                                                processIdentifier: app.processIdentifier, window: element)
            }
        }
        return Self(appName: app.localizedName, bundleIdentifier: app.bundleIdentifier,
                    processIdentifier: app.processIdentifier, windowTitle: title, url: url, documentURL: documentURL)
    }
}
