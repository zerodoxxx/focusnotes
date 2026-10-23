import Foundation

public enum BlockKind: String, Sendable, Equatable {
    case text, image, loose, note
}

public struct ParsedBlock: Sendable, Equatable {
    public let captureID: UUID?
    public let kind: BlockKind
    public let createdAt: Date?
    public let sourceApp: String?
    public let windowTitle: String?
    public let body: String
    public let assetPath: String?
}

public struct ParsedNote: Sendable, Equatable {
    public let title: String
    public let blocks: [ParsedBlock]
}

/// A tolerant, read-only parser for the capture file format and ordinary Markdown.
public enum NoteParser {
    public static func parse(
        contents: String,
        notePath: String,
        titleFallback: String,
        calendar: Calendar,
        assetRootURL: URL? = nil
    ) -> ParsedNote {
        var lines = contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines[0].hasPrefix("\u{FEFF}") { lines[0].removeFirst() }
        var title = titleFallback
        var start = 0
        if lines[0].hasPrefix("# ") {
            let cleaned = NoteTitle.cleanTitle(String(lines[0].dropFirst(2)))
            if !cleaned.isEmpty { title = cleaned }
            start = 1
        }

        let boundaries = boundaries(in: lines, start: start, calendar: calendar)
        var blocks = looseBlocks(lines[start..<(boundaries.first?.line ?? lines.count)])
        for (offset, boundary) in boundaries.enumerated() {
            var bodyStart = boundary.marker + 1
            var bodyEnd = offset + 1 < boundaries.count ? boundaries[offset + 1].line : lines.count
            if bodyStart < bodyEnd, isBlank(lines[bodyStart]) { bodyStart += 1 }
            while bodyEnd > bodyStart, isBlank(lines[bodyEnd - 1]) { bodyEnd -= 1 }
            var body = lines[bodyStart..<bodyEnd].joined(separator: "\n")
            if boundary.id == nil {
                body = lines[boundary.line] + (body.isEmpty ? "" : "\n" + body)
                blocks += looseBlocks(body.components(separatedBy: "\n")[...])
                continue
            }
            let asset = boundary.isNote ? nil : imagePath(body, notePath: notePath, assetRootURL: assetRootURL)
            blocks.append(ParsedBlock(
                captureID: boundary.id, kind: boundary.isNote ? .note : (asset == nil ? .text : .image),
                createdAt: boundary.date, sourceApp: boundary.app, windowTitle: boundary.window,
                body: body, assetPath: asset
            ))
        }
        // A failed append may leave an earlier fragment with the same identity.
        // Prefer the last complete occurrence. Typed notes can intentionally have
        // an empty body after their first line becomes the file's title.
        var seen = Set<UUID>()
        blocks = blocks.reversed().filter { block in
            guard let id = block.captureID else { return true }
            guard !block.body.isEmpty || block.kind == .note else { return false }
            return seen.insert(id).inserted
        }.reversed()
        return ParsedNote(title: title, blocks: blocks)
    }

    private struct Boundary {
        let line: Int
        let marker: Int
        let id: UUID?
        let date: Date?
        let app: String?
        let window: String?
        let source: String?
        var isNote = false
    }

    private static func boundaries(in lines: [String], start: Int, calendar: Calendar) -> [Boundary] {
        let visible = Set(CaptureFormat.unfencedLines(lines))
        var source: String?
        var result: [Boundary] = []
        for index in visible.sorted() where index >= start {
            if lines[index].hasPrefix("### ") { source = String(lines[index].dropFirst(4)) }
            if lines[index].hasPrefix("<!-- subheading:"), lines[index].hasSuffix(" -->"),
               UUID(uuidString: String(lines[index].dropFirst(16).dropLast(4))) != nil,
               index > start, visible.contains(index - 1), CaptureFormat.atxHeading(lines[index - 1])?.level == 2 {
                result.append(Boundary(line: index - 1, marker: index, id: nil, date: nil, app: nil, window: nil, source: nil))
                continue
            }
            if let note = parseNoteMarker(lines[index]) {
                result.append(Boundary(line: index, marker: index, id: note.id, date: note.date,
                                       app: nil, window: nil, source: nil, isNote: true))
                continue
            }
            guard let marker = parseMarker(lines[index]) else { continue }
            let preceding = index > start && visible.contains(index - 1) && lines[index - 1].hasPrefix("### ")
            if marker.metadata == nil {
                guard preceding, let old = parseHeader(String(lines[index - 1].dropFirst(4)), calendar: calendar) else { continue }
                source = CaptureFormat.sourceHeading(CaptureSource(appName: old.app, windowTitle: old.window))
                result.append(Boundary(line: index - 1, marker: index, id: marker.id, date: old.date,
                                       app: old.app, window: old.window,
                                       source: CaptureFormat.sourceHeading(CaptureSource(appName: old.app, windowTitle: old.window))))
            } else if let metadata = marker.metadata {
                result.append(Boundary(line: preceding ? index - 1 : index, marker: index, id: marker.id,
                                       date: metadata.date, app: metadata.app, window: source, source: source))
            }
        }
        return result
    }

