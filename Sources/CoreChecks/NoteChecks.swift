import Core
import Foundation

func checkTypedNotes() async throws {
    let base = try checkMakeDirectory("typed-notes")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    try vault.prepare()
    let calendar = checkCalendar()
    let date = checkDate(2026, 10, 13, 14, 30)
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let destination = Destination(url: vault.inboxURL, title: "Inbox", kind: .inbox)
    let id = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000010")!
    let raw = "\n  typednoteneedle **bold**  \n- [ ] task\n\n  tail  \n\t"
    let note = Capture(id: id, createdAt: date, content: .note(raw), source: CaptureSource())
    let expected = "<!-- note:a1b2c3d4-0000-4000-8000-000000000010 at=2026-10-13T14:30:00+05:30 -->\n\n\n  typednoteneedle **bold**  \n- [ ] task\n\n  tail\n"
    try require(CaptureFormat.block(for: note, noteRelativeDir: "", calendar: calendar) == expected,
                "typed note must preserve internal/leading whitespace, trim only its tail, and start with local timestamp marker")
    let source = CaptureSource(appName: "Firefox", windowTitle: "System Design — Mozilla Firefox")
    let first = Capture(id: UUID(), createdAt: date, content: .text("first capture"), source: source)
    try await writer.appendIfMissing(first, to: destination)
    try await writer.appendIfMissing(note, to: destination)
    let saved = try checkRead(vault.inboxURL)
    try await writer.appendIfMissing(note, to: destination)
    let replayed = try checkRead(vault.inboxURL)
    try require(saved == replayed, "typed-note replay must be idempotent")
    let second = Capture(id: UUID(), createdAt: date, content: .text("second capture"), source: source)
    try await writer.appendIfMissing(second, to: destination)
    let grouped = try checkRead(vault.inboxURL)
    try require(grouped.components(separatedBy: "### System Design\n").count - 1 == 1,
                "typed note must not count as a source change")
    let headingNote = Capture(id: UUID(), createdAt: date, content: .note("## Typed heading\nbody"), source: CaptureSource())
    try await writer.appendIfMissing(headingNote, to: destination)
    let third = Capture(id: UUID(), createdAt: date, content: .text("third capture"), source: source)
    try await writer.appendIfMissing(third, to: destination)
    let contents = try checkRead(vault.inboxURL)
    try require(contents.components(separatedBy: "### System Design\n").count - 1 == 2,
                "heading inside typed note must force a source heading")
    let parsed = NoteParser.parse(contents: contents, notePath: "Inbox.md", titleFallback: "", calendar: calendar)
    let block = parsed.blocks.first { $0.captureID == id }
    try require(block?.kind == .note && block?.createdAt == date && block?.sourceApp == nil && block?.windowTitle == nil,
                "note parser must recover note identity/time without capture source metadata")
    try require(block?.body == CaptureFormat.noteBody(raw), "note parser must preserve its body")
    let index = try SearchIndex(vault: vault, databaseURL: base.appendingPathComponent("index.sqlite"), calendar: calendar)
    _ = try await index.sync()
    let hits = try await index.search("typednoteneedle")
    try require(hits.count == 1 && hits[0].title == "Inbox" && hits[0].createdAt == date && hits[0].captureID == id,
                "typed note keyword search must show its note title and timestamp")
    let embeddable = try await index.embeddableBlocks()
    try require(embeddable.contains { $0.kind == .note && $0.body.contains("typednoteneedle") }, "typed note must be eligible for semantic indexing")
    let count = try await index.captureCount(notePath: "Inbox.md")
    try require(count == 3, "typed notes must not increase session capture count")
    // A partial append retains its original bytes and gains one complete replay.
    let broken = vault.root.appendingPathComponent("Interrupted note.md")
    let fragment = "# Interrupted\n\n" + String(expected.prefix(95))
    try checkWrite(fragment, to: broken)
    let brokenDestination = Destination(url: broken, title: "Interrupted", kind: .note)
    try await writer.appendIfMissing(note, to: brokenDestination)
    try await writer.appendIfMissing(note, to: brokenDestination)
    let recovered = try checkRead(broken)
    let blocks = NoteParser.parse(contents: recovered, notePath: "Interrupted note.md", titleFallback: "", calendar: calendar).blocks
    try require(recovered.hasPrefix(fragment) && blocks.filter { $0.captureID == id }.count == 1 && blocks.last?.body == CaptureFormat.noteBody(raw),
                "interrupted note must replay once and preserve earlier bytes")
    try await checkIndependentNotes(vault: vault, writer: writer, index: index, base: base, date: date, calendar: calendar)
    print("Typed-note checks passed (format, source grouping, headings, parsing, search, semantic eligibility, replay).")
}

