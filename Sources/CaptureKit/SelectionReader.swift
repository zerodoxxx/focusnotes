import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

// Bounds each AX call so a hung app cannot stall capture.
enum AccessibilityTimeout {
    static let messaging: Float = 0.2
}

public enum SelectionMethod: String, Sendable {
    case accessibility
    case clipboard
}

public struct SelectionCapture: Equatable, Sendable {
    public let text: String
    public let context: FrontmostContext
    public let method: SelectionMethod
}

public enum SelectionFailure: Error, Equatable, Sendable {
    case noSelection
    case secureInput
    case accessibilityNotTrusted
    case ownApp
}

public enum PasteboardSnapshotError: Error, Equatable, Sendable {
    case unreadableType(String)
    case changedDuringSnapshot
}

/// Materializes all representations, including lazy pasteboard providers, before a copy.
public struct PasteboardSnapshot: Equatable, Sendable {
    public let items: [[String: Data]]
    public let changeCount: Int

    @MainActor
    public init(pasteboard: NSPasteboard) throws {
        changeCount = pasteboard.changeCount
        var copies: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [String: Data] = [:]
            for type in item.types {
                // Skip representations that can't be materialized (e.g. stale promises) instead of
                // failing the whole capture; the readable ones are still restored.
                guard let data = item.data(forType: type) else { continue }
                representations[type.rawValue] = data
            }
            copies.append(representations)
        }
        guard pasteboard.changeCount == changeCount else { throw PasteboardSnapshotError.changedDuringSnapshot }
        items = copies
    }

    /// Never restore over a subsequent copy. Returns false if ownership changed or writing failed.
    @MainActor
    @discardableResult
    public func restore(to pasteboard: NSPasteboard, ifUnchangedSince expectedCount: Int) -> Bool {
        let restoredItems = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: .init(type)) }
            return item
        }
        guard pasteboard.changeCount == expectedCount else { return false }
        pasteboard.clearContents()
        return restoredItems.isEmpty || pasteboard.writeObjects(restoredItems)
    }
}

@MainActor
public enum SelectionReader {
    private static var captureInProgress = false

    /// Pass a hotkey-time snapshot if work was scheduled asynchronously after the hotkey.
    public static func read(context suppliedContext: FrontmostContext? = nil) async -> Result<SelectionCapture, SelectionFailure> {
        let context = suppliedContext ?? FrontmostContext.capture()
        guard context.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .failure(.ownApp) }
        guard !IsSecureEventInputEnabled() else { return .failure(.secureInput) }
        guard context.processIdentifier != 0, !captureInProgress else { return .failure(.noSelection) }
        captureInProgress = true
        defer { captureInProgress = false }
        guard CapturePermissions.accessibilityTrusted else { return .failure(.accessibilityNotTrusted) }
        guard isStillFrontmost(context) else { return .failure(.noSelection) }

        if let text = selectedText(in: context), !text.isEmpty, isStillFrontmost(context) {
            guard !IsSecureEventInputEnabled() else { return .failure(.secureInput) }
            return .success(SelectionCapture(text: text, context: context, method: .accessibility))
        }

        // Wait briefly for the physical hotkey modifiers. A private event source plus explicit
        // Command-only flags prevents held Option/Shift from leaking into Cmd+C even at the deadline.
        let clock = ContinuousClock()
        let releaseDeadline = clock.now.advanced(by: .milliseconds(200))
        let unwantedFlags: CGEventFlags = [.maskAlternate, .maskShift, .maskControl]
        while !CGEventSource.flagsState(.hidSystemState).intersection(unwantedFlags).isEmpty,
              clock.now < releaseDeadline {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return .failure(.noSelection) }
        }
        guard !Task.isCancelled, isStillFrontmost(context) else { return .failure(.noSelection) }
        guard !IsSecureEventInputEnabled() else { return .failure(.secureInput) }
        guard CapturePermissions.accessibilityTrusted else { return .failure(.accessibilityNotTrusted) }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false),
              let snapshot = try? PasteboardSnapshot(pasteboard: .general) else { return .failure(.noSelection) }

        let pasteboard = NSPasteboard.general
        // Materializing lazy clipboard data can take time: recheck immediately before posting.
        guard !IsSecureEventInputEnabled() else { return .failure(.secureInput) }
        guard !Task.isCancelled, isStillFrontmost(context) else { return .failure(.noSelection) }
        guard CapturePermissions.accessibilityTrusted else { return .failure(.accessibilityNotTrusted) }
        guard pasteboard.changeCount == snapshot.changeCount else { return .failure(.noSelection) }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)

        let copyDeadline = clock.now.advanced(by: .milliseconds(500))
        while pasteboard.changeCount == snapshot.changeCount, clock.now < copyDeadline {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { break }
        }
        let copyChangeCount = pasteboard.changeCount
        guard copyChangeCount != snapshot.changeCount else { return .failure(.noSelection) }
        defer { snapshot.restore(to: pasteboard, ifUnchangedSince: copyChangeCount) }
        // Editors such as VS Code may copy the current line with no selection; accept that behavior.
        guard !Task.isCancelled, let text = pasteboard.string(forType: .string),
              !text.isEmpty,
              pasteboard.changeCount == copyChangeCount else { return .failure(.noSelection) }
        return .success(SelectionCapture(text: text, context: context, method: .clipboard))
    }

    private static func isStillFrontmost(_ context: FrontmostContext) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processIdentifier
    }

    private static func selectedText(in context: FrontmostContext) -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, AccessibilityTimeout.messaging)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == context.processIdentifier else { return nil }
        AXUIElementSetMessagingTimeout(element, AccessibilityTimeout.messaging)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
