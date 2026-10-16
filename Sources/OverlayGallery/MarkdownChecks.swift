import AppKit
import OverlayKit

let editorSample = """
## Working notes
**bold** *italic* `code` ~~strike~~ [link](https://example.com)
- A long item that wraps and keeps its text aligned after the visible Markdown marker, even on a second line.
- [ ] Follow up
- [x] Reviewed
> Keep the source in context.
```swift
let message = "Hello"
print(message)
// **plain code**
```
"""

@MainActor
func checkMarkdownStyler() throws {
    let text = editorSample + "\n# One\n### Three\n#### Four\n####### Deep\n__strong__ _emphasis_\n1. Numbered\n+ Plus\n  - [ ] Nested task\n    - [x] Deeper task\n  - Nested bullet\nhttps://example.org\n😀 **unicode**"
    let source = text as NSString
    let result = NSMutableAttributedString(string: text, attributes: MarkdownStyler.baseAttributes)
    let spans = MarkdownStyler.styles(text)
    for span in spans {
        guard span.range.location >= 0, NSMaxRange(span.range) <= source.length else { throw GalleryError("Styler produced invalid UTF-16 range") }
        result.addAttributes(span.attributes, range: span.range)
    }
    func attrs(_ token: String) throws -> [NSAttributedString.Key: Any] {
        let range = source.range(of: token)
        guard range.location != NSNotFound else { throw GalleryError("Missing style fixture: \(token)") }
        return result.attributes(at: range.location, effectiveRange: nil)
    }
    func expect(_ condition: Bool, _ message: String) throws { if !condition { throw GalleryError(message) } }
    try expect((try attrs("Working notes")[.font] as? NSFont)?.pointSize == 19, "H2 font")
    for (token, size) in [("One", CGFloat(22)), ("Three", CGFloat(17)), ("Four", CGFloat(15)), ("Deep", CGFloat(15))] {
        try expect((try attrs(token)[.font] as? NSFont)?.pointSize == size, "Heading font: \(token)")
    }
    try expect((try attrs("## ")[.foregroundColor] as? NSColor) == OverlayTheme.tertiaryColor, "Heading delimiters")
    for token in ["bold", "strong", "unicode"] {
        try expect((try attrs(token)[.font] as? NSFont) == OverlayTheme.editorStrongFont, "Bold range: \(token)")
    }
    for token in ["italic", "emphasis"] {
        try expect((try attrs(token)[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true, "Italic trait: \(token)")
    }
    try expect((try attrs("code")[.font] as? NSFont) == OverlayTheme.editorCodeFont, "Inline code font")
    try expect(try attrs("code")[MarkdownStyler.inlineCode] as? Bool == true && attrs("code")[.backgroundColor] == nil, "Inline code uses one padded rounded decoration")
    try expect((try attrs("strike")[.strikethroughStyle] as? Int) == NSUnderlineStyle.single.rawValue, "Strike range")
    try expect((try attrs("- A")[.foregroundColor] as? NSColor) == OverlayTheme.secondaryColor, "Bullet marker range")
    try expect((try attrs("- A")[.font] as? NSFont) == OverlayTheme.editorBulletFont && OverlayTheme.editorBulletFont.pointSize == OverlayTheme.editorFont.pointSize,
               "Bullet glyph must use the body font size at semibold weight")
    try expect((try attrs("1. ")[.foregroundColor] as? NSColor) == OverlayTheme.secondaryColor, "Numbered marker range")
    try expect((try attrs("+ ")[.foregroundColor] as? NSColor) == OverlayTheme.secondaryColor, "Plus marker range")
    try expect((try attrs("A long")[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0 > 0, "Hanging list indent")
    try expect((try attrs("- [ ]")[.foregroundColor] as? NSColor) == OverlayTheme.secondaryColor, "Task marker range")
    try expect((try attrs("Reviewed")[.strikethroughStyle] as? Int) == NSUnderlineStyle.single.rawValue, "Completed task strike")
    try expect((try attrs("Reviewed")[.foregroundColor] as? NSColor) == OverlayTheme.secondaryColor, "Completed task color")
    let checkboxTextIndent = OverlayTheme.editorCheckboxSize + OverlayTheme.editorCheckboxGap
    for token in ["Nested task", "Deeper task"] {
        let task = try attrs(token)
        let taskText = source.range(of: token)
        let taskLine = source.lineRange(for: taskText)
        let taskMarker = source.range(of: "- [", range: taskLine)
        let indentation = taskMarker.location == NSNotFound ? -1
            : result.attribute(MarkdownStyler.taskIndent, at: taskMarker.location, effectiveRange: nil) as? CGFloat ?? -1
        let preview = task[MarkdownStyler.previewParagraph] as? NSParagraphStyle
        try expect(indentation > 0 && preview != nil, "Nested task checkbox style: \(token)")
        try expect(abs((preview?.firstLineHeadIndent ?? -1) - checkboxTextIndent) < 0.001,
                   "Nested task first-line indent must not count visible Markdown spaces twice: \(token)")
        try expect(abs((preview?.headIndent ?? -1) - indentation - checkboxTextIndent) < 0.001,
                   "Wrapped nested task lines must align after the checkbox and list indentation: \(token)")
    }
    let nestedBulletIndent = (try attrs("Nested bullet")[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0
    let rootBulletIndent = (try attrs("A long")[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0
    try expect(nestedBulletIndent > rootBulletIndent,
               "Nested bullet hanging indent must retain its existing marker spacing")
    try expect((try attrs("> ")[.foregroundColor] as? NSColor) == OverlayTheme.tertiaryColor, "Quote marker")
    try expect((try attrs("Keep")[.paragraphStyle] as? NSParagraphStyle)?.headIndent == OverlayTheme.editorQuoteIndent, "Quote indent")
    try expect((try attrs("link")[.foregroundColor] as? NSColor) == OverlayTheme.editorLinkColor, "Link text range")
    try expect((try attrs("](https:")[.foregroundColor] as? NSColor) == OverlayTheme.tertiaryColor, "Link punctuation range")
    try expect((try attrs("https://example.org")[.foregroundColor] as? NSColor) == OverlayTheme.editorLinkColor, "Bare URL range")
    try expect((try attrs("```swift")[.foregroundColor] as? NSColor) == OverlayTheme.tertiaryColor, "Fence delimiter range")
    try expect(try attrs("```swift")[MarkdownStyler.fencedCodeBlock] as? Bool == true, "Opening fence block decoration")
    try expect(try attrs("let message")[MarkdownStyler.fencedCodeBlock] as? Bool == true, "Code block decoration")
    let closing = source.range(of: "```", options: .backwards)
    try expect(result.attribute(MarkdownStyler.fencedCodeBlock, at: closing.location, effectiveRange: nil) as? Bool == true,
               "Closing fence must receive the full-width block decoration")
    try expect(try attrs("let message")[.backgroundColor] == nil, "Block fill must not also draw behind individual glyphs")
    for (name, alpha, white) in [(NSAppearance.Name.aqua, CGFloat(0.05), CGFloat(0)), (.darkAqua, CGFloat(0.09), CGFloat(1))] {
        guard let appearance = NSAppearance(named: name) else { throw GalleryError("Missing code-fill appearance") }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = OverlayTheme.codeBackground.usingColorSpace(.deviceRGB) }
        guard let color = resolved else { throw GalleryError("Code color did not resolve") }
        try expect(abs(color.alphaComponent - alpha) < 0.001 && abs(color.redComponent - white) < 0.001,
                   "Code background must resolve its tint/opacity for \(name)")
    }
    try expect((try attrs("**plain code**")[.font] as? NSFont) == OverlayTheme.editorCodeFont, "No emphasis inside fenced code")
    try expect((try attrs("**plain code**")[.foregroundColor] as? NSColor) == OverlayTheme.textColor, "Code punctuation must retain body color")
    let fenceText = "```\n# heading **bold** *italic* [link](https://example.com) ~~strike~~\n```"
    let fenceStyles = MarkdownStyler.styles(fenceText)
    let interior = (fenceText as NSString).range(of: "# heading **bold** *italic* [link](https://example.com) ~~strike~~")
    let fencedStorage = NSMutableAttributedString(string: fenceText, attributes: MarkdownStyler.baseAttributes)
    for span in fenceStyles { fencedStorage.addAttributes(span.attributes, range: span.range) }
    for index in interior.location..<NSMaxRange(interior) {
        let attributes = fencedStorage.attributes(at: index, effectiveRange: nil)
        try expect((attributes[.font] as? NSFont) == OverlayTheme.editorCodeFont
                   && (attributes[.foregroundColor] as? NSColor) == OverlayTheme.textColor
                   && attributes[.strikethroughStyle] == nil
                   && attributes[MarkdownStyler.inlineCode] == nil
                   && attributes[MarkdownStyler.element] == nil
                   && attributes[MarkdownStyler.syntax] == nil
                   && attributes[MarkdownStyler.fencedCodeBlock] as? Bool == true,
                   "No inline or heading styling inside fences")
    }
    let large = String(repeating: editorSample + "\n", count: 50)
    let largeSource = large as NSString
    let paragraph = largeSource.paragraphRange(for: NSRange(location: largeSource.range(of: "Reviewed").location, length: 1))
    let start = ContinuousClock.now
    for _ in 0..<10 { _ = MarkdownStyler.styles(String(large.prefix(20_000))) }
    let elapsed = start.duration(to: .now)
    let limited = MarkdownStyler.styles(large, in: paragraph)
    try expect(!limited.isEmpty && limited.allSatisfy { NSIntersectionRange($0.range, paragraph) == $0.range }, "Large document paragraph cap")

    func fullyStyled(_ value: String) -> NSMutableAttributedString {
        let storage = NSMutableAttributedString(string: value, attributes: MarkdownStyler.baseAttributes)
        for span in MarkdownStyler.styles(value) { storage.addAttributes(span.attributes, range: span.range) }
        return storage
    }
    func sameAttribute(_ lhs: Any?, _ rhs: Any?) -> Bool {
        let left: Any
        let right: Any
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(_), nil), (nil, .some(_)): return false
        case let (.some(lhs), .some(rhs)):
            left = lhs
            right = rhs
        }
        let lhs = left
        let rhs = right
        if let lhs = lhs as? MarkdownStyler.Element, let rhs = rhs as? MarkdownStyler.Element { return lhs == rhs }
        if let lhs = lhs as? MarkdownStyler.FenceState, let rhs = rhs as? MarkdownStyler.FenceState { return lhs == rhs }
        if let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber { return lhs == rhs }
        if let lhs = lhs as? NSObject { return lhs.isEqual(rhs) }
        return String(describing: lhs) == String(describing: rhs)
    }
    func incrementallyEdit(_ original: String, token: String, replacement: String) throws -> (NSMutableAttributedString, NSRange, Duration) {
        let storage = fullyStyled(original)
        let oldSource = storage.string as NSString
        let oldRange = oldSource.range(of: token)
        guard oldRange.location != NSNotFound else { throw GalleryError("Missing incremental-style fixture: \(token)") }
        let editStart = ContinuousClock.now
        storage.replaceCharacters(in: oldRange, with: replacement)
        let value = storage.string
        let source = value as NSString
        let changed = NSRange(location: oldRange.location, length: (replacement as NSString).length)
        let probe = min(changed.location, max(0, source.length - 1))
        let paragraph = source.paragraphRange(for: NSRange(location: probe, length: min(max(1, changed.length), source.length - probe)))
        MarkdownStyler.rebaseElementRanges(in: storage, after: NSMaxRange(paragraph),
                                           by: changed.length - oldRange.length)
        let start = paragraph.location
        let incoming = start > 0
            ? storage.attribute(MarkdownStyler.fenceStateAfter, at: start - 1, effectiveRange: nil) as? MarkdownStyler.FenceState ?? .outside
            : .outside
        let minimumEnd = max(NSMaxRange(paragraph), NSMaxRange(changed))
        let scan = MarkdownStyler.scan(value, from: start, startingFence: incoming) { line, state in
            guard NSMaxRange(line) >= minimumEnd, line.location < source.length,
                  let oldState = storage.attribute(MarkdownStyler.fenceStateAfter, at: line.location,
                                                   effectiveRange: nil) as? MarkdownStyler.FenceState else { return false }
            return state == oldState
        }
        storage.setAttributes(MarkdownStyler.baseAttributes, range: scan.processedRange)
        for span in scan.spans { storage.addAttributes(span.attributes, range: span.range) }
        let editElapsed = editStart.duration(to: .now)
        let expected = fullyStyled(value)
        let attributes: [NSAttributedString.Key] = [
            .font, .foregroundColor, .paragraphStyle, .strikethroughStyle,
            MarkdownStyler.syntax, MarkdownStyler.element, MarkdownStyler.bullet,
            MarkdownStyler.task, MarkdownStyler.taskIndent, MarkdownStyler.quote,
            MarkdownStyler.rawParagraph, MarkdownStyler.previewParagraph,
            MarkdownStyler.fencedCodeBlock, MarkdownStyler.inlineCode, MarkdownStyler.fenceStateAfter
        ]
        guard storage.length == expected.length else { throw GalleryError("Incremental style changed UTF-16 length") }
        for index in 0..<storage.length {
            for key in attributes where !sameAttribute(storage.attribute(key, at: index, effectiveRange: nil),
                                                        expected.attribute(key, at: index, effectiveRange: nil)) {
                throw GalleryError("Incremental Markdown styling differed at UTF-16 offset \(index), attribute \(key)")
            }
        }
        return (storage, scan.processedRange, editElapsed)
    }

    let unicodeDocument = "😀 heading\n# **outside**\nplain\n```swift\nprint(\"**code**\")\n```\n# after\n"
    let openedFence = try incrementallyEdit(unicodeDocument, token: "plain", replacement: "```\nplain")
    try expect(openedFence.1.length < (openedFence.0.string as NSString).length,
               "Opening a fence should restyle only through the first unchanged fence boundary")
    let reopened = openedFence.0.string as NSString
    try expect(openedFence.0.attribute(MarkdownStyler.fencedCodeBlock, at: reopened.range(of: "# **outside**").location, effectiveRange: nil) as? Bool != true,
               "Text before an inserted fence must keep its Markdown styling")
    try expect(openedFence.0.attribute(MarkdownStyler.fencedCodeBlock, at: reopened.range(of: "# after").location, effectiveRange: nil) as? Bool != true,
               "A later unchanged closing fence must end the inserted code block")

    let removedCloser = try incrementallyEdit(unicodeDocument, token: "```\n# after", replacement: "not-a-fence\n# after")
    let afterRemovedCloser = (removedCloser.0.string as NSString).range(of: "# after")
    try expect(removedCloser.0.attribute(MarkdownStyler.fencedCodeBlock, at: afterRemovedCloser.location, effectiveRange: nil) as? Bool == true,
               "Removing a closing fence must propagate code styling through the suffix")
    try expect(NSMaxRange(removedCloser.1) == removedCloser.0.length,
               "An unmatched opening fence must rescan to end-of-document")

    let addedCloser = try incrementallyEdit("😀 title\n```swift\n**code**\n# still code\n# after\n",
                                            token: "**code**\n", replacement: "**code**\n```\n")
    let afterAddedCloser = (addedCloser.0.string as NSString).range(of: "# still code")
    try expect(addedCloser.0.attribute(MarkdownStyler.fencedCodeBlock, at: afterAddedCloser.location, effectiveRange: nil) as? Bool != true,
               "An inserted closing fence must restore Markdown styling below it")

    let offsetDocument = "😀 lead\nplain text\n# Heading **bold**\n[link](https://example.org) and ~~strike~~\n- [ ] task\n"
    _ = try incrementallyEdit(offsetDocument, token: "lead", replacement: "a much longer lead")
    _ = try incrementallyEdit(offsetDocument, token: "plain text", replacement: "plain")

    let heavyTail = String(repeating: "# Heading **bold** [link](https://example.org) - [ ] task\n", count: 600)
    let heavyDocument = "😀 prefix\n" + heavyTail
    let heavyStorage = fullyStyled(heavyDocument)
    let heavySource = heavyStorage.string as NSString
    let prefix = heavySource.range(of: "prefix")
    heavyStorage.replaceCharacters(in: prefix, with: "a much longer prefix")
    let editedSource = heavyStorage.string as NSString
    let changedParagraph = editedSource.paragraphRange(for: NSRange(location: prefix.location, length: 1))
    let rebaseStart = ContinuousClock.now
    MarkdownStyler.rebaseElementRanges(in: heavyStorage, after: NSMaxRange(changedParagraph),
                                       by: ("a much longer prefix" as NSString).length - prefix.length)
    let rebaseElapsed = rebaseStart.duration(to: .now)
    let lastLink = editedSource.range(of: "[link]", options: .backwards)
    let lastLinkElement = heavyStorage.attribute(MarkdownStyler.element, at: lastLink.location, effectiveRange: nil) as? MarkdownStyler.Element
    try expect(lastLinkElement?.range.location == lastLink.location,
               "Large Markdown suffix rebasing must keep the final link's UTF-16 range aligned")

    let headInserted = try incrementallyEdit(heavyDocument, token: "prefix", replacement: "a much longer prefix")
    let headDeleted = try incrementallyEdit(headInserted.0.string, token: "a much longer prefix", replacement: "prefix")
    let withTail = heavyDocument + "tail-marker\n"
    let tailInserted = try incrementallyEdit(withTail, token: "tail-marker", replacement: "tail-marker 😀")
    let tailDeleted = try incrementallyEdit(tailInserted.0.string, token: "tail-marker 😀", replacement: "tail-marker")
    print("MarkdownStyler checks passed; ten ~20k-character full passes: \(elapsed); 600-line suffix rebase: \(rebaseElapsed); incremental head insert/delete: \(headInserted.2)/\(headDeleted.2); tail insert/delete: \(tailInserted.2)/\(tailDeleted.2); paragraph cap verified.")
}

/// Pixel assertions catch appearance/alpha resolution and ragged fence fills in
/// the production view, rather than only checking the styler's attribute values.
@MainActor
func checkEditorCodePixels(_ root: NSView, bitmap: NSBitmapImageRep) throws {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    guard let text = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { $0.string == editorSample }),
          let manager = text.layoutManager, let container = text.textContainer,
          let tint = OverlayTheme.codeBackground.usingColorSpace(.deviceRGB) else { return }
    let source = text.string as NSString
    func pixel(_ point: NSPoint) throws -> NSColor {
        let x = Int(point.x * OverlayTheme.galleryScale), y = Int(point.y * OverlayTheme.galleryScale)
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw GalleryError("Code-fill pixel outside render") }
        return color
    }
    func expectTint(_ point: NSPoint, context: String) throws {
        let base = try pixel(NSPoint(x: OverlayTheme.padding / 2, y: point.y))
        let actual = try pixel(point)
        let alpha = tint.alphaComponent
        let expected = [base.redComponent, base.greenComponent, base.blueComponent].enumerated().map { index, channel in
            let tintChannel = [tint.redComponent, tint.greenComponent, tint.blueComponent][index]
            return channel * (1 - alpha) + tintChannel * alpha
        }
        let channels = [actual.redComponent, actual.greenComponent, actual.blueComponent]
        guard zip(channels, expected).allSatisfy({ abs($0 - $1) < 0.012 }) else {
            throw GalleryError("\(context) code-fill pixels: actual \(channels), expected \(expected)")
        }
    }
    for (label, range) in [("opening fence", source.range(of: "```swift")),
                           ("code body", source.range(of: "let message")),
                           ("closing fence", source.range(of: "```", options: .backwards))] {
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let line = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        for x in [container.size.width / 2, container.size.width - OverlayTheme.codeBlockInset] {
            let point = text.convert(NSPoint(x: text.textContainerOrigin.x + x, y: text.textContainerOrigin.y + line.midY), to: root)
            try expectTint(point, context: label)
        }
    }
    let inlineGlyphs = manager.glyphRange(forCharacterRange: source.range(of: "`code`"), actualCharacterRange: nil)
    let inline = manager.boundingRect(forGlyphRange: inlineGlyphs, in: container)
    let point = text.convert(NSPoint(x: text.textContainerOrigin.x + inline.midX, y: text.textContainerOrigin.y + inline.minY + 1), to: root)
    try expectTint(point, context: "inline code")
    let bodyGlyphs = manager.glyphRange(forCharacterRange: source.range(of: "code"), actualCharacterRange: nil)
    let body = manager.boundingRect(forGlyphRange: bodyGlyphs, in: container)
    for x in [body.minX - OverlayTheme.inlineCodePadding / 2, body.maxX + OverlayTheme.inlineCodePadding / 2] {
        let padding = text.convert(NSPoint(x: text.textContainerOrigin.x + x, y: text.textContainerOrigin.y + body.midY), to: root)
        try expectTint(padding, context: "inline code horizontal padding")
    }
    print("Code background pixels passed (inline and full-width opening/body/closing fence).")
}
