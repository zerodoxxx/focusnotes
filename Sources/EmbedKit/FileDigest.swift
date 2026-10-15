import CryptoKit
import Foundation

public enum FileDigest {
    /// Streams the file in 1 MiB chunks so large model files are never fully loaded into memory.
    /// Returns the lowercase hexadecimal SHA-256 digest.
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
