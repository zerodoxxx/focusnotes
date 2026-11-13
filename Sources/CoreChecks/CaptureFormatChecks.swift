import Core
import Foundation

func checkCaptureFormat() throws {
    let calendar = checkCalendar()
    let when = checkDate(2026, 10, 13, 14, 30)
    let id = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000000F")!
    func marker(_ app: String = "") -> String {
        "<!-- capture:a1b2c3d4-0000-4000-8000-00000000000f at=2026-10-13T14:30:00+05:30 app=\"\(app)\" -->"
    }
    func block(_ content: CaptureContent, source: CaptureSource = CaptureSource(), dir: String = "") -> String {
        CaptureFormat.block(for: Capture(id: id, createdAt: when, content: content, source: source),
                            noteRelativeDir: dir, calendar: calendar)
    }
    let cases: [(String, String, String)] = [
        ("app and window", block(.text("Hello\nworld"), source: CaptureSource(appName: "Safari", windowTitle: "Docs — Safari")),
         "### Docs\n\(marker("Safari"))\n\nHello\nworld\n"),
        ("app only", block(.text("Hello"), source: CaptureSource(appName: "Safari")), "### Safari\n\(marker("Safari"))\n\nHello\n"),
        ("unknown", block(.text("Hello")), "### Unknown source\n\(marker())\n\nHello\n"),
        ("clean and truncate", block(.text("Hello"), source: CaptureSource(windowTitle: "Plan · draft\nline two " + String(repeating: "x", count: 85))),
         "### Plan - draft line two \(String(repeating: "x", count: 58))…\n\(marker())\n\nHello\n"),
        ("root image", block(.image(assetPath: "assets/shot.png")), "### Unknown source\n\(marker())\n\n![](assets/shot.png)\n"),
        ("session image", block(.image(assetPath: "assets/my shot.png"), dir: "Sessions"), "### Unknown source\n\(marker())\n\n![](../assets/my%20shot.png)\n"),
        ("body whitespace", block(.text("\n  \nFirst\n\nSecond  \n\t\n")), "### Unknown source\n\(marker())\n\nFirst\n\nSecond\n"),
        ("empty", block(.text(" \n\t")), "### Unknown source\n\(marker())\n\n(empty)\n"),
        ("CRLF", block(.text("one\r\ntwo\r\n")), "### Unknown source\n\(marker())\n\none\ntwo\n")
    ]
    for (name, actual, expected) in cases { try require(actual == expected, "\(name): got \(actual.debugDescription)") }
    let selectionURL = "https://docs.example.test/notes?id=1#part"
    let selection = block(.text("Selected words"), source: CaptureSource(appName: "Browser", windowTitle: "Selection", url: selectionURL))
    try require(selection == "### Selection\n\(marker("Browser"))\n\n[Source](<\(selectionURL):~:text=Selected%20words>)\n\nSelected words\n",
                "selection source URL must follow the marker and precede captured text: \(selection.debugDescription)")
    let passage = block(.text("Caching keeps   hot data\nclose to the CPU so reads stay fast"), source: CaptureSource(url: "https://blog.example/post"))
    try require(passage.contains("[Source](<https://blog.example/post#:~:text=Caching%20keeps%20hot%20data,so%20reads%20stay%20fast>)"), "passage link must use first and last four words")
    let doc = block(.image(assetPath: "assets/a.pdf"), source: CaptureSource(documentURL: "file:///Users/me/Papers/My%20Paper%20(v2).pdf", page: 12))
    try require(doc.contains("[Source](<file:///Users/me/Papers/My%20Paper%20%28v2%29.pdf>) · page 12"), "document source must encode parentheses and append page")
    let oldJSON = try JSONDecoder().decode(CaptureSource.self, from: Data(#"{"appName":"Safari","windowTitle":"T","url":"https://e.com"}"#.utf8))
    try require(oldJSON.documentURL == nil && oldJSON.page == nil, "old capture source JSON must decode with nil document fields")
    let shortPassage = block(.text("Use well-known keys"), source: CaptureSource(url: "https://e.com/a#intro"))
    try require(shortPassage.contains("[Source](<https://e.com/a#intro:~:text=Use%20well%2Dknown%20keys>)"), "short passage link must encode hyphens")
    let directiveURL = "https://e.com/a#:~:text=old"
    try require(block(.text("Hello"), source: CaptureSource(url: directiveURL)).contains("[Source](<\(directiveURL)>)"), "existing text directive must remain unchanged")
    let symbolText = block(.text("— …"), source: CaptureSource(url: "https://e.com"))
    try require(symbolText.contains("[Source](<https://e.com>)"), "text without letters or digits must not add a directive")
    try require(block(.image(assetPath: "assets/x.png"), source: CaptureSource(url: "https://e.com")).contains("[Source](<https://e.com>)"), "image URL must not add a directive")
    for (documentURL, page, expectedSuffix) in [("file:///tmp/a.pdf", Optional<Int>.none, ""), ("file:///tmp/a.pdf", 0, "")] {
        let rendered = block(.image(assetPath: "assets/a.pdf"), source: CaptureSource(documentURL: documentURL, page: page))
        try require(rendered.contains("[Source](<file:///tmp/a.pdf>)\(expectedSuffix)"), "document link with nil or zero page must omit suffix")
    }
    for invalidDocumentURL in ["https://x", "relative/path", "garbage"] {
        try require(!block(.text("plain"), source: CaptureSource(documentURL: invalidDocumentURL)).contains("[Source]"), "invalid document URL must be omitted")
    }
    let bothLinks = block(.text("Hello"), source: CaptureSource(url: "https://e.com", documentURL: "file:///tmp/a.pdf", page: 7))
    try require(bothLinks.contains("[Source](<https://e.com#:~:text=Hello>)") && !bothLinks.contains("page 7"), "web URL must win without a page suffix")
    let regionURL = "https://docs.example.test/doc/section#reading"
    let region = block(.image(assetPath: "assets/shot.png"), source: CaptureSource(appName: "Safari", windowTitle: "Document — Safari", url: regionURL))
    try require(region == "### Document\n\(marker("Safari"))\n\n[Source](<\(regionURL)>)\n\n![](assets/shot.png)\n",
                "region source URL must precede the saved image")
    let escapedURL = "HTTPS://example.test/a(b)/x\\y?q=<x>&r=(2)#part(3)"
    let escapedURLBlock = block(.text("Hello"), source: CaptureSource(url: escapedURL))
    try require(escapedURLBlock.contains("[Source](<https://example.test/a%28b%29/x%5Cy?q=%3Cx%3E&r=%282%29#part%283%29:~:text=Hello>)"),
                "source URL must normalize the scheme and escape Markdown delimiters")
    let percentURL = "https://example.test/path%2Fpart?next=a%20b&tag=x+y#frag%2f"
    try require(block(.text("Hello"), source: CaptureSource(url: percentURL)).contains("[Source](<\(percentURL):~:text=Hello>)"),
                "source URL must preserve valid percent escapes and query/fragment text")
    let noURL = block(.text("Hello"), source: CaptureSource(appName: "Safari"))
    for invalidURL in [
        "javascript:alert(1)", "file:///etc/passwd", "http:///missing-host", "https://",
        "https://example.test/bad%2", "https://example.test/a b", "https://exa mple.test/path",
        "https://example.test:abc/path", "https://example.test:65536/path", "https://example.test/path\nnext"
    ] {
        let invalid = block(.text("Hello"), source: CaptureSource(appName: "Safari", url: invalidURL))
        try require(invalid == noURL, "invalid source URL must be omitted: \(invalidURL.debugDescription)")
    }
    for suffix in [" — Mozilla Firefox", " - Google Chrome", " - Brave", " — Safari"] {
        try require(CaptureFormat.sourceHeading(CaptureSource(windowTitle: "Page" + suffix)) == "Page", "browser suffix remained")
    }
    let escapedImage = CaptureFormat.block(
        for: Capture(id: id, createdAt: when, content: .image(assetPath: "assets/shot.png"), source: CaptureSource()),
        noteRelativeDir: "Deep/Folder", calendar: calendar, assetPathPrefix: "../../My Vault"
    )
    try require(escapedImage.contains("![](../../My%20Vault/assets/shot.png)"), "asset links must encode path components while preserving relative traversal")
    let app = "A \"quoted\" -- app --> &quot;"
    let escaped = block(.text("Hello"), source: CaptureSource(appName: app))
    let line = escaped.components(separatedBy: "\n")[1]
    try require(line == marker("A &quot;quoted&quot; &#45;&#45; app &#45;&#45;&gt; &amp;quot;"), "marker escaping changed: \(line)")
    try require(!line.dropFirst(4).dropLast(3).contains("--"), "metadata can break the comment")
    let parsed = NoteParser.parse(contents: escaped, notePath: "N.md", titleFallback: "N", calendar: calendar)
    try require(parsed.blocks[0].sourceApp == app, "escaped app did not round-trip")
    try require(CaptureFormat.cleanSubheading("  ###  Plan\n next  ") == "Plan next", "subheading must clean to a single line")
    try require(CaptureFormat.noteHeader(title: "Plan") == "# Plan\n", "note header format changed")
    print("CaptureFormat checks passed.")
}
