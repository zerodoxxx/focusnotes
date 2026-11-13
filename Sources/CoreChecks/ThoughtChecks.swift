@_spi(Checks) import Core
import Foundation

func checkThoughts() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 19_800)!
    let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14, minute: 30))!
    let id = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000000F")!
    let unknown = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    let marker = "<!-- capture:a1b2c3d4-0000-4000-8000-00000000000f at=2026-10-13T14:30:00+05:30 app=\"Safari\" -->"
    let thought = "<!-- thought:a1b2c3d4-0000-4000-8000-00000000000f at=2026-10-13T14:30:00+05:30 -->\n**My thought**\n\n  Reflect é\nnext"
    func set(_ text: String?, _ contents: String, capture: UUID = id) -> String? {
        CaptureFormat.settingThought(text, forCapture: capture, in: contents, at: date, calendar: calendar)
    }
    func exact(_ actual: String?, _ expected: String, _ label: String) throws {
        try require(actual == expected, "thought \(label): got \(String(describing: actual?.debugDescription))")
        print("PASS thought \(label)")
    }
    let text = "  Reflect é\nnext \n\t"
    try exact(CaptureFormat.thoughtBlock(captureID: id, text: text, createdAt: date, calendar: calendar),
              thought + "\n", "1 exact block")
    let body = "# N\n\n### Safari\n" + marker + "\n\nHello é  "
    let next = "### Next\n<!-- capture:00000000-0000-4000-8000-000000000002 -->\n\nOther\n"
    let middle = body + "\n\n\n" + next
    let inserted = body + "\n\n" + thought + "\n\n\n" + next
    try exact(set(text, middle), inserted, "2 middle heading")
    let last = body + "\n"
    let lastInserted = body + "\n\n" + thought + "\n"
    try exact(set(text, last), lastInserted, "3 final newline")
    try require(lastInserted.hasSuffix("\n") && !lastInserted.hasSuffix("\n\n"), "one final newline")
    let old = body + "\n\n\n<!-- thought:a1b2c3d4-0000-4000-8000-00000000000f at=old -->\n**My thought**\n\nOld\n\n\n" + next
    try exact(set(text, old), inserted, "4 replacement spacing")
    try exact(set(nil, inserted), middle, "5 insert remove round trip")
    try exact(set(" \n\t", lastInserted), last, "5 blank removes")
    try exact(set(nil, middle), middle, "6 absent removal")
    try require(set(text, middle, capture: unknown) != nil, "next capture exists")
    try require(set(text, body, capture: unknown) == nil, "unknown capture must return nil")
    let note = "<!-- note:a1b2c3d4-0000-4000-8000-00000000000f at=old -->\n\nNote\n"
    try require(set(text, note) == nil, "note marker must not match")
    try require(set(text, "## Title\n<!-- subheading:a1b2c3d4-0000-4000-8000-00000000000f -->\n") == nil,
                "subheading marker must not match")
    print("PASS thought 7 unknown and non-capture markers")
    try exact(set(text, last + "\n" + last), last + "\n" + lastInserted, "8 duplicate last occurrence")
    let image = marker + "\n\n![](assets/x.png)\n"
    try exact(set(text, image), marker + "\n\n![](assets/x.png)\n\n" + thought + "\n", "9 image")
    try exact(set(text, body), body + "\n\n" + thought, "no final newline")
    try exact(set(nil, body + "\n\n" + thought), body, "remove without final newline")
    let subheading = "## Section\n<!-- subheading:00000000-0000-4000-8000-000000000002 -->\n"
    try exact(set(text, body + "\n \n" + subheading), body + "\n\n" + thought + "\n \n" + subheading,
              "subheading and whitespace separator")

    let base = try checkMakeDirectory("thought")
    defer { checkRemoveDirectory(base) }
    let root = base.appendingPathComponent("Vault", isDirectory: true)
    let vault = Vault(root: root, homeDirectoryURL: base.appendingPathComponent("Home", isDirectory: true))
    try vault.prepare()
    let url = root.appendingPathComponent("Thought.md")
    try checkWrite(middle, to: url)
    let writer = NoteWriter(vault: vault, calendar: calendar)
    try await writer.setThought(text, forCapture: id, inNoteAt: url, at: date)
    let written = try checkRead(url)
    try exact(written, inserted, "10 writer contents")
    let before = try Data(contentsOf: url)
    do {
        try await writer.setThought(text, forCapture: UUID(), inNoteAt: url, at: date)
        throw CheckFailure.failed("unknown writer capture must throw")
    } catch ThoughtWriteError.captureNotFound {}
    let after = try Data(contentsOf: url)
    try require(after == before, "unknown writer capture changed bytes")
    let missing = root.appendingPathComponent("Missing.md")
    do {
        try await writer.setThought(text, forCapture: id, inNoteAt: missing, at: date)
        throw CheckFailure.failed("missing file must throw a read error")
    } catch is POSIXError {}
    try require(!FileManager.default.fileExists(atPath: missing.path), "missing file was created")
    try await writer.setThought(nil, forCapture: id, inNoteAt: url, at: date)
    let removed = try checkRead(url)
    try exact(removed, middle, "10 writer removal")
    let capture = Capture(id: unknown, createdAt: date, content: .text("Appended"), source: CaptureSource(appName: "Safari"))
    try await writer.append(capture, to: url, title: "N")
    let appended = try checkRead(url)
    try require(appended.hasPrefix(middle) && appended.contains("Appended\n"), "append after rewrite failed")
    print("PASS thought 10 unknown unchanged, missing read error, append after rewrite")
    try checkThoughtParsing()
    try await checkThoughtSearch()
}

