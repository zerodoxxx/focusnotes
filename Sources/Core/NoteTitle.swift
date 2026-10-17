import Foundation

public enum NoteTitle {
    /// Trims the title and collapses every run of whitespace to a single space.
    public static func cleanTitle(_ title: String) -> String {
        title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Comparison key for matching a heading to a note title.
    public static func matchKey(_ title: String) -> String {
        cleanTitle(title)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    /// True when `query` names a note, by its title or its file stem. An empty query names nothing.
    public static func names(_ query: String, title: String, stem: String) -> Bool {
        let cleaned = cleanTitle(query)
        guard !cleaned.isEmpty else { return false }
        return matchKey(cleaned) == matchKey(title)
            || matchKey(fileStem(for: cleaned)) == matchKey(stem)
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
