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
        let sourceLink = sourceLink(for: capture.source).map { $0 + "\n\n" } ?? ""
        return heading + marker + "\n\n" + sourceLink + body + "\n"
    }

    /// A source URL is serialized only when it is a well-formed absolute HTTP(S) URL.
    /// Angle brackets keep Markdown syntax out of the destination; encoded parentheses
    /// also keep the editor's current link recognizer from ending the destination early.
    static func sourceLink(for source: CaptureSource) -> String? {
        guard let value = source.url, !value.isEmpty else { return nil }
        let scalars = Array(value.unicodeScalars)
        guard scalars.allSatisfy({
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
            $0.properties.generalCategory != .control &&
            $0.properties.generalCategory != .format &&
            $0.properties.generalCategory != .lineSeparator &&
            $0.properties.generalCategory != .paragraphSeparator
        }) else { return nil }

        func allowedPercentEscapes() -> Bool {
            func isHex(_ byte: UInt8) -> Bool {
                (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
            }
            let bytes = Array(value.utf8)
            var index = 0
            while index < bytes.count {
                guard bytes[index] == 0x25 else {
                    index += 1
                    continue
                }
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 3
            }
            return true
        }

        func isUnreservedOrSubDelimiter(_ scalar: Unicode.Scalar) -> Bool {
            let value = scalar.value
            if (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) { return true }
            return "-._~!$&'()*+,;=".unicodeScalars.contains(scalar)
        }

        func isValidComponent(_ text: Substring, allowColon: Bool, allowAt: Bool,
                              allowSlash: Bool, allowQuestion: Bool, allowMarkdownEscapes: Bool) -> Bool {
            text.unicodeScalars.allSatisfy { scalar in
                if isUnreservedOrSubDelimiter(scalar) || scalar.value > 0x7F { return true }
                if scalar == "%" { return true }
                if allowColon && scalar == ":" { return true }
                if allowAt && scalar == "@" { return true }
                if allowSlash && scalar == "/" { return true }
                if allowQuestion && scalar == "?" { return true }
                if allowMarkdownEscapes && (scalar == "<" || scalar == ">" || scalar == "\\") { return true }
                return false
            }
        }

        guard allowedPercentEscapes(),
              let schemeEnd = value.firstIndex(of: ":") else { return nil }
        let scheme = value[..<schemeEnd].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let authorityStart = value.index(after: schemeEnd)
        guard value[authorityStart...].hasPrefix("//") else { return nil }
        let hostStart = value.index(authorityStart, offsetBy: 2)
        let authorityEnd = value[hostStart...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? value.endIndex
        let authority = value[hostStart..<authorityEnd]
        guard !authority.isEmpty else { return nil }

        let atCount = authority.filter { $0 == "@" }.count
        guard atCount <= 1 else { return nil }
        let hostPort: Substring
        if atCount == 1, let at = authority.firstIndex(of: "@") {
            guard isValidComponent(authority[..<at], allowColon: true, allowAt: false,
                                   allowSlash: false, allowQuestion: false, allowMarkdownEscapes: true) else { return nil }
            hostPort = authority[authority.index(after: at)...]
        } else {
            hostPort = authority
        }
        guard !hostPort.isEmpty else { return nil }

        let port: Substring?
        if hostPort.first == "[" {
            guard let close = hostPort.firstIndex(of: "]"), close > hostPort.index(after: hostPort.startIndex) else { return nil }
            let literal = hostPort[hostPort.index(after: hostPort.startIndex)..<close]
            guard literal.contains(":"), literal.unicodeScalars.allSatisfy({
                let value = $0.value
                return (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value) || $0 == ":" || $0 == "." || $0 == "%"
            }) else { return nil }
            let suffix = hostPort[hostPort.index(after: close)...]
            if suffix.isEmpty { port = nil }
            else if suffix.first == ":" { port = suffix.dropFirst() }
            else { return nil }
        } else {
            let colons = hostPort.indices.filter { hostPort[$0] == ":" }
            guard colons.count <= 1 else { return nil }
            if let colon = colons.first {
                port = hostPort[hostPort.index(after: colon)...]
                let host = hostPort[..<colon]
                guard !host.isEmpty, isValidComponent(host, allowColon: false, allowAt: false,
                    allowSlash: false, allowQuestion: false, allowMarkdownEscapes: false) else { return nil }
            } else {
                port = nil
                guard isValidComponent(hostPort, allowColon: false, allowAt: false,
                    allowSlash: false, allowQuestion: false, allowMarkdownEscapes: false) else { return nil }
            }
        }
        if let port {
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(port), number <= 65_535 else { return nil }
        }

        let remainder = value[authorityEnd...]
        let fragmentStart = remainder.firstIndex(of: "#")
        let beforeFragment = fragmentStart.map { remainder[..<$0] } ?? remainder
        let fragment = fragmentStart.map { remainder[remainder.index(after: $0)..<remainder.endIndex] }
        let queryStart = beforeFragment.firstIndex(of: "?")
        let path = queryStart.map { beforeFragment[..<$0] } ?? beforeFragment
        let query = queryStart.map { beforeFragment[beforeFragment.index(after: $0)...] }
        guard (path.isEmpty || path.first == "/"),
              isValidComponent(path, allowColon: true, allowAt: true, allowSlash: true,
                               allowQuestion: false, allowMarkdownEscapes: true),
              query.map({ isValidComponent($0, allowColon: true, allowAt: true, allowSlash: true,
                                           allowQuestion: true, allowMarkdownEscapes: true) }) ?? true,
              fragment.map({ isValidComponent($0, allowColon: true, allowAt: true, allowSlash: true,
                                              allowQuestion: true, allowMarkdownEscapes: true) }) ?? true else { return nil }

        let encodedTail = String(value[schemeEnd...])
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
            .replacingOccurrences(of: "\\", with: "%5C")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        let normalized = scheme + encodedTail
        guard let components = URLComponents(string: normalized),
              components.scheme?.lowercased() == scheme,
              let host = components.host, !host.isEmpty,
              components.url != nil else { return nil }
        return "[Source](<\(normalized)>)"
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
