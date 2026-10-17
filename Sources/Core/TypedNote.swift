import Foundation

/// A root note's display title and body, derived without rewriting the draft.
public struct TypedNote: Sendable {
    public let title: String
    public let body: String
    /// True when the first line has no text, so the title is a creation stamp.
    public let isGeneratedTitle: Bool

    public init(markdown: String, createdAt: Date, calendar: Calendar) {
        let withoutComments = Self.replace(#"<!--[\s\S]*?(?:-->|$)"#, in: markdown, with: "")
        let first = withoutComments.components(separatedBy: .newlines).first {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        } ?? ""
        let stripped = Self.strip(first)
        isGeneratedTitle = stripped.isEmpty
        if stripped.isEmpty {
            title = "Note " + CaptureFormat.localStamp(createdAt, pattern: "yyyy-MM-dd HH.mm", calendar: calendar)
        } else if stripped.count > 60 {
            let end = stripped.index(stripped.startIndex, offsetBy: 60)
            var prefix = String(stripped[..<end])
            if !stripped[end].isWhitespace, let boundary = prefix.lastIndex(of: " ") {
                prefix = String(prefix[..<boundary])
            }
            title = prefix.trimmingCharacters(in: .whitespaces) + "…"
        } else {
            title = stripped
        }

        // Only the physical first line is eligible. Lists, quotes and code are
        // meaningful body content even when their text becomes the note title.
        let line = markdown.components(separatedBy: .newlines).first ?? ""
        let structural = #"^(?:[ \t]*(?:[-*+][ \t]+|[0-9]+[.)][ \t]+|>|`|~{3})|\t| {4})"#
        if !stripped.isEmpty, Self.strip(line) == title,
           line.range(of: structural, options: .regularExpression) == nil {
            if let newline = markdown.rangeOfCharacter(from: .newlines) {
                var remainder = String(markdown[newline.upperBound...])
                if markdown[newline.lowerBound] == "\r", remainder.hasPrefix("\n") { remainder.removeFirst() }
                body = CaptureFormat.noteBody(remainder)
            } else { body = "" }
        } else { body = CaptureFormat.noteBody(markdown) }
    }

    private static func strip(_ line: String) -> String {
        var text = replace(#"<!--[\s\S]*?(?:-->|$)"#, in: line, with: "")
        let prefix = #"^[ \t]*(?:#+[ \t]+|[-*+][ \t]+(?:\[[ xX]\][ \t]*)?|[0-9]+[.)][ \t]+|>[ \t]*)"#
        while true {
            let stripped = replace(prefix, in: text, with: "")
            if stripped == text { break }
            text = stripped
        }
        text = replace(#"[ \t]+#+[ \t]*$"#, in: text, with: "")
        text = replace(#"!?\[([^\]]*)\]\([^)]*\)"#, in: text, with: "$1")
        for _ in 0..<2 {
            text = replace(#"(\*\*|__|~~)(?=\S)(.+?)\1"#, in: text, with: "$2")
            text = replace(#"(?<![\w*_])([*_])(?=\S)(.+?)\1(?![\w*_])"#, in: text, with: "$2")
        }
        text = replace(#"`+"#, in: text, with: "")
        return NoteTitle.cleanTitle(text)
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