func checkThoughtParsing() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 19_800)!
    let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14, minute: 30))!
    let id = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000000F")!
    let other = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    let marker = "<!-- capture:a1b2c3d4-0000-4000-8000-00000000000f at=2026-10-13T14:30:00+05:30 app=\"Safari\" -->"
    let thought = CaptureFormat.thoughtBlock(captureID: id, text: "Reflect é\nnext", createdAt: date, calendar: calendar)
    func parse(_ contents: String) -> [ParsedBlock] {
        NoteParser.parse(contents: contents, notePath: "Thought.md", titleFallback: "Thought", calendar: calendar).blocks
    }
    func expect(_ blocks: [ParsedBlock], body: String, thought expected: String?, _ label: String) throws {
        try require(blocks.count == 1, "thought parse \(label): expected one block, got \(blocks.count)")
        let block = blocks[0]
        try require(block.body == body && block.thought == expected,
                    "thought parse \(label): body \(block.body.debugDescription), thought \(String(describing: expected?.debugDescription))")
        print("PASS thought parse \(label)")
    }
    try expect(parse("# Thought\n\n" + marker + "\n\nHello body\n\n" + thought),
               body: "Hello body", thought: "Reflect é\nnext", "text capture")
    let image = parse("# Thought\n\n" + marker + "\n\n![](assets/x.png)\n\n" + thought)
    try require(image.count == 1 && image[0].kind == .image && image[0].assetPath == "assets/x.png",
                "image capture with a thought must remain an image")
    try expect(image, body: "![](assets/x.png)", thought: "Reflect é\nnext", "image capture")
    let otherThought = CaptureFormat.thoughtBlock(captureID: other, text: "Elsewhere", createdAt: date, calendar: calendar)
    try expect(parse("# Thought\n\n" + marker + "\n\nHello body\n\n" + otherThought),
               body: "Hello body\n\n" + otherThought.dropLast(), thought: nil, "other capture's thought stays in body")
    try expect(parse("# Thought\n\n" + marker + "\n\nHello body\n"), body: "Hello body", thought: nil, "capture without thought")
    let labelless = "<!-- thought:a1b2c3d4-0000-4000-8000-00000000000f at=2026-10-13T14:30:00+05:30 -->\n\nPlain thought\n"
    try expect(parse("# Thought\n\n" + marker + "\n\nHello body\n\n" + labelless),
               body: "Hello body", thought: "Plain thought", "label-less thought")
}

func checkThoughtSearch() async throws {
    let base = try checkMakeDirectory("thought-search")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    try vault.prepare()
    let calendar = checkCalendar()
    let date = checkDate(2026, 10, 13, 14, 30)
    let id = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000000F")!
    let marker = "<!-- capture:\(id.uuidString.lowercased()) at=2026-10-13T14:30:00+05:30 app=\"Safari\" -->"
    let thought = CaptureFormat.thoughtBlock(captureID: id, text: "thoughtonlyneedle", createdAt: date, calendar: calendar)
    try checkWrite("# Thought\n\n\(marker)\n\nbodyonlyneedle\n\n\(thought)", to: vault.root.appendingPathComponent("Thought.md"))
    let index = try SearchIndex(vault: vault, databaseURL: base.appendingPathComponent("index.sqlite"), calendar: calendar)
    _ = try await index.sync()
    let hits = try await index.search("thoughtonlyneedle")
    try require(hits.count == 1 && hits[0].notePath == "Thought.md",
                "a word found only in a capture's thought must match that capture")
    print("PASS thought search finds thought-only word")
}
