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
    var errorDescription: String? { message }
}

struct FolderShortcutStore {
    static let maximumBindings = 20
    let url: URL

    private struct Envelope: Codable {
        let version: Int
        let bindings: [FolderShortcut]
    }

    init(url: URL) { self.url = url }

    func load() throws -> [FolderShortcut] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else {
            throw FolderShortcutValidationError(message: "Unsupported folder shortcut settings version.")
        }
        try Self.validate(envelope.bindings)
        return envelope.bindings
    }

    func save(_ bindings: [FolderShortcut]) throws {
        try Self.validate(bindings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, bindings: bindings))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func validate(_ bindings: [FolderShortcut]) throws {
        func reject(_ message: String) throws { throw FolderShortcutValidationError(message: message) }
        guard bindings.count <= maximumBindings else { try reject("You can add up to \(maximumBindings) folder shortcuts."); return }
        let builtIns: Set<Hotkey> = [.captureSelection, .captureRegion, .captureSelectionOutsideSession,
            .captureRegionOutsideSession, .search, .toggleSession, .writeNote, .writeNoteOutsideSession, .addSubheading, .openLibrary]
        let allowed: Hotkey.Modifiers = [.command, .option, .control, .shift]
        let required: Hotkey.Modifiers = [.command, .option, .control]
        // Modifier, caps lock, and function keys are not shortcut trigger keys.
        let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        var ids = Set<UUID>()
        var chords = Set<Hotkey>()
        for binding in bindings {
            guard ids.insert(binding.id).inserted else { try reject("Each folder shortcut must have a unique identity."); return }
            let chord = binding.hotkey
            guard chord.modifiers.rawValue & ~allowed.rawValue == 0,
                  !chord.modifiers.intersection(required).isEmpty,
                  chord.keyCode <= 126, chord.keyCode != 53, !modifierKeyCodes.contains(chord.keyCode) else {
                try reject("Choose a key with Command, Option, or Control. Escape and modifier keys cannot be used."); return
            }
            guard !builtIns.contains(chord) else { try reject("This combination is already used by a built-in shortcut."); return }
            guard chords.insert(chord).inserted else { try reject("This combination is already used by another folder shortcut."); return }
            let folder: NoteFolder
            do { folder = try NoteFolder(rawValue: binding.folder) }
            catch {
                try reject("Enter a nonempty relative folder path without a leading slash, traversal (..), or hidden names.")
                return
            }
            guard !binding.folder.isEmpty, folder.rawValue == binding.folder else {
                try reject("Choose a valid relative folder path without empty components or surrounding whitespace."); return
            }
            if binding.action == .quickNote, folder.components.first?.lowercased() == "assets" {
                try reject("The assets folder is reserved for captured images. Choose another quick note folder."); return
            }
        }
    }
}
