import Core
import Foundation

func checkNoteParser() throws {
    let calendar = checkCalendar()
    let minute = checkDate(2026, 10, 13, 10, 4)
    let id = UUID(uuidString: "0B3C0000-0000-4000-8000-000000000001")!
    let sources: [(CaptureSource, String?, String?)] = [
        (CaptureSource(), nil, "Unknown source"),
        (CaptureSource(appName: "  Safari\n Browser  "), "Safari Browser", "Safari Browser"),
        (CaptureSource(appName: " Safari · Beta ", windowTitle: "  Token\n bucket · Wikipedia  "), "Safari - Beta", "Token bucket - Wikipedia"),
        (CaptureSource(appName: "Preview", windowTitle: String(repeating: "x", count: 85)), "Preview", String(repeating: "x", count: 80) + "…")
    ]
    let contents: [CaptureContent] = [
        .text("\n  \nFirst paragraph\n\nSecond paragraph with Café 😀  \n\n"),
        .text("  \n\t"),
        .text("a\r\nb\n### ordinary body heading\nnot a marker"),
        .image(assetPath: "assets/my shot.png")
    ]
    for path in ["Root.md", "Sessions/Session.md"] {
        let directory = path.hasPrefix("Sessions/") ? "Sessions" : ""
        for (source, app, window) in sources {
            for content in contents {
                let capture = Capture(id: id, createdAt: minute.addingTimeInterval(42), content: content, source: source)
                let written = CaptureFormat.block(for: capture, noteRelativeDir: directory, calendar: calendar)
                let markdown = "#   Parsed\t title  \n\n" + written
                let parsed = NoteParser.parse(contents: markdown, notePath: path, titleFallback: "Fallback", calendar: calendar)
                try require(parsed.title == "Parsed title", "parser should clean the leading title")
                try require(parsed.blocks.count == 1, "round-trip should recover exactly one block")
                let block = parsed.blocks[0]
                try require(block.captureID == id && block.createdAt == minute.addingTimeInterval(42), "round-trip id or seconds changed")
                try require(block.sourceApp == app && block.windowTitle == window, "round-trip source parts changed")
                let separator = written.range(of: "\n\n")!
                let expectedBody = String(written[separator.upperBound...].dropLast())
                try require(block.body == expectedBody, "round-trip should preserve the body as written")
                switch content {
                case .subheading, .text, .note:
                    try require(block.kind == .text && block.assetPath == nil, "text round-trip kind changed")
                case .image(let assetPath):
                    try require(block.kind == .image && block.assetPath == assetPath, "image path should resolve from either note folder")
                }
                let crlf = NoteParser.parse(contents: markdown.replacingOccurrences(of: "\n", with: "\r\n"), notePath: path, titleFallback: "Fallback", calendar: calendar)
                try require(crlf == parsed, "CRLF should parse identically to LF")
            }
        }
    }

    let sourceURL = "https://example.test/page?a=1#part"
    let linkedImage = Capture(id: id, createdAt: minute, content: .image(assetPath: "assets/shot one.png"),
                              source: CaptureSource(url: sourceURL))
    let linkedImageMarkdown = CaptureFormat.block(for: linkedImage, noteRelativeDir: "", calendar: calendar)
    let linkedImageBlock = NoteParser.parse(contents: linkedImageMarkdown, notePath: "Root.md", titleFallback: "Root", calendar: calendar).blocks[0]
    let linkedImageBody = "[Source](<\(sourceURL)>)\n\n![](assets/shot%20one.png)"
    try require(linkedImageBlock.kind == .image && linkedImageBlock.assetPath == "assets/shot one.png",
                "a generated source link must not hide the following image asset")
    try require(linkedImageBlock.body == linkedImageBody, "image classification must preserve the complete linked body")

    let literalLink = "[Source](<\(sourceURL)>)"
    let linkedSelection = Capture(id: id, createdAt: minute, content: .text(literalLink), source: CaptureSource(url: sourceURL))
    let selectionBlock = NoteParser.parse(
        contents: CaptureFormat.block(for: linkedSelection, noteRelativeDir: "", calendar: calendar),
        notePath: "Root.md", titleFallback: "Root", calendar: calendar
    ).blocks[0]
    try require(selectionBlock.kind == .text && selectionBlock.body == "\(literalLink)\n\n\(literalLink)",
                "a selected literal source link must remain in the parsed text body")

    for invalidURL in ["javascript:alert(1)", "file:///tmp/page", "https://example.test/%GG"] {
        let malformedText = "[Source](<\(invalidURL)>)\n\n![](assets/shot.png)"
        let malformedCapture = Capture(id: id, createdAt: minute, content: .text(malformedText), source: CaptureSource())
        let malformedBlock = NoteParser.parse(
            contents: CaptureFormat.block(for: malformedCapture, noteRelativeDir: "", calendar: calendar),
            notePath: "Root.md", titleFallback: "Root", calendar: calendar
        ).blocks[0]
        try require(malformedBlock.kind == .text && malformedBlock.body == malformedText,
                    "a malformed or non-HTTP source-like line must remain ordinary text")
    }

    let first = Capture(id: id, createdAt: minute, content: .text("first body"), source: CaptureSource())
    let second = Capture(id: UUID(), createdAt: minute.addingTimeInterval(60), content: .text("second body"), source: CaptureSource())
    let markdown = "# Mixed\n\nLoose introduction\n### ordinary heading\nstill loose\n\nAnother loose paragraph\n\n"
        + CaptureFormat.block(for: first, noteRelativeDir: "", calendar: calendar)
        + "\nUser text between captures\n### another ordinary heading\n\n"
        + CaptureFormat.block(for: second, noteRelativeDir: "", calendar: calendar)
    let mixed = NoteParser.parse(contents: markdown, notePath: "Mixed.md", titleFallback: "Fallback", calendar: calendar)
    try require(mixed.blocks.count == 4, "two initial loose regions and two captures should be recovered")
    try require(mixed.blocks[0].kind == .loose && mixed.blocks[0].captureID == nil && mixed.blocks[0].createdAt == nil, "loose blocks should have no capture metadata")
    try require(mixed.blocks[0].body.contains("### ordinary heading"), "a heading without a marker is ordinary Markdown")
    // There is no closing capture marker: intervening edits belong to the preceding capture until the next pair.
    try require(mixed.blocks[2].body == "first body\n\nUser text between captures\n### another ordinary heading", "intervening loose edits must be preserved in the containing capture")
    try require(mixed.blocks[3].body == "second body", "the next valid pair should end the preceding capture")

    let long = String(repeating: "é", count: 5_000)
    let chunked = NoteParser.parse(contents: "# Long\n\n" + long + "\n\nShort paragraph", notePath: "Long.md", titleFallback: "Fallback", calendar: calendar)
    try require(chunked.blocks.map(\.body.count) == [2_000, 2_000, 1_000, 15], "long loose paragraphs should be chunked to at most 2,000 characters")
    try require(chunked.blocks.prefix(3).map(\.body).joined() == long, "chunking must preserve every character")

    let fallback = NoteParser.parse(contents: "No leading title\n\nparagraph", notePath: "Fallback.md", titleFallback: "Fallback", calendar: calendar)
    try require(fallback.title == "Fallback" && fallback.blocks[0].body == "No leading title", "missing title should use the file stem and preserve the first line")
    let bom = NoteParser.parse(contents: "\u{FEFF}# \t \n\nbody", notePath: "Stem.md", titleFallback: "Stem", calendar: calendar)
    try require(bom.title == "Stem", "BOM and empty cleaned titles should follow Vault's fallback rule")
    let malformed = NoteParser.parse(contents: "# Malformed\n\n### 2026-02-30 10:04\n\(checkMarker(id))\n\nBad date\n\n### 2026-10-13 10:04\n<!-- capture:not-a-uuid -->\n\nBad marker", notePath: "Malformed.md", titleFallback: "Fallback", calendar: calendar)
    try require(malformed.blocks.allSatisfy { $0.kind == .loose }, "malformed dates and markers should degrade to loose Markdown")

    let extraParts = NoteParser.parse(contents: "# Parts\n\n### 2026-10-13 10:04 · Safari · One · Two\n\(checkMarker(id))\n\nbody", notePath: "Parts.md", titleFallback: "Fallback", calendar: calendar)
    try require(extraParts.blocks[0].sourceApp == "Safari" && extraParts.blocks[0].windowTitle == "One · Two", "extra header parts should remain in the window title")
    let windowOnly = Capture(id: id, createdAt: minute, content: .text("body"), source: CaptureSource(windowTitle: "Window only"))
    let ambiguous = NoteParser.parse(contents: CaptureFormat.block(for: windowOnly, noteRelativeDir: "", calendar: calendar), notePath: "Parts.md", titleFallback: "Fallback", calendar: calendar)
    try require(ambiguous.blocks[0].sourceApp == nil && ambiguous.blocks[0].windowTitle == "Window only", "new marker metadata must distinguish app from source title")
    let escaping = NoteParser.parse(contents: "### 2026-10-13 10:04\n\(checkMarker(id))\n\n![](../../outside.png)", notePath: "Root.md", titleFallback: "Fallback", calendar: calendar)
    try require(escaping.blocks[0].kind == .text, "an image outside the vault should degrade to text")
    let noteURL = URL(fileURLWithPath: "/Users/example/Desktop/typed note.md")
    let assetRootURL = URL(fileURLWithPath: "/Users/example/Vault/assets", isDirectory: true)
    let image = Capture(id: id, createdAt: minute, content: .image(assetPath: "assets/shot one.png"), source: CaptureSource())
    let externalBlock = CaptureFormat.block(
        for: image, noteRelativeDir: "", calendar: calendar,
        assetPathPrefix: "../Vault"
    )
    let external = NoteParser.parse(contents: externalBlock, notePath: noteURL.absoluteString, titleFallback: "typed note",
                                    calendar: calendar, assetRootURL: assetRootURL)
    try require(external.blocks.first?.kind == .image && external.blocks.first?.assetPath == "assets/shot one.png",
                "home-note image links should resolve to vault assets only")
    let externalEscape = NoteParser.parse(
        contents: "### 2026-10-13 10:04\n\(checkMarker(id))\n\n![](../outside.png)",
        notePath: noteURL.absoluteString, titleFallback: "typed note", calendar: calendar, assetRootURL: assetRootURL
    )
    try require(externalEscape.blocks.first?.kind == .text && externalEscape.blocks.first?.assetPath == nil,
                "external Markdown links outside the vault asset root must stay unindexed")
    let encodedTraversal = NoteParser.parse(
        contents: "### 2026-10-13 10:04\n\(checkMarker(id))\n\n![](%2E%2E/%2E%2E/outside.png)",
        notePath: noteURL.absoluteString, titleFallback: "typed note", calendar: calendar, assetRootURL: assetRootURL
    )
    try require(encodedTraversal.blocks.first?.kind == .text && encodedTraversal.blocks.first?.assetPath == nil,
                "percent-encoded traversal outside the asset root must stay unindexed")
    let vaultOverTraversal = NoteParser.parse(
        contents: "### 2026-10-13 10:04\n\(checkMarker(id))\n\n![](../../assets/shot.png)",
        notePath: "Nested/Root.md", titleFallback: "Root", calendar: calendar
    )
    try require(vaultOverTraversal.blocks.first?.kind == .text && vaultOverTraversal.blocks.first?.assetPath == nil,
                "vault-relative image paths must reject traversal above the vault root before re-entering assets")
    let legacy = "### 2026-10-13 10:04 · Safari · Page\n\(checkMarker(id))\n\nlegacy body\n"
    let newCapture = Capture(id: UUID(), createdAt: minute.addingTimeInterval(42), content: .text("new body"), source: CaptureSource(appName: "Safari", windowTitle: "Page"))
    let repeatedCapture = Capture(id: UUID(), createdAt: minute.addingTimeInterval(43), content: .text("repeat body"), source: newCapture.source)
    let mixedFormats = "# Formats\n\n" + legacy + "\n" + CaptureFormat.block(for: newCapture, noteRelativeDir: "", calendar: calendar)
        + "\n" + CaptureFormat.block(for: repeatedCapture, noteRelativeDir: "", calendar: calendar, includeSourceHeading: false)
    let both = NoteParser.parse(contents: mixedFormats, notePath: "Formats.md", titleFallback: "", calendar: calendar)
    try require(both.blocks.count == 3 && both.blocks.map(\.body) == ["legacy body", "new body", "repeat body"], "old and new captures must share a note")
    try require(both.blocks.allSatisfy { $0.windowTitle == "Page" && $0.sourceApp == "Safari" } && both.blocks[0].createdAt == minute && both.blocks[2].createdAt == repeatedCapture.createdAt,
                "mixed metadata and inherited source heading must survive")
    let oldInherited = NoteParser.parse(contents: legacy + "\n" + CaptureFormat.block(for: newCapture, noteRelativeDir: "", calendar: calendar, includeSourceHeading: false),
                                        notePath: "Formats.md", titleFallback: "", calendar: calendar)
    try require(oldInherited.blocks.count == 2 && oldInherited.blocks[1].windowTitle == "Page", "heading-less new capture must inherit the legacy source without its date/app")
    let fake = "\n````markdown\n### Fake\n" + CaptureFormat.block(for: repeatedCapture, noteRelativeDir: "", calendar: calendar) + "```\n````\n"
    let fenced = NoteParser.parse(contents: mixedFormats + fake, notePath: "Formats.md", titleFallback: "", calendar: calendar)
    try require(fenced.blocks.count == 3 && fenced.blocks[2].windowTitle == "Page", "markers and headings inside code fences must be ignored")
    print("NoteParser checks passed.")
}
