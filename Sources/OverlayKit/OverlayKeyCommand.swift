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

/// A panel shortcut: the keys it matches and the glyphs shown for it.
struct KeyBinding {
    let keyCodes: Set<UInt16>
    let modifiers: NSEvent.ModifierFlags
    /// When true no other modifier may be held; otherwise extra modifiers are ignored.
    let exact: Bool
    let glyph: String

    func matches(_ event: NSEvent) -> Bool {
        guard keyCodes.contains(event.keyCode) else { return false }
        let flags = event.shortcutFlags
        return exact ? flags == modifiers : flags.contains(modifiers)
    }
}

enum PanelShortcuts {
    static let toggleActions = KeyBinding(keyCodes: [OverlayKeyCode.k], modifiers: .command, exact: true, glyph: "⌘K")
    static let toggleBrowse = KeyBinding(keyCodes: [OverlayKeyCode.p], modifiers: .command, exact: true, glyph: "⌘P")
    static let save = KeyBinding(keyCodes: [OverlayKeyCode.returnKey, OverlayKeyCode.keypadEnter], modifiers: .command, exact: false, glyph: "⌘↩")
    /// First match wins: ⇧⌘P (pin) must precede ⌘P (browse).
    static let noteActions: [(id: NoteActionID, binding: KeyBinding)] = [
        (.copyMarkdown, KeyBinding(keyCodes: [OverlayKeyCode.c], modifiers: [.command, .shift], exact: false, glyph: "⇧⌘C")),
        (.pin, KeyBinding(keyCodes: [OverlayKeyCode.p], modifiers: [.command, .shift], exact: false, glyph: "⇧⌘P")),
        (.browse, KeyBinding(keyCodes: [OverlayKeyCode.p], modifiers: .command, exact: false, glyph: toggleBrowse.glyph)),
        (.writeOutsideSession, KeyBinding(keyCodes: [OverlayKeyCode.n], modifiers: [.command, .shift], exact: true, glyph: "⇧⌘N")),
        (.newNote, KeyBinding(keyCodes: [OverlayKeyCode.n], modifiers: .command, exact: true, glyph: "⌘N")),
        (.openAsNote, KeyBinding(keyCodes: [OverlayKeyCode.o], modifiers: .command, exact: false, glyph: "⌘O")),
        (.discardDraft, KeyBinding(keyCodes: [OverlayKeyCode.delete], modifiers: [.command, .shift], exact: false, glyph: "⇧⌘⌫")),
        (.saveAsNewNote, KeyBinding(keyCodes: [OverlayKeyCode.returnKey, OverlayKeyCode.keypadEnter], modifiers: [.command, .option], exact: false, glyph: "⌥⌘↩")),
    ]
    static func glyph(for id: NoteActionID) -> String {
        noteActions.first { $0.id == id }?.binding.glyph ?? ""
    }
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
        case _ where PanelShortcuts.toggleActions.matches(event): self = .toggleActions
        case _ where PanelShortcuts.toggleBrowse.matches(event): self = .toggleBrowse
        default: return nil
        }
    }
}