    /// Called only while NoteFile holds the append lock on the inode it read.
    static func needsSourceHeading(_ source: String, contents: String, calendar: Calendar) -> Bool {
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let last = boundaries(in: lines, start: 0, calendar: calendar).last(where: { $0.id != nil && !$0.isNote }),
              last.source == source else { return true }
        return CaptureFormat.unfencedLines(lines).contains { $0 > last.marker && CaptureFormat.atxHeading(lines[$0]) != nil }
    }

    /// The same source/heading rules as `boundaries`, carried forward across
    /// appends without retaining or reparsing the preceding note body.
    struct SourceHeadingState {
        private var fence = CaptureFormat.FenceState()
        private var pending = ""
        private var previousLine: String?
        private var source: String?
        private var lastCaptureSource: String?
        private var hasCapture = false
        private var headingAfterCapture = false

        var retainedByteCount: Int {
            pending.utf8.count + (previousLine?.utf8.count ?? 0) + (source?.utf8.count ?? 0) + (lastCaptureSource?.utf8.count ?? 0)
        }

        mutating func consume(_ text: String, calendar: Calendar) {
            let lines = (pending + text).components(separatedBy: "\n")
            pending = lines.last ?? ""
            for raw in lines.dropLast() {
                // A trailing CR is part of CRLF only once its newline arrives.
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                consumeLine(line, calendar: calendar)
            }
        }

        func needsHeading(_ requested: String, calendar: Calendar) -> Bool {
            var complete = self
            complete.consumeLine(pending, calendar: calendar)
            return !complete.hasCapture || complete.lastCaptureSource != requested || complete.headingAfterCapture
        }

        private mutating func consumeLine(_ line: String, calendar: Calendar) {
            guard fence.isVisible(line) else {
                previousLine = nil
                return
            }
            defer { previousLine = line.hasPrefix("### ") ? line : nil }
            if line.hasPrefix("### ") { source = String(line.dropFirst(4)) }
            if CaptureFormat.atxHeading(line) != nil { headingAfterCapture = true }
            guard let marker = NoteParser.parseMarker(line) else { return }
            if marker.metadata == nil {
                guard let previousLine, previousLine.hasPrefix("### "),
                      let old = NoteParser.parseHeader(String(previousLine.dropFirst(4)), calendar: calendar) else { return }
                source = CaptureFormat.sourceHeading(CaptureSource(appName: old.app, windowTitle: old.window))
            }
            lastCaptureSource = source
            hasCapture = true
            headingAfterCapture = false
        }
    }

    private static func parseNoteMarker(_ line: String) -> (id: UUID, date: Date)? {
        let prefix = "<!-- note:"
        guard line.hasPrefix(prefix), line.hasSuffix(CaptureFormat.markerSuffix) else { return nil }
        let value = String(line.dropFirst(prefix.count).dropLast(CaptureFormat.markerSuffix.count))
        guard value.count > 40, let id = UUID(uuidString: String(value.prefix(36))),
              value.dropFirst(36).hasPrefix(" at="),
              let date = ISO8601DateFormatter().date(from: String(value.dropFirst(40))) else { return nil }
        return (id, date)
    }

    private static func parseMarker(_ line: String) -> (id: UUID, metadata: (date: Date, app: String?)?)? {
        guard line.hasPrefix(CaptureFormat.markerPrefix), line.hasSuffix(CaptureFormat.markerSuffix) else { return nil }
        let value = String(line.dropFirst(CaptureFormat.markerPrefix.count).dropLast(CaptureFormat.markerSuffix.count))
        guard value.count >= 36, let id = UUID(uuidString: String(value.prefix(36))) else { return nil }
        if value.count == 36 { return (id, nil) }
        let rest = String(value.dropFirst(36))
        guard rest.hasPrefix(" at="), let appStart = rest.range(of: " app=\""), rest.hasSuffix("\"") else { return nil }
        let stamp = String(rest[rest.index(rest.startIndex, offsetBy: 4)..<appStart.lowerBound])
        guard let date = ISO8601DateFormatter().date(from: stamp) else { return nil }
        let app = CaptureFormat.unescapeMetadata(String(rest[appStart.upperBound...].dropLast()))
        return (id, (date, app.isEmpty ? nil : app))
    }

