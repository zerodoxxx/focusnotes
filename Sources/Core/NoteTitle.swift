import Foundation

public enum NotePathScope: String, Codable, Sendable, Equatable {
    case vault
    case home
}

/// A validated, filename-safe name split into its destination root and path components.
public struct NotePathName: Sendable, Equatable {
    static let maximumPathDepth = 32
    @_spi(Checks) public static let maximumRelativePathBytes = 900
    @_spi(Checks) public static let maximumStemCharacters = 120
    @_spi(Checks) public static let maximumStemBytes = 220
    static let maximumStemScalarsPerCharacter = 32
    static let displayTitleLength = 60

    public let scope: NotePathScope
    public let components: [String]

    public var relativePath: String { components.joined(separator: "/") }
    public var leafName: String { components[components.count - 1] }
    public var displayTitle: String { NoteTitle.displayTitle(leafName) }

    private init(scope: NotePathScope, components: [String]) {
        self.scope = scope
        self.components = components
    }

    /// Creates a path value from already-sanitized filename components.
    /// User-facing names should normally go through a `NoteTitle` resolver;
    /// this factory is for trusted code that adds validated path components.
    static func validated(scope: NotePathScope, components: [String]) throws(NotePathNameError) -> NotePathName {
        guard !components.isEmpty else { throw NotePathNameError.emptyPath }
        guard components.count <= maximumPathDepth else { throw NotePathNameError.tooDeep }
        guard components.allSatisfy({ NoteTitle.isCanonicalComponent($0) }) else {
            throw NotePathNameError.invalidComponent
        }
        guard let leafName = components.last, !NoteTitle.isOwnerFileName(leafName) else {
            throw NotePathNameError.invalidComponent
        }
        guard components.joined(separator: "/").utf8.count <= maximumRelativePathBytes else {
            throw NotePathNameError.tooLong
        }
        return NotePathName(scope: scope, components: components)
    }
}

public enum NotePathNameError: Error, Sendable, Equatable {
    case emptyPath
    case invalidComponent
    case tooDeep
    case tooLong
}

public enum NoteTitle {
    public static func cleanTitle(_ title: String) -> String {
        title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func matchKey(_ title: String) -> String {
        cleanTitle(title)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    static func displayTitle(_ title: String) -> String {
        guard title.count > NotePathName.displayTitleLength else { return title }
        let end = title.index(title.startIndex, offsetBy: NotePathName.displayTitleLength)
        var prefix = String(title[..<end])
        if !title[end].isWhitespace, let boundary = prefix.lastIndex(of: " ") {
            prefix = String(prefix[..<boundary])
        }
        return prefix.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func leafName(of path: String) -> String {
        String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    }

    static func isDotComponent(_ component: String) -> Bool {
        component == "." || component == ".."
    }

    static func isOwnerFileName(_ name: String) -> Bool {
        name.hasPrefix("~$")
    }

    static func isCanonicalComponent(_ component: String) -> Bool {
        !component.isEmpty && component == fileStem(for: component)
    }

    static func containsSeparatorOrNull(_ name: String) -> Bool {
        name.contains("/") || name.contains("\\") || name.contains("\0")
    }

    /// Strictly parses a note name into a safe relative path. A leading slash selects
    /// the user's home directory; an unprefixed name is relative to the vault.
    /// Each path component uses the same bounded filename sanitization as a
    /// single-component title.
    public static func pathName(for rawName: String) throws(NotePathNameError) -> NotePathName {
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
            guard !component.isEmpty, !isDotComponent(component) else {
                throw NotePathNameError.invalidComponent
            }
            components.append(fileStem(for: component))
        }
        return try NotePathName.validated(scope: scope, components: components)
    }

    /// Resolves a user-entered destination name, preserving the legacy flat
    /// filename behavior for malformed relative slash forms.
    /// Typed notes pass `normalizingWhitespace: false` so `a  /  b` keeps resolving
    /// to the same flat file (`a  -  b.md`) as before.
    public static func resolvedPathName(for rawName: String, normalizingWhitespace: Bool = true) throws(NotePathNameError) -> NotePathName {
        do {
            let path = try pathName(for: rawName)
            if canFallBackToFlatName(rawName, error: nil) {
                return try flatPathName(for: rawName, normalizingWhitespace: normalizingWhitespace)
            }
            return path
        } catch {
            guard canFallBackToFlatName(rawName, error: error) else { throw error }
            return try flatPathName(for: rawName, normalizingWhitespace: normalizingWhitespace)
        }
    }

    private static func flatPathName(for rawName: String, normalizingWhitespace: Bool) throws(NotePathNameError) -> NotePathName {
        try NotePathName.validated(scope: .vault,
                                   components: [fileStem(for: normalizingWhitespace ? cleanTitle(rawName) : rawName)])
    }

    /// Returns whether a malformed or whitespace-qualified path should retain
    /// the legacy behavior of treating the full input as one flat filename.
    static func canFallBackToFlatName(_ rawName: String, error: NotePathNameError?) -> Bool {
        let cleanedName = cleanTitle(rawName)
        guard !cleanedName.hasPrefix("/"), !rawName.contains("\0") else { return false }
        if let error, error != .invalidComponent { return false }
        let components = rawName.split(separator: "/", omittingEmptySubsequences: false)
            .map { cleanTitle(String($0)) }
        guard !components.contains(where: { isDotComponent($0) }) else { return false }
        if let finalComponent = components.last(where: { !$0.isEmpty }),
           isOwnerFileName(fileStem(for: finalComponent)) { return false }

        let hasWhitespaceAroundSlash = rawName.range(of: #"\s/|/\s"#, options: .regularExpression) != nil
        if error == nil { return hasWhitespaceAroundSlash }
        return hasWhitespaceAroundSlash || rawName.hasSuffix("/") || rawName.contains("//")
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
        for character in stem.prefix(NotePathName.maximumStemCharacters) {
            let piece = String(character)
            // Filesystem normalization also rejects long combining sequences,
            // even far below NAME_MAX. Count the canonical decomposition because
            // one mark (for example U+0344) can expand into multiple scalars.
            guard piece.decomposedStringWithCanonicalMapping.unicodeScalars.count <= NotePathName.maximumStemScalarsPerCharacter,
                  bounded.utf8.count + piece.utf8.count <= NotePathName.maximumStemBytes else { break }
            bounded += piece
        }
        // A single grapheme may contain hundreds of combining marks. Splitting
        // it can produce a Unicode sequence the filesystem refuses even within
        // its byte limit, so the usual Untitled fallback handles that case.
        stem = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Untitled" : stem
    }
}
