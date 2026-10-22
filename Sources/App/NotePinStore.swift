import Foundation

/// Pinned notes live in app state, never in the Markdown. A corrupt file reads as empty
/// and is replaced by the next successful write.
final class NotePinStore: @unchecked Sendable {
    private let lock = NSLock()
    let url: URL
    init(stateDirectory: URL) { url = stateDirectory.appendingPathComponent("pinned-notes.json") }

    func isPinned(_ path: String) -> Bool {
        lock.withLock { read().contains(path) }
    }
    func paths() -> Set<String> {
        lock.withLock { read() }
    }
    @discardableResult
    func toggle(_ path: String) throws -> Bool {
        try lock.withLock {
            var current = read()
            let pinned = !current.contains(path)
            if pinned { current.insert(path) } else { current.remove(path) }
            try write(current)
            return pinned
        }
    }
    func set(_ path: String, pinned: Bool) throws {
        try lock.withLock {
            var current = read()
            guard current.contains(path) != pinned else { return }
            if pinned { current.insert(path) } else { current.remove(path) }
            try write(current)
        }
    }
    func rename(from oldPath: String, to newPath: String) throws {
        guard oldPath != newPath else { return }
        try lock.withLock {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
            var current = Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
            guard current.remove(oldPath) != nil else { return }
            current.insert(newPath)
            try write(current)
        }
    }
    private func read() -> Set<String> {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }
    private func write(_ paths: Set<String>) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(paths.sorted()).write(to: url, options: .atomic)
    }
}
