import Core
import Foundation

func checkTypedNotes() async throws {
    let base = try checkMakeDirectory("typed-notes")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    try vault.prepare()
    for unsafePath in ["folder\\name.md", "folder/name\u{0007}.md"] {
        do {
            _ = try vault.fileSnapshot(relativePath: unsafePath)
            throw CheckFailure.failed("managed relative identity path accepted unsafe component: \(unsafePath.debugDescription)")
        } catch let error as POSIXError {
            try require(error.code == .EPERM,
                        "managed relative identity path should reject backslash and control characters")
        }
    }
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
    let nestedTyped = TypedNote(markdown: "# science/math/trigonometry\n\nBody", createdAt: date, calendar: calendar)
    try require(nestedTyped.rawName == "science/math/trigonometry" && nestedTyped.pathName?.components == ["science", "math", "trigonometry"] &&
                nestedTyped.title == "trigonometry" && nestedTyped.body == "\nBody",
                "typed note should retain its full path while displaying and saving only the leaf title")
    let longNestedLeaf = String(repeating: "word ", count: 15).trimmingCharacters(in: .whitespaces)
    let longNested = TypedNote(markdown: "# science/math/\(longNestedLeaf)\nBody", createdAt: date, calendar: calendar)
    try require(longNested.pathName?.components.last == longNestedLeaf && longNested.title.hasSuffix("…"),
                "long folder-qualified typed names must resolve the full leaf before display truncation")
    let unsafeTyped = TypedNote(markdown: "# science/../escape\nBody", createdAt: date, calendar: calendar)
    try require(unsafeTyped.pathName == nil && unsafeTyped.pathNameError == .invalidComponent,
                "typed note traversal must retain its path validation error")
    for path in ["folder/ ../outside", "folder/. /outside"] {
        let typed = TypedNote(markdown: "# \(path)\nBody", createdAt: date, calendar: calendar)
        try require(typed.pathName == nil && typed.pathNameError == .invalidComponent,
                    "whitespace must not turn a traversal component into an ordinary flat name: \(path)")
    }
    for (name, stem) in [
        ("Read https://example.com", "Read https---example.com"),
        ("TODO/", "TODO-"),
        ("a//b", "a--b"),
        ("pros / cons of X", "pros - cons of X")
    ] {
        let typed = TypedNote(markdown: "# \(name)\n\nFallback body", createdAt: date, calendar: calendar)
        try require(typed.pathName?.scope == .vault && typed.pathName?.components == [stem] && typed.title == name &&
                    typed.body == "\nFallback body",
                    "malformed relative slash input should retain an ordinary note name: \(name)")
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
    for (index, item) in [
        ("Read https://example.com", "Read https---example.com.md"),
        ("TODO/", "TODO-.md"),
        ("a//b", "a--b.md"),
        ("pros / cons of X", "pros - cons of X.md")
    ].enumerated() {
        let capture = Capture(id: UUID(), createdAt: date,
                              content: .note("# \(item.0)\n\nFallback body \(index)"), source: CaptureSource())
        let preparedFallback = try await service.prepareNote(capture, calendar: calendar)
        try require(preparedFallback.destination.url.lastPathComponent == item.1,
                    "malformed relative slash input should prepare a flat safe filename: \(item.0)")
        _ = try await service.save(preparedFallback)
        let fallbackContents = try checkRead(preparedFallback.destination.url)
        try require(fallbackContents.hasPrefix("# \(item.0)\n\n<!-- note:"),
                    "malformed relative slash input should save as an ordinary note: \(item.0)")
    }
    let tooDeepName = Array(repeating: "x", count: 33).joined(separator: "/")
    let tooLongComponent = String(repeating: "x", count: 120)
    let tooLongName = Array(repeating: tooLongComponent, count: 8).joined(separator: "/")
    for (rawName, expectedError) in [
        ("science/../escape", NotePathNameError.invalidComponent),
        ("folder/ ../outside", NotePathNameError.invalidComponent),
        ("folder/. /outside", NotePathNameError.invalidComponent),
        ("/Desktop/../escape", NotePathNameError.invalidComponent),
        ("folder/name\u{0000}", NotePathNameError.invalidComponent),
        ("folder/~$draft", NotePathNameError.invalidComponent),
        (tooDeepName, NotePathNameError.tooDeep),
        (tooLongName, NotePathNameError.tooLong)
    ] {
        let typed = TypedNote(markdown: "# \(rawName)\nBody", createdAt: date, calendar: calendar)
        try require(typed.pathName == nil && typed.pathNameError == expectedError,
                    "explicit invalid path should retain its specific validation error: \(expectedError)")
        let invalidCapture = Capture(id: UUID(), createdAt: date, content: .note("# \(rawName)\nBody"), source: CaptureSource())
        do {
            _ = try await service.prepareNote(invalidCapture, calendar: calendar)
            throw CheckFailure.failed("invalid explicit path unexpectedly prepared: \(rawName)")
        } catch let error as NotePathNameError {
            try require(error == expectedError, "typed note path should throw \(expectedError), got \(error)")
        }
    }
    let pending = Capture(id: UUID(), createdAt: date, content: .note("Reserved title"), source: CaptureSource())
    let pendingFirst = try await service.prepareNote(pending, calendar: calendar)
    let pendingNext = try await service.prepareNote(Capture(id: UUID(), createdAt: date, content: pending.content, source: CaptureSource()), calendar: calendar)
    try require(pendingFirst.destination.url.lastPathComponent == "Reserved title.md" && pendingNext.destination.url.lastPathComponent == "Reserved title 2.md",
                "unsaved journal destinations must also reserve their filenames")
    let original = Capture(id: UUID(), createdAt: date, content: .note("# rootnoteneedle\n\nBody **untouched**"), source: CaptureSource())
    let prepared = try await service.prepareNote(original, calendar: calendar)
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
    let collisionCapture = Capture(id: UUID(), createdAt: date, content: original.content, source: CaptureSource())
    let collision = try await service.prepareNote(collisionCapture, calendar: calendar)
    _ = try await service.save(collision)
    let afterCollision = try checkRead(prepared.destination.url)
    try require(collision.destination.url == prepared.destination.url && collision.createsNote != true && collision.noteMarkerIsIdentity == true,
                "typed note collisions should append to the existing canonical target")
    try require(afterCollision.components(separatedBy: "<!-- note:\(collisionCapture.id.uuidString.lowercased()) at=").count - 1 == 1,
                "appending a typed note to an existing target should preserve its identity marker")
    let journaledCollision = try JSONDecoder().decode(PreparedCapture.self, from: JSONEncoder().encode(collision))
    _ = try await service.save(journaledCollision)
    let afterCollisionReplay = try checkRead(prepared.destination.url)
    try require(afterCollisionReplay == afterCollision,
                "replaying an appended typed-note collision must not duplicate its marker")
    var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)) as! [String: Any]
    legacyObject.removeValue(forKey: "noteMarkerIsIdentity")
    let legacyPrepared = try JSONDecoder().decode(PreparedCapture.self, from: JSONSerialization.data(withJSONObject: legacyObject))
    try require(legacyPrepared.createsNote == true && legacyPrepared.noteMarkerIsIdentity == nil,
                "older journal records without noteMarkerIsIdentity must continue to decode")

    let nestedCapture = Capture(id: UUID(), createdAt: date,
                                content: .note("# science/math/trigonometry\n\nNested typed body"), source: CaptureSource())
    let nestedPrepared = try await service.prepareNote(nestedCapture, calendar: calendar)
    try require(nestedPrepared.destination.url == vault.root.appendingPathComponent("science/math/trigonometry.md") &&
                nestedPrepared.destination.title == "trigonometry",
                "folder-qualified typed note should target the nested path and use its leaf title")
    _ = try await service.save(nestedPrepared)
    let nestedContents = try checkRead(nestedPrepared.destination.url)
    try require(nestedContents.hasPrefix("# trigonometry\n") && nestedContents.contains("Nested typed body") &&
                !nestedContents.contains("\n# science/math/trigonometry\n"),
                "typed note path should determine a leaf-title header without duplicating the name in its body")
    _ = try await index.sync()
    let nestedHit = try await index.search("Nested typed body").first
    try require(nestedHit?.notePath == "science/math/trigonometry.md" && nestedHit?.title == "trigonometry",
                "nested typed note should be indexed at its relative path with its leaf title")
    // The persisted identity still denotes a saved note after external body edits.
    let edited = afterCollision.replacingOccurrences(of: "Body **untouched**", with: "Edited body")
    try checkWrite(edited, to: prepared.destination.url)
    _ = try await service.save(journaled)
    let editedReplay = try checkRead(prepared.destination.url)
    try require(editedReplay == edited, "existing new-note marker must make replay idempotent after edits")
    let titleOnly = try await service.prepareNote(Capture(id: UUID(), createdAt: date, content: .note("# titleonlyneedle"), source: CaptureSource()), calendar: calendar)
    _ = try await service.save(titleOnly)
    _ = try await index.sync()
    let hit = try await index.search("titleonlyneedle").first
    try require(hit?.title == "titleonlyneedle" && hit?.blockKind == .note && hit?.body == "", "marker-only notes must parse and be searchable by their title")
    _ = try await sessions.start(name: "Typed session")
    let inSession = try await service.prepareNote(original, calendar: calendar)
    try require(inSession.destination.kind == .session && inSession.capture.content == original.content && inSession.createsNote != true,
                "session typed notes must retain their full body and append destination")
    print("Independent-note checks passed (title table/Unicode, first-line rules, creation/collisions, fixed-path replay, marker identity, title-only search, session routing).")
}