private func checkIndependentNotes(vault: Vault, writer: NoteWriter, index: SearchIndex, base: URL, date: Date, calendar: Calendar) async throws {
    let long = String(repeating: "word ", count: 15).trimmingCharacters(in: .whitespaces)
    let cases: [(String, String)] = [
        ("\n## A **clear** _heading_ ##\nbody", "A clear heading"),
        ("  - [x] Review ~~the~~ `plan`", "Review the plan"),
        ("[Link title](https://example.com) <!-- hidden -->", "Link title"),
        ("snake_case and literal ~ tilde", "snake_case and literal ~ tilde"),
        ("> - **Nested** quote", "Nested quote"),
        (" \n\t", "Note 2026-10-13 14.30"),
        ("<!-- only a comment -->", "Note 2026-10-13 14.30"),
        ("# 😀 家族 👨‍👩‍👧‍👦 計画", "😀 家族 👨‍👩‍👧‍👦 計画"),
        (long, String(repeating: "word ", count: 12).trimmingCharacters(in: .whitespaces) + "…"),
        (String(repeating: "計", count: 61), String(repeating: "計", count: 60) + "…"),
        (String(repeating: "😀", count: 61), String(repeating: "😀", count: 60) + "…")
    ]
    for (markdown, expected) in cases {
        try require(TypedNote(markdown: markdown, createdAt: date, calendar: calendar).title == expected,
                    "typed title derivation failed for \(markdown)")
    }
    for markdown in ["- title", "* title", "+ title", "1. title", "- [ ] title", "- [x] title", "> title", "`title`", "    title", "```title"] {
        try require(TypedNote(markdown: markdown, createdAt: date, calendar: calendar).body == markdown,
                    "list/task/quote/code first lines must remain in the body")
    }
    for markdown in ["Title", "# Title", "**Title**", "[Title](https://example.com)", "Title <!-- hidden -->"] {
        try require(TypedNote(markdown: markdown, createdAt: date, calendar: calendar).body.isEmpty,
                    "duplicate ordinary/heading first line must be omitted")
    }
    try require(TypedNote(markdown: "# Title\n\n  untouched  \nnext  ", createdAt: date, calendar: calendar).body == "\n  untouched  \nnext",
                "first-line removal must preserve internal whitespace")
    try require(TypedNote(markdown: "\n# Title\nbody", createdAt: date, calendar: calendar).body == "\n# Title\nbody",
                "only the physical first line may be removed")
    try require(TypedNote(markdown: long, createdAt: date, calendar: calendar).body == long,
                "truncated title must not remove the first line")
    let sessions = SessionStore(stateDirectory: base.appendingPathComponent("State"), vault: vault, calendar: calendar, now: { date })
    let service = CaptureService(vault: vault, sessions: sessions, writer: writer, now: { date })
    let pending = Capture(id: UUID(), createdAt: date, content: .note("Reserved title"), source: CaptureSource())
    let pendingFirst = await service.prepareNote(pending, calendar: calendar)
    let pendingNext = await service.prepareNote(Capture(id: UUID(), createdAt: date, content: pending.content, source: CaptureSource()), newNote: true, calendar: calendar)
    try require(pendingFirst.destination.url.lastPathComponent == "Reserved title.md" && pendingNext.destination.url.lastPathComponent == "Reserved title 2.md",
                "unsaved journal destinations must also reserve their filenames")
    let pendingAgain = await service.prepareNote(Capture(id: UUID(), createdAt: date, content: pending.content, source: CaptureSource()), calendar: calendar)
    try require(pendingAgain.destination.url.lastPathComponent == "Reserved title.md" && pendingAgain.createsNote == nil,
                "a later default append must reuse the reserved filename instead of a new root")
    let original = Capture(id: UUID(), createdAt: date, content: .note("# rootnoteneedle\n\nBody **untouched**"), source: CaptureSource())
    let prepared = await service.prepareNote(original, calendar: calendar)
    try require(prepared.destination.url.lastPathComponent == "rootnoteneedle.md" && prepared.createsNote == true,
                "outside-session typed note must choose a new root filename")
    _ = try await service.save(prepared)
    let before = try checkRead(prepared.destination.url)
    try require(before.hasPrefix("# rootnoteneedle\n\n<!-- note:") && !before.contains("\n# rootnoteneedle\n") && before.contains("Body **untouched**"), "root note header/body format")
    let journaled = try JSONDecoder().decode(PreparedCapture.self, from: JSONEncoder().encode(prepared))
    _ = try await service.save(journaled)
    let replayContents = try checkRead(prepared.destination.url)
    try require(replayContents == before && !FileManager.default.fileExists(atPath: vault.root.appendingPathComponent("rootnoteneedle 2.md").path),
                "journaled replay must reuse its chosen path without creating a second file")
    let plainDefault = await service.prepareNote(Capture(id: UUID(), createdAt: date, content: original.content, source: CaptureSource()), calendar: calendar)
    try require(plainDefault.destination.url.lastPathComponent == "rootnoteneedle.md" && plainDefault.createsNote == nil,
                "a default typed note whose title already exists must append to that note")
    let collision = await service.prepareNote(Capture(id: UUID(), createdAt: date, content: original.content, source: CaptureSource()), newNote: true, calendar: calendar)
    _ = try await service.save(collision)
    try require(collision.destination.url.lastPathComponent == "rootnoteneedle 2.md", "independent notes with the same title need the existing collision suffix")
    // The persisted identity still denotes a saved note after external body edits.
    let edited = before.replacingOccurrences(of: "Body **untouched**", with: "Edited body")
    try checkWrite(edited, to: prepared.destination.url)
    _ = try await service.save(journaled)
    let editedReplay = try checkRead(prepared.destination.url)
    try require(editedReplay == edited, "existing new-note marker must make replay idempotent after edits")
    let titleOnly = await service.prepareNote(Capture(id: UUID(), createdAt: date, content: .note("# titleonlyneedle"), source: CaptureSource()), calendar: calendar)
    _ = try await service.save(titleOnly)
    _ = try await index.sync()
    let hit = try await index.search("titleonlyneedle").first
    try require(hit?.title == "titleonlyneedle" && hit?.blockKind == .note && hit?.body == "", "marker-only notes must parse and be searchable by their title")
    let inboxNote = await service.prepareNote(Capture(id: UUID(), createdAt: date, content: .note("Inbox"), source: CaptureSource()), calendar: calendar)
    try require(inboxNote.destination.url == vault.inboxURL && inboxNote.destination.kind == .inbox && inboxNote.createsNote == nil,
                "a typed note titled Inbox must route to Inbox.md")
    let blankFirst = await service.prepareNote(Capture(id: UUID(), createdAt: date, content: .note("\n\nfirst body"), source: CaptureSource()), calendar: calendar)
    let blankSecond = await service.prepareNote(Capture(id: UUID(), createdAt: date, content: .note("\n\nsecond body"), source: CaptureSource()), calendar: calendar)
    try require(blankFirst.destination.url.lastPathComponent == "first body.md" && blankSecond.destination.url.lastPathComponent == "second body.md"
                && blankFirst.createsNote == true && blankSecond.createsNote == true,
                "a note whose first line is blank must take its title from the first text line")
    try checkWrite("# Buy milk\n", to: vault.root.appendingPathComponent("Buy milk.md"))
    let buyMilk = await service.prepareNote(Capture(id: UUID(), createdAt: date, content: .note("Buy milk"), source: CaptureSource()), calendar: calendar)
    try require(buyMilk.destination.url.lastPathComponent == "Buy milk.md" && buyMilk.createsNote == nil && buyMilk.capture.content == .note("Buy milk"),
                "a title-only typed note must append to the existing note with that title")
    _ = try await sessions.start(name: "Typed session")
    let inSession = await service.prepareNote(original, calendar: calendar)
    try require(inSession.destination.kind == .session && inSession.capture.content == original.content && inSession.createsNote != true,
                "session typed notes must retain their full body and append destination")
    print("Independent-note checks passed (title table/Unicode, first-line rules, creation/collisions, fixed-path replay, marker identity, title-only search, session routing).")
}
