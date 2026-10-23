import ApplicationServices
import Foundation

@_spi(Testing)
public enum BrowserAddressURL {
    private static let supportedBundles: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac"
    ]

    @MainActor
    static func capture(bundleIdentifier: String?, processIdentifier: pid_t, window: AXUIElement) -> String? {
        guard let bundleIdentifier, supportedBundles.contains(bundleIdentifier), processIdentifier > 0,
              belongsToProcess(window, processIdentifier) else { return nil }

        // AX can stall or expose an enormous page tree. Inspect only a small part of
        // the focused window's browser chrome, never descendants of a web area.
        let deadline = CFAbsoluteTimeGetCurrent() + 0.20
        var pending: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        var next = 0
        while next < pending.count, next < 32, CFAbsoluteTimeGetCurrent() < deadline {
            let (element, depth, insideToolbar) = pending[next]
            next += 1
            guard belongsToProcess(element, processIdentifier) else { continue }
            AXUIElementSetMessagingTimeout(element, 0.02)
            guard let role = stringAttribute(kAXRoleAttribute, of: element), role != "AXWebArea" else { continue }
            let inToolbar = insideToolbar || role == kAXToolbarRole as String

            if role == kAXTextFieldRole as String,
               recognizedField(bundleIdentifier: bundleIdentifier, role: role,
                               identifier: stringAttribute(kAXIdentifierAttribute, of: element),
                               title: stringAttribute(kAXTitleAttribute, of: element),
                               description: stringAttribute(kAXDescriptionAttribute, of: element),
                               insideToolbar: inToolbar),
               belongsToWindow(element, window) {
                if let url = capturableValue(focused: boolAttribute(kAXFocusedAttribute, of: element),
                                             nativeURL: stringAttribute(kAXURLAttribute, of: element),
                                             displayedValue: stringAttribute(kAXValueAttribute, of: element)) { return url }
            }

            guard depth < 6, pending.count < 32, CFAbsoluteTimeGetCurrent() < deadline else { continue }
            var value: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 32, &value) == .success,
                  let children = value as? [AnyObject] else { continue }
            for child in children.prefix(32 - pending.count) where CFGetTypeID(child) == AXUIElementGetTypeID() {
                pending.append((unsafeDowncast(child, to: AXUIElement.self), depth + 1, inToolbar))
            }
        }
        return nil
    }

    @_spi(Testing)
    public static func recognizedField(bundleIdentifier: String?, role: String, identifier: String?,
                                       title: String?, description: String?, insideToolbar: Bool) -> Bool {
        guard let bundleIdentifier, supportedBundles.contains(bundleIdentifier), insideToolbar,
              role == kAXTextFieldRole as String else { return false }
        switch bundleIdentifier {
        case "com.apple.Safari":
            return identifier == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
        case "com.google.Chrome", "com.microsoft.edgemac":
            return title == "Address and search bar" || description == "Address and search bar"
        default:
            return false
        }
    }

    @_spi(Testing)
    public static func capturableValue(focused: Bool?, nativeURL: String?, displayedValue: String?) -> String? {
        // A focused address field may contain an unsubmitted edit, not the loaded page.
        guard focused == false else { return nil }
        return validated(nativeURL) ?? validated(displayedValue)
    }

    @_spi(Testing)
    public static func validated(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 8192,
              raw.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                                              && !CharacterSet.controlCharacters.contains($0) }),
              !raw.contains("\\"),
              let parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.url != nil, hasOnlyEncodedPercents(raw) else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        return raw
    }

    private static func hasOnlyEncodedPercents(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        for (index, byte) in bytes.enumerated() where byte == 37 {
            guard index + 2 < bytes.count,
                  bytes[(index + 1)...(index + 2)].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
            else { return false }
        }
        return true
    }

    private static func belongsToProcess(_ element: AXUIElement, _ processIdentifier: pid_t) -> Bool {
        var elementPID: pid_t = 0
        return AXUIElementGetPid(element, &elementPID) == .success && elementPID == processIdentifier
    }

    private static func belongsToWindow(_ element: AXUIElement, _ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return CFEqual(value, window)
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        if let text = value as? String { return text }
        return (value as? URL)?.absoluteString
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
