import AppKit

/// AppKit virtual key codes used by the overlays.
enum OverlayKeyCode {
    static let a: UInt16 = 0
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let x: UInt16 = 7
    static let z: UInt16 = 6
    static let o: UInt16 = 31
    static let p: UInt16 = 35
    static let k: UInt16 = 40
    static let n: UInt16 = 45
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let tab: UInt16 = 48
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

/// List and card navigation shared by the overlays. Arrow, Return/Enter, Escape and Tab match regardless of
/// modifiers; ⌘K and ⌘P need exactly ⌘.
enum OverlayKeyCommand: Equatable {
    case moveDown, moveUp, submit, cancel, complete, toggleActions, toggleBrowse

    init?(_ event: NSEvent) {
        switch event.keyCode {
        case OverlayKeyCode.downArrow: self = .moveDown
        case OverlayKeyCode.upArrow: self = .moveUp
        case OverlayKeyCode.returnKey, OverlayKeyCode.keypadEnter: self = .submit
        case OverlayKeyCode.escape: self = .cancel
        case OverlayKeyCode.tab: self = .complete
        case OverlayKeyCode.k where event.shortcutFlags == .command: self = .toggleActions
        case OverlayKeyCode.p where event.shortcutFlags == .command: self = .toggleBrowse
        default: return nil
        }
    }
}
