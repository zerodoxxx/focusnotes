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

    /// Paragraph-style variants that must stay in sync (body, raw syntax, hidden-syntax preview).
    static let paragraphKeys: [NSAttributedString.Key] = [.paragraphStyle, rawParagraph, previewParagraph]
    /// Every attribute the styler writes.
    @_spi(Checks) public static let styledKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .strikethroughStyle,
        syntax, element, bullet, task, taskIndent, quote,
        fencedCodeBlock, inlineCode, fenceStateAfter
    ] + paragraphKeys

    /// A `task` attribute value: whether the task box is checked.
    static func taskState(_ value: Any?) -> Bool? { value as? Bool }

    /// Literal Markdown patterns, compiled once; patterns are fixed, so failure is a programmer error.
    enum Syntax {
        static let heading = compile("^#+ ")
        static let listMarker = compile(#"^([ \t]*)([-*+] (?:\[[ xX]\] )?|[0-9]+\. )"#)
        static let quote = compile("^> ")
        static let inlineCode = compile(#"(`+)([^`\r\n]+)\1"#)
        static let link = compile(#"\[([^\]\r\n]+)\]\(([^)\r\n]+)\)|https?://[^\s<>]+"#)
        static let strong = compile(#"(\*\*|__)(?=\S)(.+?\S|\S)\1"#)
        static let italic = compile(#"(?<![\w*_])(\*|_)(?=\S)([^*_\r\n]+?\S|[^\s*_])\1(?![\w*_])"#)
        static let strike = compile(#"(~~)(?=\S)(.+?\S|\S)\1"#)
        /// Single-line editor patterns.
        static let emptyTaskBox = compile(#"^([ \t]*)([-*+]) \[\]$"#, options: [])
        static let taskBox = compile(#"^([ \t]*)([-*+] )\[[ xX]\] "#, options: [])
        /// Length of the "[x] " box that taskBox matches after the bullet.
        static let taskBoxLength = 4
        static let listLine = compile(#"^([ \t]*)([-*+] (?:\[[ xX]\] )?|([0-9]+)\. )(.*)$"#, options: [])

        static func isBulletCharacter(_ c: unichar) -> Bool { c == 45 || c == 42 || c == 43 }

        private static func compile(_ pattern: String, options: NSRegularExpression.Options = .anchorsMatchLines) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    /// Feeds one logical line (without its newline) through the fence state.
    /// Returns whether the line is itself an opening or closing fence.
    static func advanceFence(_ fence: inout FenceState, line: NSString) -> Bool {
        var indent = 0
        while indent < line.length, line.character(at: indent) == 32 { indent += 1 }
        var run = 0
        let first: unichar = indent < line.length ? line.character(at: indent) : 0
        if indent <= 3, first == 96 || first == 126 {
            while indent + run < line.length, line.character(at: indent + run) == first { run += 1 }
        }
        let rest = line.substring(from: min(line.length, indent + run))
        if fence.isOpen {
            if first == fence.character, run >= fence.length,
               rest.trimmingCharacters(in: .whitespaces).isEmpty { fence = .outside; return true }
        } else if run >= 3, first != 96 || !rest.contains("`") {
            fence = FenceState(character: first, length: run); return true
        }
        return false
    }

    /// Levels past four share the smallest heading font.
    private static func headingFont(level: Int) -> NSFont { OverlayTheme.editorHeadingFonts[min(level, 4) - 1] }

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

    /// The paragraph containing `edit`, clamped to `source`.
    @_spi(Checks) public static func paragraphRange(around edit: NSRange, in source: NSString) -> NSRange {
        let safe = NSIntersectionRange(edit, NSRange(location: 0, length: source.length))
        let probe = min(safe.location, max(0, source.length - 1))
        return source.paragraphRange(for: NSRange(location: probe, length: min(max(1, safe.length), source.length - probe)))
    }

    /// The editor's restyle: rewrites the paragraph around `editedRange` plus any suffix whose
    /// fence state changed (the whole document when nil). `adjust` runs inside the same editing
    /// batch. Returns the rewritten line range.
    @_spi(Checks) @discardableResult
    public static func restyle(_ storage: NSMutableAttributedString, editedRange: NSRange?,
                               baseAttributes: [NSAttributedString.Key: Any],
                               adjust: (NSRange) -> Void = { _ in }) -> NSRange {
        let text = storage.string
        let source = text as NSString
        let scan: ScanResult
        if let editedRange {
            let safeEdit = NSIntersectionRange(editedRange, NSRange(location: 0, length: source.length))
            let paragraph = paragraphRange(around: editedRange, in: source)
            let start = paragraph.location
            let incomingFence = start > 0
                ? storage.attribute(fenceStateAfter, at: start - 1, effectiveRange: nil) as? FenceState ?? .outside
                : .outside
            let minimumEnd = max(NSMaxRange(paragraph), NSMaxRange(safeEdit))
            scan = Self.scan(text, from: start, startingFence: incomingFence) { line, state in
                guard NSMaxRange(line) >= minimumEnd, line.location < source.length,
                      let previousState = storage.attribute(fenceStateAfter, at: line.location,
                                                            effectiveRange: nil) as? FenceState else { return false }
                return state == previousState
            }
        } else {
            scan = Self.scan(text, from: 0, startingFence: .outside)
        }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: scan.processedRange)
        for span in scan.spans { storage.addAttributes(span.attributes, range: span.range) }
        adjust(scan.processedRange)
        storage.endEditing()
        return scan.processedRange
    }

    /// Restyle from an already-known fence boundary. The caller can stop once the new
    /// outgoing fence state matches the cached state for an unchanged suffix line.
    /// Fence context is scanned as plain lines, without running inline expressions there.
    public static func scan(_ text: String, from requestedStart: Int, startingFence initialFence: FenceState,
                            stopAfterLine: ((NSRange, FenceState) -> Bool)? = nil) -> ScanResult {
        let source = text as NSString
        guard source.length > 0 else { return ScanResult(spans: [], processedRange: .init(location: 0, length: 0)) }
        let startProbe = min(max(0, requestedStart), source.length - 1)
        let start = source.lineRange(for: NSRange(location: startProbe, length: 0)).location
        let target = NSRange(location: start, length: source.length - start)
        var spans: [Span] = []
        var fence: FenceState = initialFence
        var processedEnd = start
        func add(_ range: NSRange, _ attributes: [NSAttributedString.Key: Any]) {
            let intersection = NSIntersectionRange(range, target)
            if intersection.length > 0 { spans.append((intersection, attributes)) }
        }
        func matches(_ regex: NSRegularExpression, _ range: NSRange) -> [NSTextCheckingResult] {
            regex.matches(in: text, range: range)
        }
        var offset = start
        while offset < source.length {
            let line = source.lineRange(for: NSRange(location: offset, length: 0))
            let value = source.substring(with: line) as NSString
            let trimmed = value.trimmingCharacters(in: .newlines) as NSString
            let fenceLine = advanceFence(&fence, line: trimmed)
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
            var lineFont = OverlayTheme.editorFont
            if let heading = matches(Syntax.heading, line).first {
                lineFont = headingFont(level: heading.range.length - 1)
                add(line, [.font: lineFont, .foregroundColor: OverlayTheme.editorHeadingColor])
                let contentLength = (trimmed as NSString).length
                let element = Element(range: NSRange(location: line.location, length: contentLength), kind: .headingLine)
                add(heading.range, [.foregroundColor: OverlayTheme.tertiaryColor, syntax: true, Self.element: element])
            }
            if let list = matches(Syntax.listMarker, line).first {
                let marker = NSRange(location: line.location, length: list.range.length)
                let itemMarker = list.range(at: 2)
                let blockElement = Element(range: itemMarker, kind: .blockMarker)
                add(itemMarker, [Self.element: blockElement])
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineHeightMultiple = OverlayTheme.editorLineHeightMultiple
                var displayedMarker = source.substring(with: marker)
                let isBullet = Syntax.isBulletCharacter(source.character(at: itemMarker.location))
                if isBullet {
                    add(NSRange(location: itemMarker.location, length: 1), [bullet: true, .font: OverlayTheme.editorBulletFont])
                    displayedMarker = (displayedMarker as NSString).replacingCharacters(in: NSRange(location: itemMarker.location - marker.location, length: 1), with: OverlayTheme.editorBullet)
                }
                paragraph.headIndent = (displayedMarker as NSString).size(withAttributes: [.font: OverlayTheme.editorFont]).width
                if isBullet {
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
            } else if let quote = matches(Syntax.quote, line).first {
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
            let codes = matches(Syntax.inlineCode, line)
            let links = matches(Syntax.link, line)
            let protected = codes.map(\.range) + links.map(\.range)
            func emphasis(_ pattern: NSRegularExpression, _ attrs: [NSAttributedString.Key: Any]) {
                for match in matches(pattern, line) where !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    add(match.range(at: 2), attrs)
                    let element = Element(range: match.range, kind: .inlineSpan)
                    add(match.range(at: 1), [.foregroundColor: OverlayTheme.tertiaryColor, syntax: true, Self.element: element])
                    let end = NSMaxRange(match.range(at: 2))
                    add(NSRange(location: end, length: NSMaxRange(match.range) - end),
                        [.foregroundColor: OverlayTheme.tertiaryColor, syntax: true, Self.element: element])
                }
            }
            emphasis(Syntax.strong, [.font: NSFont.systemFont(ofSize: lineFont.pointSize, weight: .semibold)])
            let italic = NSFont(descriptor: lineFont.fontDescriptor.withSymbolicTraits(lineFont.fontDescriptor.symbolicTraits.union(.italic)), size: lineFont.pointSize) ?? lineFont
            emphasis(Syntax.italic, [.font: italic])
            emphasis(Syntax.strike, [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
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
