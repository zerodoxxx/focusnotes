import Foundation

public enum NotePathScope: String, Codable, Sendable, Equatable {
    case vault
    case home
}

/// A validated, filename-safe name split into its destination root and path components.
public struct NotePathName: Sendable, Equatable {
    static let maximumPathDepth = 32
    static let maximumRelativePathBytes = 900

    public let scope: NotePathScope
    public let components: [String]

    public var relativePath: String { components.joined(separator: "/") }
    public var leafName: String { components[components.count - 1] }
    public var displayTitle: String {
        guard leafName.count > 60 else { return leafName }
        let end = leafName.index(leafName.startIndex, offsetBy: 60)
        var prefix = String(leafName[..<end])
        if !leafName[end].isWhitespace, let boundary = prefix.lastIndex(of: " ") {
            prefix = String(prefix[..<boundary])
        }
        return prefix.trimmingCharacters(in: .whitespaces) + "…"
    }

    init(scope: NotePathScope, components: [String]) {
        self.scope = scope
        self.components = components
    }
}

public enum NotePathNameError: Error, Sendable, Equatable {
    case emptyPath
    case invalidComponent
    case tooDeep
    case tooLong
}

public enum NoteTitle {
    /// Trims the title and collapses every run of whitespace to a single space.
    public static func cleanTitle(_ title: String) -> String {
        title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Comparison key for matching note titles.
    public static func matchKey(_ title: String) -> String {
        cleanTitle(title)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    /// Parses a note name into a safe relative path. A leading slash selects
    /// the user's home directory; an unprefixed name is relative to the vault.
    /// Each path component uses the same bounded filename sanitization as a
    /// single-component title.
    public static func pathName(for rawName: String) throws -> NotePathName {
        let cleanedName = cleanTitle(rawName)
        guard !cleanedName.contains("\0") else { throw NotePathNameError.invalidComponent }

        let scope: NotePathScope = cleanedName.hasPrefix("/") ? .home : .vault
        let unrooted = scope == .home ? String(cleanedName.dropFirst()) : cleanedName
        guard !unrooted.isEmpty else { throw NotePathNameError.emptyPath }

        let rawComponents = unrooted.split(separator: "/", omittingEmptySubsequences: false)
        guard rawComponents.count <= NotePathName.maximumPathDepth else { throw NotePathNameError.tooDeep }

        var components: [String] = []
        components.reserveCapacity(rawComponents.count)
        for rawComponent in rawComponents {
            let component = cleanTitle(String(rawComponent))
            guard !component.isEmpty, component != ".", component != ".." else {
                throw NotePathNameError.invalidComponent
            }
            components.append(fileStem(for: component))
        }
        guard let leafName = components.last, !leafName.hasPrefix("~$") else {
            throw NotePathNameError.invalidComponent
        }

        let relativePath = components.joined(separator: "/")
        guard relativePath.utf8.count <= NotePathName.maximumRelativePathBytes else {
            throw NotePathNameError.tooLong
        }
        return NotePathName(scope: scope, components: components)
    }

    /// File name stem (without `.md`) for a note title. Never empty.
    public static func fileStem(for title: String) -> String {
        var replaced = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                replaced.append("-")
            } else {
                replaced.append(scalar)
            }
        }

        var stem = String(replaced).trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.hasPrefix(".") {
            stem.removeFirst()
            stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // macOS limits a filename component to 255 UTF-8 bytes. Leave room for
        // `.md` and a collision suffix, in addition to the display-length cap.
        var bounded = ""
        for character in stem.prefix(120) {
            let piece = String(character)
            // Filesystem normalization also rejects long combining sequences,
            // even far below NAME_MAX. Count the canonical decomposition because
            // one mark (for example U+0344) can expand into multiple scalars.
            guard piece.decomposedStringWithCanonicalMapping.unicodeScalars.count <= 32,
                  bounded.utf8.count + piece.utf8.count <= 220 else { break }
            bounded += piece
        }
        // A single grapheme may contain hundreds of combining marks. Splitting
        // it can produce a Unicode sequence the filesystem refuses even within
        // its byte limit, so the usual Untitled fallback handles that case.
        stem = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Untitled" : stem
    }
}
