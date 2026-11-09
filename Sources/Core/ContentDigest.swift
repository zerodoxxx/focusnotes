import CryptoKit
import Foundation

public enum ContentDigest {
    /// Lowercase hexadecimal SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
