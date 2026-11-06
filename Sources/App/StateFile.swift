import Foundation

/// App state-file rules: a missing file reads as nil, any other read error throws, writes are atomic JSON.
enum StateFile {
    static func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
    }
    static func writeJSON<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = JSONEncoder(), createDirectory: Bool = false) throws {
        if createDirectory {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
