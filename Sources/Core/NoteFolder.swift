import Foundation

/// A literal, safe vault-relative folder. Decoding applies the same validation as input.
public struct NoteFolder: Codable, Sendable, Equatable {
    // Reserve room for Sessions/, a full note stem, extension and suffix.
    static let maximumDepth = NotePathName.maximumPathDepth - 2
    static let maximumBytes = NotePathName.maximumRelativePathBytes - (NotePathName.maximumStemBytes + 20)

    public let rawValue: String
    public var components: [String] { rawValue.split(separator: "/").map(String.init) }
    public var sessionsRelativePath: String { "\(Vault.sessionsDirectoryName)/\(rawValue)" }

    public init(rawValue: String) throws {
        guard !rawValue.isEmpty else { throw NotePathNameError.emptyPath }
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= Self.maximumDepth else { throw NotePathNameError.tooDeep }
        guard rawValue.utf8.count <= Self.maximumBytes else {
            throw NotePathNameError.tooLong
        }
        guard parts.allSatisfy({ NoteTitle.isCanonicalComponent($0) && !$0.hasPrefix(".") && !$0.hasPrefix("~") &&
            $0 == NoteTitle.cleanTitle($0) }) else {
            throw NotePathNameError.invalidComponent
        }
        self.rawValue = rawValue
    }

    public func scoped(_ name: NotePathName) throws -> NotePathName {
        guard name.scope == .vault else { throw NotePathNameError.invalidComponent }
        return try NotePathName.validated(scope: .vault, components: components + name.components)
    }

    private enum CodingKeys: String, CodingKey { case rawValue }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .rawValue)
        do { try self.init(rawValue: rawValue) }
        catch {
            throw DecodingError.dataCorruptedError(forKey: .rawValue, in: container,
                                                   debugDescription: "Unsafe relative folder path.")
        }
    }
}
