import Foundation

/// Byte-preserving line slicing: only the removal boundary and final newline are normalized.
struct CaptureMoveBlock {
    let text: String
    let heading: String?
    let remainder: Data

    init?(id: UUID, contents: Data) {
        guard let contents = String(data: contents, encoding: .utf8) else { return nil }
        var lines = contents.components(separatedBy: "\n")
        let identity = CaptureFormat.markerPrefix + id.uuidString.lowercased()
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix(identity + " ") || $0 == identity
        }) else { return nil }
        func blank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func headingLevel(_ line: String) -> Int? {
            let count = line.prefix(while: { $0 == "#" }).count
            return (1...6).contains(count) && line.dropFirst(count).hasPrefix(" ") ? count : nil
        }
        func marker(_ line: String) -> Bool {
            ["<!-- capture:", "<!-- note:", "<!-- subheading:"].contains { line.hasPrefix($0) }
        }
        let end = ((start + 1)..<lines.count).first { marker(lines[$0]) || headingLevel(lines[$0]) != nil } ?? lines.count
        var textEnd = end
        while textEnd > start && blank(lines[textEnd - 1]) { textEnd -= 1 }
        text = lines[start..<textEnd].joined(separator: "\n") + "\n"
        var headingIndex: Int?
        if start > 0 {
            for i in (0..<start).reversed() {
                if let level = headingLevel(lines[i]) {
                    if level == 3 { headingIndex = i; break }
                    if level <= 2 { break }
                }
            }
        }
        heading = headingIndex.map { String(lines[$0].dropFirst(4)).trimmingCharacters(in: .newlines) }
        var lower = start
        if let h = headingIndex, lines[(h + 1)..<start].allSatisfy(blank) {
            // Later captures under the same heading may sit past note blocks or user text.
            let sectionEnd = (end..<lines.count).first { headingLevel(lines[$0]) != nil } ?? lines.count
            if !lines[end..<sectionEnd].contains(where: { $0.hasPrefix(CaptureFormat.markerPrefix) }) { lower = h }
        }
        var upper = end
        while lower > 0 && blank(lines[lower - 1]) { lower -= 1 }
        while upper < lines.count && blank(lines[upper]) { upper += 1 }
        lines.replaceSubrange(lower..<upper, with: lower > 0 && upper < lines.count ? [""] : [])
        while lines.last.map(blank) == true { lines.removeLast() }
        remainder = Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func rewritingImages(from source: URL, to destination: URL) -> String {
        let regex = try! NSRegularExpression(pattern: #"!\[(?:\\.|[^\]\\])*\]\("#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        for match in matches.reversed() {
            guard let opening = Range(match.range, in: result) else { continue }
            let start = opening.upperBound
            guard start < result.endIndex else { continue }
            let angle = result[start] == "<"
            let linkStart = angle ? result.index(after: start) : start
            var cursor = linkStart
            var depth = 0
            var escaped = false
            var end: String.Index?
            while cursor < result.endIndex {
                let character = result[cursor]
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\n" { break }
                else if angle && character == ">" { end = cursor; break }
                else if !angle {
                    if character == "(" { depth += 1 }
                    else if character == ")" {
                        if depth == 0 { end = cursor; break }
                        depth -= 1
                    } else if character.isWhitespace { break }
                }
                cursor = result.index(after: cursor)
            }
            guard let end else { continue }
            let close = angle ? result.index(after: end) : end
            guard close < result.endIndex, result[close] == ")" else { continue }
            let link = String(result[linkStart..<end])
            guard !link.hasPrefix("/"), URLComponents(string: link)?.scheme == nil else { continue }
            let unescaped = link.replacingOccurrences(of: ##"\\([!"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])"##,
                                                      with: "$1", options: .regularExpression)
            let decoded = unescaped.removingPercentEncoding ?? unescaped
            let asset = source.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
            let relative = CaptureFormat.relativePath(from: destination.deletingLastPathComponent(), to: asset)
            let encoded = relative.split(separator: "/", omittingEmptySubsequences: false)
                .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
            result.replaceSubrange(linkStart..<end, with: encoded)
        }
        return result
    }
}
