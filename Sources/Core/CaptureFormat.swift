import Foundation

/// Markdown format for captures. This is a file-format contract: changes break existing notes.
public enum CaptureFormat {
    public static let markerPrefix = "<!-- capture:"
    public static let markerSuffix = " -->"

    private static let separator = "\u{00B7}"
    private static let ellipsis = "\u{2026}"
    private static let windowTitleLimit = 80

    public static func noteHeader(title: String) -> String {
        "# \(title)\n"
    }

    /// One capture block, ending with a single newline.
    /// - Parameters:
    ///   - noteRelativeDir: the note's folder relative to the vault root (`""` for root notes, `"Sessions"` for session notes).
    public static func block(for capture: Capture, noteRelativeDir: String, calendar: Calendar,
                             includeSourceHeading: Bool = true, assetPathPrefix: String? = nil) -> String {
        if case .subheading(let text) = capture.content {
            return "## \(cleanSubheading(text))\n<!-- subheading:\(capture.id.uuidString.lowercased()) -->\n"
        }
        if case .note(let text) = capture.content {
            let stamp = localStamp(capture.createdAt, pattern: "yyyy-MM-dd'T'HH:mm:ssXXX", calendar: calendar)
            return "<!-- note:\(capture.id.uuidString.lowercased()) at=\(stamp) -->\n\n" + noteBody(text) + "\n"
        }
        let body: String
        switch capture.content {
        case .text(let text):
            let trimmed = textBody(text)
            body = trimmed.isEmpty ? "(empty)" : trimmed
        case .image(let assetPath):
            body = imageBody(assetPath: assetPath, noteRelativeDir: noteRelativeDir, assetPathPrefix: assetPathPrefix)
        case .subheading, .note: preconditionFailure("handled above")
        }
        let app = escapeMetadata(cleanPart(capture.source.appName))
        let stamp = localStamp(capture.createdAt, pattern: "yyyy-MM-dd'T'HH:mm:ssXXX", calendar: calendar)
        let marker = markerPrefix + capture.id.uuidString.lowercased() + " at=\(stamp) app=\"\(app)\"" + markerSuffix
        let heading = includeSourceHeading ? "### \(sourceHeading(capture.source))\n" : ""
        return heading + marker + "\n\n" + body + "\n"
    }

    public static func sourceHeading(_ source: CaptureSource) -> String {
        var window = cleanPart(source.windowTitle)
        for browser in ["Mozilla Firefox", "Google Chrome", "Brave", "Safari", "Firefox", "Microsoft Edge"] {
            for separator in [" — ", " - ", " – "] {
                let suffix = separator + browser
                if window.hasSuffix(suffix) { window.removeLast(suffix.count) }
            }
        }
        window = truncated(NoteTitle.cleanTitle(window), limit: windowTitleLimit)
        if !window.isEmpty { return window }
        let app = cleanPart(source.appName)
        return app.isEmpty ? "Unknown source" : app
    }

    /// Preserve every internal byte, including leading whitespace and Markdown hard breaks.
    public static func noteBody(_ text: String) -> String {
        String(text.dropLast(text.reversed().prefix(while: \.isWhitespace).count))
    }

    public static func cleanSubheading(_ text: String) -> String {
        NoteTitle.cleanTitle(String(NoteTitle.cleanTitle(text).drop(while: { $0 == "#" || $0.isWhitespace })))
    }

    private static func escapeMetadata(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "-", with: "&#45;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescapeMetadata(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#45;", with: "-")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Markdown structure ignores fenced code, including longer and tilde fences.
    static func unfencedLines(_ lines: [String]) -> [Int] {
        var state = FenceState()
        var result: [Int] = []
        for (index, line) in lines.enumerated() {
            if state.isVisible(line) { result.append(index) }
        }
        return result
    }

    /// Shared by full parsing and incremental append source grouping.
    struct FenceState {
        private var fence: (Character, Int)?

        mutating func isVisible(_ line: String) -> Bool {
            let indentation = line.prefix(while: { $0 == " " }).count
            let text = line.dropFirst(min(indentation, 3))
            if indentation <= 3, let first = text.first, first == "`" || first == "~" {
                let count = text.prefix(while: { $0 == first }).count
                let rest = text.dropFirst(count)
                if let current = fence {
                    if first == current.0, count >= current.1, rest.allSatisfy(\.isWhitespace) { fence = nil }
                } else if count >= 3, first != "`" || !rest.contains("`") { fence = (first, count) }
                if count >= 3 { return false }
            }
            return fence == nil
        }
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let text = line.dropFirst(indentation)
        let level = text.prefix(while: { $0 == "#" }).count
        let rest = text.dropFirst(level)
        guard (1...6).contains(level), rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return (level, String(rest).trimmingCharacters(in: .whitespaces))
    }

    /// Formats a date in the calendar's time zone with a fixed en_US_POSIX pattern.
    /// Used by the note writer and session store as well, so every date stamp shares one rule.
    static func localStamp(_ date: Date, pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func cleanPart(_ value: String?) -> String {
        guard let value else { return "" }
        let replaced = value.replacingOccurrences(of: separator, with: "-")
        return NoteTitle.cleanTitle(replaced)
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + ellipsis
    }

    private static func textBody(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let first = lines.first, isBlank(first) {
            lines.removeFirst()
        }
        while let last = lines.last, isBlank(last) {
            lines.removeLast()
        }
        var body = lines.joined(separator: "\n")
        while let last = body.last, last.isWhitespace {
            body.removeLast()
        }
        return body
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns a relative path from `directory` to `target`, without reading either path.
    /// This supports notes outside the vault while keeping generated links relative.
    static func relativePath(from directory: URL, to target: URL) -> String {
        let source = directory.standardizedFileURL.pathComponents
        let destination = target.standardizedFileURL.pathComponents
        var common = 0
        while common < source.count, common < destination.count, source[common] == destination[common] {
            common += 1
        }
        return (Array(repeating: "..", count: source.count - common) + Array(destination.dropFirst(common)))
            .joined(separator: "/")
    }

    private static func imageBody(assetPath: String, noteRelativeDir: String, assetPathPrefix: String?) -> String {
        let path: String
        if let assetPathPrefix {
            let prefix = assetPathPrefix.isEmpty ? [] : assetPathPrefix.split(separator: "/").map(String.init)
            let suffix = assetPath.split(separator: "/").map(String.init)
            path = (prefix + suffix).joined(separator: "/")
        } else {
            let depth = noteRelativeDir.split(separator: "/").count
            path = String(repeating: "../", count: depth) + assetPath
        }
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters) ?? String($0) }
            .joined(separator: "/")
        return "![](\(encoded))"
    }

    private static let pathSegmentCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}
