import Foundation

/// Pinned notes live in app state, never in the Markdown. A missing or corrupt file reads as empty
/// and is replaced by the next successful write; an unreadable file throws so a toggle never erases pins.
final class NotePinStore: @unchecked Sendable {
    private let lock = NSLock()
    let url: URL
    init(stateDirectory: URL) { url = stateDirectory.appendingPathComponent("pinned-notes.json") }

    func isPinned(_ path: String) -> Bool {
        lock.withLock { ((try? read()) ?? []).contains(path) }
    }
    func paths() -> Set<String> {
        lock.withLock { (try? read()) ?? [] }
    }
    @discardableResult
    func toggle(_ path: String) throws -> Bool {
        try lock.withLock {
            var current = try read()
            let pinned = !current.contains(path)
            if pinned { current.insert(path) } else { current.remove(path) }
            try write(current)
            return pinned
        }
    }
    func set(_ path: String, pinned: Bool) throws {
        try lock.withLock {
            var current = try read()
            guard current.contains(path) != pinned else { return }
            if pinned { current.insert(path) } else { current.remove(path) }
            try write(current)
        }
    }
    func rename(from oldPath: String, to newPath: String) throws {
        guard oldPath != newPath else { return }
        try lock.withLock {
            var current = try read()
            guard current.remove(oldPath) != nil else { return }
            current.insert(newPath)
            try write(current)
        }
    }
    private func read() throws -> Set<String> {
        guard let data = try StateFile.read(url), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }
    private func write(_ paths: Set<String>) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try StateFile.writeJSON(paths.sorted(), to: url, encoder: encoder, createDirectory: true)
    }
}
