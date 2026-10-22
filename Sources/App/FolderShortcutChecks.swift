import Foundation
import CaptureKit

@MainActor
func checkFolderShortcuts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folder-shortcuts-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("state/folder-shortcuts.json")
    let store = FolderShortcutStore(url: url)
    guard try store.load().isEmpty else { throw SelfTestFailure("Missing folder shortcuts did not load as empty") }
    let chord = Hotkey(keyCode: 11, modifiers: [.command, .option])
    let note = FolderShortcut(hotkey: chord, action: .quickNote, folder: "Projects/Research")
    let session = FolderShortcut(hotkey: Hotkey(keyCode: 12, modifiers: [.command, .option]), action: .startSession, folder: "Work")
    try store.save([note, session])
    guard try store.load() == [note, session] else { throw SelfTestFailure("Folder shortcut persistence lost identity, action, or destination") }
    let original = try Data(contentsOf: url)

    func rejects(_ bindings: [FolderShortcut], _ reason: String) throws {
        do { try store.save(bindings) }
        catch {
            guard try Data(contentsOf: url) == original else { throw SelfTestFailure("Rejected folder shortcuts changed saved settings: \(reason)") }
            return
        }
        throw SelfTestFailure("Folder shortcuts accepted \(reason)")
    }
    try rejects([note, note], "duplicate identities")
    try rejects([note, FolderShortcut(hotkey: chord, action: .startSession, folder: "Other")], "duplicate chords")
    try rejects([FolderShortcut(hotkey: .writeNote, action: .quickNote, folder: "Work")], "a built-in chord")
    try rejects([FolderShortcut(hotkey: .writeNoteOutsideSession, action: .quickNote, folder: "Work")], "the outside-session quick note chord")
    for reserved in ["assets", "ASSETS/sub"] {
        try rejects([FolderShortcut(hotkey: chord, action: .quickNote, folder: reserved)], "reserved quick note folder \(reserved)")
        try FolderShortcutStore.validate([FolderShortcut(hotkey: chord, action: .startSession, folder: reserved)])
    }
    for invalid in ["", "/Work", "~/Work", "../Work", "Work/../Other", "Work\\Other", "Work//Other", "Work/", " Work"] {
        try rejects([FolderShortcut(hotkey: chord, action: .quickNote, folder: invalid)], "unsafe folder \(invalid)")
    }
    let invalidChords = [
        Hotkey(keyCode: 11, modifiers: []),
        Hotkey(keyCode: 11, modifiers: [.shift]),
        Hotkey(keyCode: 53, modifiers: [.command]),
        Hotkey(keyCode: 55, modifiers: [.command]),
        Hotkey(keyCode: 255, modifiers: [.command]),
        Hotkey(keyCode: 11, modifiers: .init(rawValue: UInt32.max))
    ]
    for invalid in invalidChords {
        try rejects([FolderShortcut(hotkey: invalid, action: .quickNote, folder: "Work")], "an unsafe chord")
    }
    try rejects((0...FolderShortcutStore.maximumBindings).map { index in
        FolderShortcut(hotkey: Hotkey(keyCode: UInt32(index), modifiers: [.command, .option]), action: .quickNote, folder: "Work")
    }, "too many bindings")

    for malformed in ["{broken", "{\"version\":99,\"bindings\":[]}", "{\"version\":1,\"bindings\":[{}]}"] {
        let bytes = Data(malformed.utf8)
        try bytes.write(to: url, options: .atomic)
        do { _ = try store.load() }
        catch {
            guard try Data(contentsOf: url) == bytes else { throw SelfTestFailure("Loading malformed folder shortcuts changed the original file") }
            continue
        }
        throw SelfTestFailure("Folder shortcut load accepted malformed or unsupported settings")
    }
}
