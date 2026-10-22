import Foundation

/// A literal, safe vault-relative folder. Decoding applies the same validation as input.
public struct NoteFolder: Codable, Sendable, Equatable {
    public let rawValue: String
    public var components: [String] { rawValue.split(separator: "/").map(String.init) }

    public init(rawValue: String) throws {
        guard !rawValue.isEmpty else { throw NotePathNameError.emptyPath }
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= NotePathName.maximumPathDepth - 2 else { throw NotePathNameError.tooDeep }
        // Reserve room for Sessions/, a full note stem, extension and suffix.
        guard rawValue.utf8.count <= NotePathName.maximumRelativePathBytes - 240 else {
            throw NotePathNameError.tooLong
        }
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasPrefix("~") &&
            $0 == NoteTitle.fileStem(for: $0) && $0 == NoteTitle.cleanTitle($0) }) else {
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
