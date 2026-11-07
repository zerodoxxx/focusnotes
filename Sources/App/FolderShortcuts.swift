import Foundation
import CaptureKit
import Core

enum FolderShortcutAction: String, Codable, CaseIterable, Sendable {
    case quickNote, startSession

    var title: String {
        switch self {
        case .quickNote: "Quick Note"
        case .startSession: "Start Session"
        }
    }
}

struct FolderShortcut: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let keyCode: UInt32
    let modifiers: UInt32
    let action: FolderShortcutAction
    let folder: String

    var hotkey: Hotkey { Hotkey(keyCode: keyCode, modifiers: .init(rawValue: modifiers)) }

    /// The menu title, e.g. "Start Session → Sessions/Work".
    var menuTitle: String {
        guard action == .startSession else { return "\(action.title) → \(folder)" }
        let path = (try? NoteFolder(rawValue: folder))?.sessionsRelativePath ?? "\(Vault.sessionsDirectoryName)/\(folder)"
        return "\(action.title) → \(path)"
    }

    init(id: UUID = UUID(), hotkey: Hotkey, action: FolderShortcutAction, folder: String) {
        self.id = id
        keyCode = hotkey.keyCode
        modifiers = hotkey.modifiers.rawValue
        self.action = action
        self.folder = folder
    }
}

struct FolderShortcutValidationError: LocalizedError {
    let message: String
    /// Why the value was rejected, for diagnostics. The message is the text users see.
    let cause: (any Error)?
    init(message: String, cause: (any Error)? = nil) {
        self.message = message
        self.cause = cause
    }
    var errorDescription: String? { message }
}

struct FolderShortcutStore {
    static let maximumBindings = 20
    static let allowedModifiers: Hotkey.Modifiers = [.command, .option, .control, .shift]
    static let requiredModifiers: Hotkey.Modifiers = [.command, .option, .control]
    static let escapeKeyCode: UInt32 = 53
    // Modifier, caps lock, and function keys are not shortcut trigger keys.
    static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    static func hasRequiredModifier(_ modifiers: Hotkey.Modifiers) -> Bool { !modifiers.intersection(requiredModifiers).isEmpty }
    private static let envelopeVersion = 1
    let url: URL

    private struct Envelope: Codable {
        let version: Int
        let bindings: [FolderShortcut]
    }

    init(url: URL) { self.url = url }
    init(stateDirectory: URL) { self.init(url: stateDirectory.appendingPathComponent("folder-shortcuts.json")) }

    func load() throws -> [FolderShortcut] {
        guard let data = try StateFile.read(url) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == Self.envelopeVersion else {
            throw FolderShortcutValidationError(message: "Unsupported folder shortcut settings version.")
        }
        try Self.validate(envelope.bindings)
        return envelope.bindings
    }

    func save(_ bindings: [FolderShortcut]) throws {
        try Self.validate(bindings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try StateFile.writeJSON(Envelope(version: Self.envelopeVersion, bindings: bindings), to: url, encoder: encoder, createDirectory: true)
    }

    static func validate(_ bindings: [FolderShortcut]) throws {
        func reject(_ message: String, cause: (any Error)? = nil) throws { throw FolderShortcutValidationError(message: message, cause: cause) }
        guard bindings.count <= maximumBindings else { try reject("You can add up to \(maximumBindings) folder shortcuts."); return }
        let builtIns: Set<Hotkey> = [.captureSelection, .captureRegion, .captureSelectionOutsideSession,
            .captureRegionOutsideSession, .search, .toggleSession, .writeNote, .writeNoteOutsideSession, .addSubheading, .openLibrary]
        var ids = Set<UUID>()
        var chords = Set<Hotkey>()
        for binding in bindings {
            guard ids.insert(binding.id).inserted else { try reject("Each folder shortcut must have a unique identity."); return }
            let chord = binding.hotkey
            guard chord.modifiers.rawValue & ~allowedModifiers.rawValue == 0,
                  hasRequiredModifier(chord.modifiers),
                  chord.keyCode <= 126, chord.keyCode != escapeKeyCode, !modifierKeyCodes.contains(chord.keyCode) else {
                try reject("Choose a key with Command, Option, or Control. Escape and modifier keys cannot be used."); return
            }
            guard !builtIns.contains(chord) else { try reject("This combination is already used by a built-in shortcut."); return }
            guard chords.insert(chord).inserted else { try reject("This combination is already used by another folder shortcut."); return }
            let folder: NoteFolder
            do { folder = try NoteFolder(rawValue: binding.folder) }
            catch {
                try reject("Enter a nonempty relative folder path without a leading slash, traversal (..), or hidden names.", cause: error)
                return
            }
            guard !binding.folder.isEmpty, folder.rawValue == binding.folder else {
                try reject("Choose a valid relative folder path without empty components or surrounding whitespace."); return
            }
            if binding.action == .quickNote, folder.components.first?.lowercased() == Vault.assetsDirectoryName.lowercased() {
                try reject("The assets folder is reserved for captured images. Choose another quick note folder."); return
            }
        }
    }
}
