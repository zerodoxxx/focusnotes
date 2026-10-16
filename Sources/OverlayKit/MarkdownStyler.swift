import AppKit

/// Attributes only: the underlying Markdown and all UTF-16 offsets stay intact.
@MainActor
public enum MarkdownStyler {
    public typealias Span = (range: NSRange, attributes: [NSAttributedString.Key: Any])
    /// A layout decoration, independent of font/color runs within a code block.
    public static let fencedCodeBlock = NSAttributedString.Key("OverlayKit.fencedCodeBlock")
    public static let inlineCode = NSAttributedString.Key("OverlayKit.inlineCode")
    /// The fence state after a logical line, cached on its characters for incremental restyling.
    public static let fenceStateAfter = NSAttributedString.Key("OverlayKit.fenceStateAfter")

    public struct FenceState: Hashable, Sendable {
        fileprivate let character: unichar
        fileprivate let length: Int
        public static let outside = FenceState(character: 0, length: 0)
        public var isOpen: Bool { length > 0 }
        fileprivate init(character: unichar, length: Int) { self.character = character; self.length = length }
    }

    public struct ScanResult {
        public let spans: [Span]
        /// The complete physical lines whose old attributes should be replaced by `spans`.
        public let processedRange: NSRange
    }

    public static let syntax = NSAttributedString.Key("OverlayKit.markdownSyntax")
    public static let element = NSAttributedString.Key("OverlayKit.markdownElement")
    public static let bullet = NSAttributedString.Key("OverlayKit.bullet")
    public static let task = NSAttributedString.Key("OverlayKit.task")
    public static let taskIndent = NSAttributedString.Key("OverlayKit.taskIndent")
    public static let quote = NSAttributedString.Key("OverlayKit.quote")
    public static let rawParagraph = NSAttributedString.Key("OverlayKit.rawParagraph")
    public static let previewParagraph = NSAttributedString.Key("OverlayKit.previewParagraph")

    public enum ElementKind: Hashable {
        case blockMarker
        case headingLine
        case inlineSpan
    }

    public struct Element: Hashable {
        public let range: NSRange
        public let kind: ElementKind

        public init(range: NSRange, kind: ElementKind) {
            self.range = range
            self.kind = kind
        }
    }

    /// NSTextStorage moves an attribute run when text is inserted or removed before it,
    /// but it cannot adjust the absolute range stored inside an Element value. Rebase just
    /// those semantic runs in the untouched suffix; Markdown parsing stays local to the edit.
    public static func rebaseElementRanges(in storage: NSMutableAttributedString, after location: Int, by delta: Int) {
        guard delta != 0, storage.length > 0 else { return }
        let start = min(max(0, location), storage.length)
        guard start < storage.length else { return }
        // Bound temporary storage even for a huge suffix with many tiny Markdown spans.
        let batchSize = 4_096
        var batchStart = start
        storage.beginEditing()
        while batchStart < storage.length {
            let batch = NSRange(location: batchStart, length: min(batchSize, storage.length - batchStart))
            var updates: [(NSRange, Element)] = []
            storage.enumerateAttribute(element, in: batch) { value, run, _ in
                guard let value = value as? Element else { return }
                let shifted = value.range.location + delta
                guard shifted >= 0 else { return }
                let affected = NSIntersectionRange(run, batch)
                guard affected.length > 0 else { return }
                updates.append((affected, Element(range: NSRange(location: shifted, length: value.range.length), kind: value.kind)))
            }
            if !updates.isEmpty {
                for (run, value) in updates { storage.addAttribute(element, value: value, range: run) }
            }
            batchStart = NSMaxRange(batch)
        }
        storage.endEditing()
    }

