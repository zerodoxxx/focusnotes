@_spi(Checks) import Core
import Foundation

func checkCaptureMoves() async throws {
    func verify(_ value: Bool, _ message: String) throws { try require(value, message) }
    let base = try checkMakeDirectory("capture-moves")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    let calendar = checkCalendar()
    let now = checkDate(2026, 10, 13, 10, 0)
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let sessions = SessionStore(stateDirectory: base.appendingPathComponent("State"), vault: vault,
                                calendar: calendar, now: { now })
    let service = CaptureService(vault: vault, sessions: sessions, writer: writer, now: { now })
    func note(_ path: String) -> Destination {
        Destination(url: vault.root.appendingPathComponent(path + ".md"), title: path, kind: .note)
    }
    func save(_ id: UUID, _ body: String, to destination: Destination) async throws {
        let capture = Capture(id: id, createdAt: now, content: .text(body), source: CaptureSource(appName: "Safari"))
        _ = try await service.save(PreparedCapture(capture: capture, destination: destination))
    }
    let a = note("A"), b = note("B")
    let first = UUID(), second = UUID()
    try await save(first, "first body", to: a)
    try await save(second, "second body", to: a)
    let original = try checkRead(a.url)
    let markerLine = original.components(separatedBy: "\n").first { $0.hasPrefix("<!-- capture:") }!
    let moved = try await service.moveCapture(id: first, from: a, to: b)
    let remaining = try checkRead(a.url), target = try checkRead(b.url)
    try verify(moved.destination == b && moved.captureID == first, "move returns destination and identity")
    try verify(!remaining.contains(checkCaptureMarker(first)) && !remaining.contains("first body"), "source loses moved capture")
    try verify(target.contains(markerLine) && target.contains("first body") && target.contains("### Safari"), "destination preserves marker, body and heading")
    try verify(remaining.contains("### Safari") && remaining.contains("second body"), "first move retains shared source heading")

    // Moving a grouped second capture must leave its earlier heading untouched.
    let grouped = note("Grouped"), groupedTarget = note("Grouped target")
    let g1 = UUID(), g2 = UUID()
    try await save(g1, "group one", to: grouped)
    try await save(g2, "group two", to: grouped)
    _ = try await service.moveCapture(id: g2, from: grouped, to: groupedTarget)
    try verify(try checkRead(grouped.url).contains("### Safari"), "grouped capture never removes earlier heading")
    try verify(try checkRead(groupedTarget.url).contains("### Safari"), "grouped capture carries source heading")

    let image = try await service.saveImage(png: Data([1, 2, 3]), source: CaptureSource(appName: "Preview"), noteTitle: "Images")
    let imageText = try checkRead(image.destination.url)
    let imageLine = imageText.components(separatedBy: "\n").first { $0.hasPrefix("![](") }!
    let assetPath = String(imageLine.dropFirst(4).dropLast())
    let nested = note("Sessions/Nested")
    _ = try await service.moveCapture(id: image.captureID, from: image.destination, to: nested)
    let expectedCapture = Capture(id: image.captureID, createdAt: now, content: .image(assetPath: assetPath), source: CaptureSource(appName: "Preview"))
    let expectedImage = CaptureFormat.block(for: expectedCapture, noteRelativeDir: "Sessions", calendar: calendar)
        .components(separatedBy: "\n").first { $0.hasPrefix("![](") }!
    try verify(try checkRead(nested.url).contains(expectedImage), "moved image matches destination format")
    try verify(FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(assetPath).path), "move leaves PNG in place")

    let links = note("Links"), linksTarget = note("Sessions/Links")
    let linksID = UUID()
    try await save(linksID, "![one](assets/a%20b.png) ![two](<assets/c d.png>) ![three](assets/a(b).png) ![web](https://example.com/a.png) ![absolute](/tmp/a.png)", to: links)
    _ = try await service.moveCapture(id: linksID, from: links, to: linksTarget)
    let rewrittenLinks = try checkRead(linksTarget.url)
    try verify(rewrittenLinks.contains("![one](../assets/a%20b.png)") && rewrittenLinks.contains("![two](<../assets/c%20d.png>)") && rewrittenLinks.contains("![three](../assets/a%28b%29.png)"), "all relative images are resolved and encoded")
    try verify(rewrittenLinks.contains("![web](https://example.com/a.png)") && rewrittenLinks.contains("![absolute](/tmp/a.png)"), "absolute and scheme links remain unchanged")

    let edited = note("Edited"), editedTarget = note("Edited target")
    let e1 = UUID(), e2 = UUID()
    try await save(e1, "original body", to: edited)
    var editedText = try checkRead(edited.url)
    editedText += "\nuser annotation\n<!-- thought:x -->\n\n"
    try checkWrite(editedText, to: edited.url)
    try await save(e2, "following capture", to: edited)
    try checkWrite(try checkRead(edited.url) + "\n## Stay here\nsection body\n", to: edited.url)
    _ = try await service.moveCapture(id: e1, from: edited, to: editedTarget)
    let editedRemaining = try checkRead(edited.url), editedMoved = try checkRead(editedTarget.url)
    try verify(editedMoved.contains("user annotation\n<!-- thought:x -->"), "unknown comments and annotations travel")
    try verify(!editedMoved.contains("following capture") && !editedMoved.contains("Stay here") && editedRemaining.contains("following capture") && editedRemaining.contains("section body"), "next capture and section remain")
    _ = try await service.moveCapture(id: e2, from: edited, to: editedTarget)
    try verify(try checkRead(edited.url).contains("## Stay here\nsection body"), "heading bounds stop the second block")
    try verify(!checkRead(edited.url).contains("\n\n\n"), "removal leaves no excess blank lines")

    // A note block between captures must not orphan the heading that later captures share.
    let gapSource = note("Heading gap"), gapTarget = note("Heading gap target")
    let gapA = UUID(), gapB = UUID(), gapNote = UUID()
    try checkWrite("### Safari\n\(checkCaptureMarker(gapA)) -->\ngap first\n\n<!-- note:\(gapNote.uuidString.lowercased()) -->\ngap note\n\n\(checkCaptureMarker(gapB)) -->\ngap second\n", to: gapSource.url)
    _ = try await service.moveCapture(id: gapA, from: gapSource, to: gapTarget)
    let gapRemaining = try checkRead(gapSource.url)
    try verify(gapRemaining.contains("### Safari") && gapRemaining.contains("gap note") && gapRemaining.contains("gap second"), "heading survives a note block before a later capture")
    try verify(!gapRemaining.contains("gap first") && !gapRemaining.contains(checkCaptureMarker(gapA)), "moved capture leaves the source")

    let aBytes = try Data(contentsOf: a.url), bBytes = try Data(contentsOf: b.url)
    do {
        _ = try await service.moveCapture(id: UUID(), from: a, to: b)
        throw CheckFailure.failed("unknown capture moved")
    } catch let error as CaptureMoveError {
        try verify(error == .notFound(noteTitle: a.title), "unknown identity reports notFound")
    }
    try verify(try Data(contentsOf: a.url) == aBytes && Data(contentsOf: b.url) == bBytes, "notFound changes neither note")
    _ = try await service.moveCapture(id: second, from: a, to: a)
    try verify(try Data(contentsOf: a.url) == aBytes, "same-note move writes nothing")

    let rollbackSource = note("Rollback source"), rollbackTarget = note("Rollback target")
    let rollbackID = UUID()
    try await save(rollbackID, "retain original", to: rollbackSource)
    let beforeRollback = try Data(contentsOf: rollbackSource.url)
    await writer.setBeforeCaptureMoveRemoval { _ in throw CocoaError(.fileWriteNoPermission) }
    do {
        _ = try await service.moveCapture(id: rollbackID, from: rollbackSource, to: rollbackTarget)
        throw CheckFailure.failed("injected removal failure succeeded")
    } catch let error as CaptureMoveError {
        try verify(error == .writeFailed(noteTitle: rollbackSource.title), "removal failure identifies source")
    }
    await writer.setBeforeCaptureMoveRemoval(nil)
    try verify(try Data(contentsOf: rollbackSource.url) == beforeRollback, "failed removal retains byte-identical source")
    try verify(try !checkRead(rollbackTarget.url).contains(checkCaptureMarker(rollbackID)), "failed removal rolls destination back")

    // A real intervening edit must be detected without overwriting that edit.
    await writer.setBeforeCaptureMoveRemoval { url in
        let data = try Data(contentsOf: url)
        try (data + Data("external edit\n".utf8)).write(to: url)
    }
    do {
        _ = try await service.moveCapture(id: rollbackID, from: rollbackSource, to: rollbackTarget)
        throw CheckFailure.failed("changed source was overwritten")
    } catch let error as CaptureMoveError {
        try verify(error == .sourceChanged(noteTitle: rollbackSource.title), "intervening edit reports sourceChanged")
    }
    await writer.setBeforeCaptureMoveRemoval(nil)
    try verify(try Data(contentsOf: rollbackSource.url) == beforeRollback + Data("external edit\n".utf8), "intervening edit survives")
    try verify(try !checkRead(rollbackTarget.url).contains(checkCaptureMarker(rollbackID)), "sourceChanged rolls destination back")

    // Existing UUIDs are idempotent even when their destination body was edited.
    let duplicateSource = note("Duplicate source"), duplicateTarget = note("Duplicate target")
    let duplicateID = UUID()
    try await save(duplicateID, "source version", to: duplicateSource)
    try await save(duplicateID, "edited target version", to: duplicateTarget)
    let existingTarget = try Data(contentsOf: duplicateTarget.url)
    _ = try await service.moveCapture(id: duplicateID, from: duplicateSource, to: duplicateTarget)
    try verify(try Data(contentsOf: duplicateTarget.url) == existingTarget, "existing UUID is not appended again")

    let invalidSource = note("Typed marker")
    let typedID = UUID()
    try checkWrite("# Typed\n<!-- note:\(typedID.uuidString.lowercased()) -->\nbody\n", to: invalidSource.url)
    let typedBytes = try Data(contentsOf: invalidSource.url)
    do {
        _ = try await service.moveCapture(id: typedID, from: invalidSource, to: b)
        throw CheckFailure.failed("typed note marker was moved")
    } catch let error as CaptureMoveError {
        try verify(error == .notFound(noteTitle: invalidSource.title), "typed marker is not a plain capture")
    }
    try verify(try Data(contentsOf: invalidSource.url) == typedBytes, "typed marker remains untouched")

    let blocked = note("Blocked")
    try FileManager.default.createDirectory(at: blocked.url, withIntermediateDirectories: true)
    let beforeBlocked = try Data(contentsOf: a.url)
    do {
        _ = try await service.moveCapture(id: second, from: a, to: blocked)
        throw CheckFailure.failed("directory destination accepted")
    } catch let error as CaptureMoveError {
        try verify(error == .writeFailed(noteTitle: blocked.title), "append failure identifies destination")
    }
    try verify(try Data(contentsOf: a.url) == beforeBlocked, "append failure retains source bytes")

    let sectionNote = note("Sections")
    try checkWrite("# Sections\n\n## First\n```swift\n## Ignored\n```\n## Last\n~~~\n## Also ignored\n~~~\n", to: sectionNote.url)
    let section = try await service.section(of: sectionNote)
    try verify(section == "Last", "section returns last heading outside fences")
    let saved = try await service.save(PreparedCapture(capture: Capture(id: UUID(), createdAt: now, content: .text("section capture"), source: CaptureSource()), destination: sectionNote))
    try verify(saved.section == "Last", "save includes destination section")
    let noSection = try await service.section(of: b)
    let missingSection = try await service.section(of: note("Missing"))
    try verify(noSection == nil && missingSection == nil, "no heading and missing file return nil")
    try checkWrite("## Outside\n````swift\n```\n## Hidden\n````\n", to: sectionNote.url)
    let longFenceSection = try await service.section(of: sectionNote)
    try verify(longFenceSection == "Outside", "shorter fences do not close a longer code fence")
    print("Capture move and section checks passed.")
}
