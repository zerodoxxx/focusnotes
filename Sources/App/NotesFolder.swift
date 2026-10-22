import AppKit
import CryptoKit
import Foundation

/// Folder preferences change the next launch, never the running capture pipeline.
@MainActor
enum NotesFolder {
    private struct LegacyRoot: Codable {
        let configuredPath: String
        let canonicalPath: String?
    }

    static func configuredRoot(defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: "vaultPath") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents").appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    /// Keep existing installations on their original state directory. Other roots
    /// get independent sessions, recovery journals, indexes, drafts and pins.
    static func stateDirectory(for root: URL, base: URL) throws -> URL {
        let path = root.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        let reachable = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        let canonical = reachable ? root.standardizedFileURL.resolvingSymlinksInPath().path : nil
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let marker = base.appendingPathComponent("legacy-vault-root.json")
        let legacy: LegacyRoot
        do {
            let decoded = try JSONDecoder().decode(LegacyRoot.self, from: Data(contentsOf: marker))
            guard (decoded.configuredPath as NSString).isAbsolutePath,
                  decoded.canonicalPath.map({ ($0 as NSString).isAbsolutePath }) ?? true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            legacy = decoded
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            let original = LegacyRoot(configuredPath: path, canonicalPath: canonical)
            try JSONEncoder().encode(original).write(to: marker, options: .atomic)
            legacy = original
        }
        if let original = legacy.canonicalPath {
            if canonical == original { return base }
        } else if path == legacy.configuredPath || canonical == legacy.configuredPath {
            if let canonical {
                let restored = LegacyRoot(configuredPath: legacy.configuredPath, canonicalPath: canonical)
                try JSONEncoder().encode(restored).write(to: marker, options: .atomic)
            }
            return base
        }
        let key = SHA256.hash(data: Data((canonical ?? path).utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("vaults", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    @discardableResult
    static func save(_ root: URL, defaults: UserDefaults = .standard) throws -> URL {
        let folder = try validate(root)
        defaults.set(folder.path, forKey: "vaultPath")
        return folder
    }

    private static func validate(_ root: URL) throws -> URL {
        guard root.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let folder = root.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Exercise the write rather than relying only on permission bits or ACLs.
        let probe = folder.appendingPathComponent(".focusnotes-write-test-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: probe) }
        try FileManager.default.removeItem(at: probe)
        return folder
    }

    /// Cancellation leaves both the preference and the running vault unchanged.
    static func choose(current: URL, defaults: UserDefaults = .standard) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Notes Folder"
        panel.message = "Choose the folder where \(AppInfo.name) saves your Markdown notes. Existing notes stay in place."
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        NSApp.activate()
        while panel.runModal() == .OK {
            guard let url = panel.url else { return nil }
            do { return try save(url, defaults: defaults) }
            catch { showError(error) }
        }
        return nil
    }

    /// A first-launch choice runs before opening the vault or registering shortcuts.
    /// Existing users retain their configured folder without another setup prompt.
    static func startupRoot(defaults: UserDefaults = .standard) -> URL? {
        let root = configuredRoot(defaults: defaults)
        guard !defaults.bool(forKey: "didShowNotesFolderSetup"),
              defaults.string(forKey: "vaultPath") == nil,
              !defaults.bool(forKey: "didShowAccessibilityGuide") else {
            defaults.set(true, forKey: "didShowNotesFolderSetup")
            do { return try validate(root) }
            catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Can't open the notes folder"
                alert.informativeText = "\(root.path)\n\n\(error.localizedDescription)\n\nChoose another folder, or quit and restore access to this folder."
                alert.addButton(withTitle: "Choose Notes Folder…")
                alert.addButton(withTitle: "Quit")
                NSApp.activate()
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                return choose(current: root, defaults: defaults)
            }
        }
        while true {
            let alert = NSAlert()
            alert.messageText = "Where should \(AppInfo.name) save your notes?"
            alert.informativeText = "Use \(root.path), or choose an existing notes folder such as an Obsidian vault. You can change this later in the menu bar."
            alert.addButton(withTitle: "Use This Folder")
            alert.addButton(withTitle: "Choose Notes Folder…")
            alert.addButton(withTitle: "Quit")
            NSApp.activate()
            let selected: URL?
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do { selected = try save(root, defaults: defaults) }
                catch { showError(error); continue }
            case .alertSecondButtonReturn:
                selected = choose(current: root, defaults: defaults)
            default:
                return nil
            }
            guard let selected else { continue }
            defaults.set(true, forKey: "didShowNotesFolderSetup")
            return selected
        }
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't use that notes folder"
        alert.informativeText = "Choose a folder you can write to. \(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