    public static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = OverlayTheme.editorLineHeightMultiple
        return [.font: OverlayTheme.editorFont, .foregroundColor: OverlayTheme.textColor,
                .paragraphStyle: paragraph]
    }

    /// Large documents restrict attribute generation to edited paragraphs. Fence
    /// context is scanned as plain lines, without running inline expressions there.
    public static func styles(_ text: String, in requested: NSRange? = nil) -> [Span] {
        scanCore(text, outputRange: requested, from: 0, startingFence: .outside, stopAfterLine: nil).spans
    }

    /// Restyle from an already-known fence boundary. The caller can stop once the new
    /// outgoing fence state matches the cached state for an unchanged suffix line.
    public static func scan(_ text: String, from location: Int, startingFence: FenceState,
                            stopAfterLine: ((NSRange, FenceState) -> Bool)? = nil) -> ScanResult {
        scanCore(text, outputRange: nil, from: location, startingFence: startingFence, stopAfterLine: stopAfterLine)
    }

    private static func scanCore(_ text: String, outputRange requested: NSRange?, from requestedStart: Int,
                                 startingFence initialFence: FenceState,
                                 stopAfterLine: ((NSRange, FenceState) -> Bool)?) -> ScanResult {
        let source = text as NSString
        guard source.length > 0 else { return ScanResult(spans: [], processedRange: .init(location: 0, length: 0)) }
        let startProbe = min(max(0, requestedStart), source.length - 1)
        let start = source.lineRange(for: NSRange(location: startProbe, length: 0)).location
        let target = requested ?? NSRange(location: start, length: source.length - start)
        var spans: [Span] = []
        var fence: FenceState = initialFence
        var processedEnd = start
        func add(_ range: NSRange, _ attributes: [NSAttributedString.Key: Any]) {
            let intersection = NSIntersectionRange(range, target)
            if intersection.length > 0 { spans.append((intersection, attributes)) }
        }
        var expressions: [String: NSRegularExpression] = [:]
        func matches(_ pattern: String, _ range: NSRange) -> [NSTextCheckingResult] {
            let regex: NSRegularExpression
            if let cached = expressions[pattern] { regex = cached }
            else {
                guard let compiled = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
                expressions[pattern] = compiled; regex = compiled
            }
            return regex.matches(in: text, range: range)
        }
        var offset = start
        while offset < source.length {
            let line = source.lineRange(for: NSRange(location: offset, length: 0))
            let value = source.substring(with: line) as NSString
            let trimmed = value.trimmingCharacters(in: .newlines) as NSString
            var indent = 0
            while indent < trimmed.length, trimmed.character(at: indent) == 32 { indent += 1 }
            var run = 0
            let first: unichar = indent < trimmed.length ? trimmed.character(at: indent) : 0
            if indent <= 3, first == 96 || first == 126 {
                while indent + run < trimmed.length, trimmed.character(at: indent + run) == first { run += 1 }
            }
            let rest = trimmed.substring(from: min(trimmed.length, indent + run))
            var fenceLine = false
            if fence.isOpen {
                if first == fence.character, run >= fence.length,
                   rest.trimmingCharacters(in: .whitespaces).isEmpty { fence = .outside; fenceLine = true }
            } else if run >= 3, first != 96 || !rest.contains("`") {
                fence = FenceState(character: first, length: run); fenceLine = true
            }
            let outgoingFence = fence
            add(line, [fenceStateAfter: outgoingFence])
            if fence.isOpen || fenceLine {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineHeightMultiple = OverlayTheme.editorLineHeightMultiple
                paragraph.firstLineHeadIndent = OverlayTheme.codeBlockInset
                paragraph.headIndent = OverlayTheme.codeBlockInset
                paragraph.tailIndent = -OverlayTheme.codeBlockInset
                add(line, [.font: OverlayTheme.editorCodeFont, .paragraphStyle: paragraph, fencedCodeBlock: true])
                if fenceLine { add(line, [.foregroundColor: OverlayTheme.tertiaryColor]) }
                processedEnd = NSMaxRange(line)
                offset = processedEnd
                if stopAfterLine?(line, outgoingFence) == true { break }
                continue
            }
            guard NSIntersectionRange(line, target).length > 0 else {
                processedEnd = NSMaxRange(line)
                offset = processedEnd
                if stopAfterLine?(line, outgoingFence) == true { break }
                continue
            }
            var lineFont = OverlayTheme.editorFont
            if let heading = matches("^#+ ", line).first {
                let level = heading.range.length - 1
                lineFont = OverlayTheme.editorHeadingFonts[min(level, 4) - 1]
                add(line, [.font: lineFont, .foregroundColor: OverlayTheme.editorHeadingColor])
                let contentLength = (trimmed as NSString).length
                let element = Element(range: NSRange(location: line.location, length: contentLength), kind: .headingLine)
                add(heading.range, [.foregroundColor: OverlayTheme.tertiaryColor, syntax: true, Self.element: element])
            }
            if let list = matches(#"^([ \t]*)([-*+] (?:\[[ xX]\] )?|[0-9]+\. )"#, line).first {
                let marker = NSRange(location: line.location, length: list.range.length)
                let itemMarker = list.range(at: 2)
                let blockElement = Element(range: itemMarker, kind: .blockMarker)
                add(itemMarker, [Self.element: blockElement])
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineHeightMultiple = OverlayTheme.editorLineHeightMultiple
                var displayedMarker = source.substring(with: marker)
                let first = source.character(at: itemMarker.location)
                if first == 45 || first == 42 || first == 43 {
                    add(NSRange(location: itemMarker.location, length: 1), [bullet: true, .font: OverlayTheme.editorBulletFont])
                    displayedMarker = (displayedMarker as NSString).replacingCharacters(in: NSRange(location: itemMarker.location - marker.location, length: 1), with: OverlayTheme.editorBullet)
                }
                paragraph.headIndent = (displayedMarker as NSString).size(withAttributes: [.font: OverlayTheme.editorFont]).width
                if first == 45 || first == 42 || first == 43 {
                    let bullet = OverlayTheme.editorBullet as NSString
                    paragraph.headIndent += bullet.size(withAttributes: [.font: OverlayTheme.editorBulletFont]).width - bullet.size(withAttributes: [.font: OverlayTheme.editorFont]).width
                }
                add(line, [.paragraphStyle: paragraph])
                add(marker, [.foregroundColor: OverlayTheme.secondaryColor])
                let markerText = source.substring(with: marker)
                if markerText.contains("[") {
                    let checked = markerText.lowercased().contains("[x]")
                    let indentation = (source.substring(with: list.range(at: 1)) as NSString).size(withAttributes: [.font: OverlayTheme.editorFont]).width
                    let preview = paragraph.mutableCopy() as! NSMutableParagraphStyle
                    // Leading Markdown spaces remain visible while the task marker is hidden.
                    // They already move the first-line text, so only wrapped lines need the
                    // explicit list indentation in addition to the checkbox and its gap.
                    preview.firstLineHeadIndent = OverlayTheme.editorCheckboxSize + OverlayTheme.editorCheckboxGap
                    preview.headIndent = indentation + preview.firstLineHeadIndent
                    add(line, [rawParagraph: paragraph, previewParagraph: preview])
                    add(itemMarker, [syntax: true, Self.element: blockElement, task: checked, taskIndent: indentation])
                }
                if markerText.lowercased().contains("[x]") {
                    add(NSRange(location: NSMaxRange(marker), length: NSMaxRange(line) - NSMaxRange(marker)),
                        [.foregroundColor: OverlayTheme.secondaryColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue])
                }
            } else if let quote = matches("^> ", line).first {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineHeightMultiple = OverlayTheme.editorLineHeightMultiple
                paragraph.headIndent = OverlayTheme.editorQuoteIndent
                let preview = paragraph.mutableCopy() as! NSMutableParagraphStyle
                preview.firstLineHeadIndent = OverlayTheme.editorQuoteIndent
                let blockElement = Element(range: quote.range, kind: .blockMarker)
                add(line, [.foregroundColor: OverlayTheme.secondaryColor, .paragraphStyle: paragraph, Self.quote: true,
                           rawParagraph: paragraph, previewParagraph: preview])
                add(quote.range, [.foregroundColor: OverlayTheme.tertiaryColor, syntax: true, Self.element: blockElement])
            }

            // Mask inline code and links before emphasis, so punctuation in a URL
            // or a code sample never becomes an emphasis delimiter.
            let codes = matches(#"(`+)([^`\r\n]+)\1"#, line)
            let links = matches(#"\[([^\]\r\n]+)\]\(([^)\r\n]+)\)|https?://[^\s<>]+"#, line)
            let protected = codes.map(\.range) + links.map(\.range)
            func emphasis(_ pattern: String, _ attrs: [NSAttributedString.Key: Any]) {
                for match in matches(pattern, line) where !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    add(match.range(at: 2), attrs)
                    let element = Element(range: match.range, kind: .inlineSpan)
                    add(match.range(at: 1), [.foregroundColor: OverlayTheme.tertiaryColor, syntax: true, Self.element: element])
                    let end = NSMaxRange(match.range(at: 2))
                    add(NSRange(location: end, length: NSMaxRange(match.range) - end),
                        [.foregroundColor: OverlayTheme.tertiaryColor, syntax: true, Self.element: element])
                }
            }
            emphasis(#"(\*\*|__)(?=\S)(.+?\S|\S)\1"#, [.font: NSFont.systemFont(ofSize: lineFont.pointSize, weight: .semibold)])
            let italic = NSFont(descriptor: lineFont.fontDescriptor.withSymbolicTraits(lineFont.fontDescriptor.symbolicTraits.union(.italic)), size: lineFont.pointSize) ?? lineFont
            emphasis(#"(?<![\w*_])(\*|_)(?=\S)([^*_\r\n]+?\S|[^\s*_])\1(?![\w*_])"#, [.font: italic])
            emphasis(#"(~~)(?=\S)(.+?\S|\S)\1"#, [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
            for code in codes {
                add(code.range, [.font: OverlayTheme.editorCodeFont, inlineCode: true])
                let element = Element(range: code.range, kind: .inlineSpan)
                add(code.range(at: 1), [.foregroundColor: OverlayTheme.tertiaryColor, syntax: true, Self.element: element])
                add(NSRange(location: NSMaxRange(code.range(at: 2)), length: code.range(at: 1).length),
                    [.foregroundColor: OverlayTheme.tertiaryColor, syntax: true, Self.element: element])
            }
            for link in links where !codes.contains(where: { NSIntersectionRange($0.range, link.range).length > 0 }) {
                if link.range(at: 1).location == NSNotFound { add(link.range, [.foregroundColor: OverlayTheme.editorLinkColor]) }
                else {
                    add(link.range, [.foregroundColor: OverlayTheme.tertiaryColor])
                    let label = link.range(at: 1)
                    let element = Element(range: link.range, kind: .inlineSpan)
                    add(NSRange(location: link.range.location, length: label.location - link.range.location),
                        [syntax: true, Self.element: element])
                    add(NSRange(location: NSMaxRange(label), length: NSMaxRange(link.range) - NSMaxRange(label)),
                        [syntax: true, Self.element: element])
                    add(label, [.foregroundColor: OverlayTheme.editorLinkColor])
                }
            }
            processedEnd = NSMaxRange(line)
            offset = processedEnd
            if stopAfterLine?(line, outgoingFence) == true { break }
        }
        return ScanResult(spans: spans, processedRange: NSRange(location: start, length: processedEnd - start))
    }
}
