import AppKit
// The C header declares the immutable AX prompt key as a mutable global.
@preconcurrency import ApplicationServices
import CoreGraphics

public enum CapturePermission: Sendable {
    case accessibility
    case screenCapture
}

@MainActor
public enum CapturePermissions {
    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func promptForAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static var screenCaptureAllowed: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    /// Explicit user action only: opening Settings intentionally changes the frontmost app.
    /// Tries the modern pane (macOS 13+) first and falls back to the legacy form if it cannot be opened.
    @discardableResult
    public static func openSettings(for permission: CapturePermission) -> Bool {
        let pane: String
        switch permission {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenCapture: pane = "Privacy_ScreenCapture"
        }
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane)",
        ]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) { return true }
        }
        return false
    }
}