    private static func parseHeader(_ header: String, calendar: Calendar) -> (date: Date, app: String?, window: String?)? {
        let parts = header.components(separatedBy: " · ")
        let bytes = Array(parts[0].utf8)
        guard bytes.count == 16, bytes[4] == 45, bytes[7] == 45, bytes[10] == 32, bytes[13] == 58 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                guard bytes[index] >= 48, bytes[index] <= 57 else { return nil }
                result = result * 10 + Int(bytes[index] - 48)
            }
            return result
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16) else { return nil }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day,
              resolved.hour == hour, resolved.minute == minute else { return nil }
        func cleaned(_ value: String) -> String? {
            let value = NoteTitle.cleanTitle(value)
            return value.isEmpty ? nil : value
        }
        let app = parts.count > 1 ? cleaned(parts[1]) : nil
        let window = parts.count > 2 ? cleaned(parts.dropFirst(2).joined(separator: " · ")) : nil
        return (date, app, window)
    }

    private static func imagePath(_ body: String, notePath: String, assetRootURL: URL?) -> String? {
        var imageBody = body
        let sourcePrefix = "[Source](<"
        if body.hasPrefix(sourcePrefix), let separator = body.range(of: "\n\n") {
            let sourceLine = String(body[..<separator.lowerBound])
            let candidate = body[separator.upperBound...]
            if !sourceLine.contains("\n"), !candidate.contains("\n"), sourceLine.hasSuffix(">)") {
                let sourceURL = String(sourceLine.dropFirst(sourcePrefix.count).dropLast(2))
                if let canonicalSourceLine = CaptureFormat.sourceLink(for: CaptureSource(url: sourceURL)), canonicalSourceLine == sourceLine {
                    imageBody = String(candidate)
                }
            }
        }
        guard !imageBody.contains("\n"), imageBody.hasPrefix("![]("), imageBody.hasSuffix(")") else { return nil }
        let encodedLink = String(imageBody.dropFirst(4).dropLast())
        guard !encodedLink.isEmpty, !encodedLink.hasPrefix("/"), !encodedLink.contains(":"),
              !encodedLink.contains("\\"), !encodedLink.contains("?"), !encodedLink.contains("#"),
              !encodedLink.contains("\n") else { return nil }

        if let noteURL = absoluteNoteURL(notePath) {
            guard let assetRootURL,
                  let components = URLComponents(string: encodedLink), components.scheme == nil,
                  components.host == nil, components.query == nil, components.fragment == nil,
                  let resolved = URL(string: encodedLink, relativeTo: noteURL.deletingLastPathComponent())?.standardizedFileURL else {
                return nil
            }
            let root = assetRootURL.standardizedFileURL
            let rootComponents = root.pathComponents
            let resolvedComponents = resolved.pathComponents
            guard resolvedComponents.count > rootComponents.count,
                  Array(resolvedComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
            return ([Vault.assetsDirectoryName] + Array(resolvedComponents.dropFirst(rootComponents.count))).joined(separator: "/")
        }

        guard let link = encodedLink.removingPercentEncoding else { return nil }
        var components = notePath.split(separator: "/").dropLast().map(String.init)
        for part in link.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(String(part))
            }
        }
        guard components.count > 1, components[0] == Vault.assetsDirectoryName else { return nil }
        return components.joined(separator: "/")
    }

    private static func absoluteNoteURL(_ notePath: String) -> URL? {
        if notePath.hasPrefix("file://") {
            guard let url = URL(string: notePath), url.isFileURL else { return nil }
            return url
        }
        guard notePath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: notePath)
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    private static func looseBlocks(_ lines: ArraySlice<String>) -> [ParsedBlock] {
        var blocks: [ParsedBlock] = []
        var region: [String] = []
        func flush() {
            guard !region.isEmpty else { return }
            let body = region.joined(separator: "\n")
            var start = body.startIndex
            while start < body.endIndex {
                let end = body.index(start, offsetBy: 2_000, limitedBy: body.endIndex) ?? body.endIndex
                blocks.append(ParsedBlock(
                    captureID: nil, kind: .loose, createdAt: nil, sourceApp: nil, windowTitle: nil,
                    body: String(body[start..<end]), assetPath: nil
                ))
                start = end
            }
            region.removeAll(keepingCapacity: true)
        }
        for line in lines {
            if isBlank(line) { flush() } else { region.append(line) }
        }
        flush()
        return blocks
    }
}
