import Carbon

public struct Hotkey: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let command = Self(rawValue: UInt32(cmdKey))
        public static let option = Self(rawValue: UInt32(optionKey))
        public static let shift = Self(rawValue: UInt32(shiftKey))
        public static let control = Self(rawValue: UInt32(controlKey))
    }

    public let keyCode: UInt32
    public let modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Physical ANSI key labels; the virtual key code is independent of the keyboard layout.
    private static let labels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`",
        51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    public var displayString: String {
        return (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
            + (Self.labels[keyCode] ?? "Key \(keyCode)")
    }

    /// Character for NSMenuItem.keyEquivalent; empty when the key has no plain ASCII character.
    public var menuKeyEquivalent: String {
        guard let label = Self.labels[keyCode], label.count == 1, label.unicodeScalars.allSatisfy(\.isASCII) else { return "" }
        return label.lowercased()
    }

    public static let captureSelection = Self(keyCode: UInt32(kVK_ANSI_C), modifiers: [.option, .shift])
    public static let captureRegion = Self(keyCode: UInt32(kVK_ANSI_S), modifiers: [.option, .shift])
    public static let captureSelectionOutsideSession = Self(keyCode: UInt32(kVK_ANSI_C), modifiers: [.control, .shift])
    public static let captureRegionOutsideSession = Self(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .shift])
    public static let search = Self(keyCode: UInt32(kVK_ANSI_F), modifiers: [.option, .shift])
    public static let toggleSession = Self(keyCode: UInt32(kVK_ANSI_A), modifiers: [.option, .shift])
    public static let writeNote = Self(keyCode: UInt32(kVK_ANSI_N), modifiers: [.option, .shift])
    public static let addSubheading = Self(keyCode: UInt32(kVK_ANSI_H), modifiers: [.option, .shift])
    public static let openLibrary = Self(keyCode: UInt32(kVK_ANSI_L), modifiers: [.option, .shift])
}

public enum HotkeyError: Error, Equatable, Sendable {
    case conflict
    case duplicateID
    case eventHandlerInstallationFailed(status: Int32)
    case registrationFailed(status: Int32)
}

@MainActor
public final class HotkeyCenter {
    private struct Registration {
        let reference: EventHotKeyRef
        let handler: @MainActor @Sendable () -> Void
    }

    private static var nextSignature: UInt32 = 0x434B0000
    private let signature: UInt32
    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]

    public init() {
        signature = Self.nextSignature
        Self.nextSignature &+= 1
    }

    isolated deinit {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.reference)
        }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    public func register(
        _ hotkey: Hotkey,
        id: UInt32,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, HotkeyError> {
        guard registrations[id] == nil else { return .failure(.duplicateID) }
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                    // The application event target dispatches on the main thread.
                    return MainActor.assumeIsolated {
                        Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue().receive(event)
                    }
                },
                1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler
            )
            guard status == noErr else { return .failure(.eventHandlerInstallationFailed(status: status)) }
        }

        var reference: EventHotKeyRef?
        // Without exclusive registration Carbon allows other apps to share the shortcut.
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers.rawValue,
            EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference
        )
        if status == eventHotKeyExistsErr { return .failure(.conflict) }
        guard status == noErr, let reference else { return .failure(.registrationFailed(status: status)) }
        registrations[id] = Registration(reference: reference, handler: handler)
        return .success(())
    }

    public func unregister(id: UInt32) {
        if let registration = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(registration.reference)
        }
        if registrations.isEmpty, let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    public func unregisterAll() {
        for id in Array(registrations.keys) { unregister(id: id) }
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID
        )
        guard status == noErr, hotkeyID.signature == signature,
              let registration = registrations[hotkeyID.id] else { return OSStatus(eventNotHandledErr) }
        registration.handler()
        return noErr
    }
}
