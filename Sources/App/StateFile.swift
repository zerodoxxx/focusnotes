import Foundation
import os

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
    /// Keeps undecodable state with its siblings instead of deleting it. A name collision gets a
    /// unique stem so an earlier quarantined file is never overwritten.
    static func quarantine(_ files: [URL], stem: String, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let targetStem = FileManager.default.fileExists(atPath: directory.appendingPathComponent(stem + ".json").path)
            ? stem + "-" + UUID().uuidString.lowercased() : stem
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(targetStem + "." + file.pathExtension)) }
            catch {
                Logger(subsystem: AppInfo.bundleIdentifier, category: "journal")
                    .error("State file quarantine failed (\(AppErrorLog.summary(error), privacy: .public))")
                throw error
            }
        }
    }
}
