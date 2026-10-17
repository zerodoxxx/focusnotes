import Core
import Foundation

func checkCaptureService() async throws {
    let base = try checkMakeDirectory("capture")
    defer { checkRemoveDirectory(base) }
    let calendar = checkCalendar()
    let vault = Vault(root: base.appendingPathComponent("Vault", isDirectory: true))
    let stateDirectory = base.appendingPathComponent("State", isDirectory: true)
    let now = checkDate(2026, 10, 13, 10, 0)
    let clock: @Sendable () -> Date = { now }
    let captureID = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!
    let makeID: @Sendable () -> UUID = { captureID }

    let sessions = SessionStore(stateDirectory: stateDirectory, vault: vault, calendar: calendar, now: clock)
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let service = CaptureService(vault: vault, sessions: sessions, writer: writer, now: clock, makeID: makeID)
    let png = Data([0x89, 0x50, 0x4E, 0x47])

    // No active session: text goes to Inbox.md.
    let inboxSave = try await service.saveText("Hello inbox", source: CaptureSource(appName: "Safari"), noteTitle: nil)
    try require(inboxSave.captureID == captureID, "saveText should return the capture id")
    try require(inboxSave.destination.kind == .inbox, "no active session should route to Inbox")
    try require(
        inboxSave.destination.url.path == vault.inboxURL.path,
        "Inbox destination path was \(inboxSave.destination.url.path)"
    )
    let inboxText = try checkRead(vault.inboxURL)
    try require(inboxText.contains("Hello inbox"), "Inbox.md should contain the capture text")
    try require(inboxText.contains(checkCaptureMarker(captureID)), "Inbox.md should contain the capture marker")

    // Active session: text goes to the session note, not Inbox.md.
    _ = try await sessions.start(name: "Design")
    let sessionURL = vault.sessionsURL.appendingPathComponent("Design.md")
    let sessionSave = try await service.saveText("Into session", source: CaptureSource(appName: "Xcode"), noteTitle: nil)
    try require(sessionSave.destination.kind == .session, "an active session should route to the session note")
    try require(
        sessionSave.destination.url.path == sessionURL.path,
        "session destination path was \(sessionSave.destination.url.path)"
    )
    let sessionText = try checkRead(sessionURL)
    try require(
        sessionText.contains("### Xcode\n"),
        "session note should hold the Xcode block heading"
    )
    try require(sessionText.contains("Into session"), "session note should contain the text")
    let inboxAfterSession = try checkRead(vault.inboxURL)
    try require(!inboxAfterSession.contains("Into session"), "session text must not go to Inbox.md")

    // An explicit note title overrides the active session.
    let titleSave = try await service.saveText("Heading wins", source: CaptureSource(), noteTitle: "Inbox")
    try require(titleSave.destination.kind == .inbox, "title Inbox should beat the active session")
    let inboxAfterTitle = try checkRead(vault.inboxURL)
    try require(inboxAfterTitle.contains("Heading wins"), "capture should land in Inbox.md")

    // An image in the session note links to ../assets/ and the PNG exists.
    let imageSave = try await service.saveImage(png: png, source: CaptureSource(appName: "Preview"), noteTitle: nil)
    try require(imageSave.destination.kind == .session, "an image with an active session should route to the session note")
    let sessionWithImage = try checkRead(sessionURL)
    guard let linkStart = sessionWithImage.range(of: "![](../assets/") else {
        throw CheckFailure.failed("session note has no ../assets image link")
    }
    guard let linkEnd = sessionWithImage[linkStart.lowerBound...].firstIndex(of: ")") else {
        throw CheckFailure.failed("image link in the session note is not closed")
    }
    let link = String(sessionWithImage[linkStart.lowerBound..<linkEnd])
    let linkPrefix = "![](../"
    let assetRelativePath = String(link.dropFirst(linkPrefix.count))
    try require(
        assetRelativePath.hasPrefix("assets/") && assetRelativePath.hasSuffix(".png"),
        "unexpected asset link \(assetRelativePath)"
    )
    let assetURL = vault.root.appendingPathComponent(assetRelativePath)
    try require(FileManager.default.fileExists(atPath: assetURL.path), "linked PNG should exist at \(assetURL.path)")
    let assetData = try Data(contentsOf: assetURL)
    try require(assetData == png, "saved PNG bytes differ from the input")

    // An image in Inbox.md links to assets/ directly.
    let inboxImage = try await service.saveImage(png: png, source: CaptureSource(), noteTitle: "Inbox")
    try require(inboxImage.destination.kind == .inbox, "title Inbox should route the image to Inbox.md")
    let inboxWithImage = try checkRead(vault.inboxURL)
    try require(inboxWithImage.contains("![](assets/"), "Inbox image link should point at assets/ directly")
    try require(!inboxWithImage.contains("![](../"), "Inbox image link must not use ../")
    // A failed write and replay both reuse the prepared identity and destination.
    let retryID = UUID()
    let retryCapture = Capture(id: retryID, createdAt: now, content: .text("retry identity"), source: CaptureSource(appName: "Test"))
    let prepared = await service.prepare(retryCapture, noteTitle: "Retry Destination")
    try FileManager.default.createDirectory(at: prepared.destination.url, withIntermediateDirectories: false)
    do {
        _ = try await service.save(prepared)
        throw CheckFailure.failed("a directory cannot be appended as a note")
    } catch is CheckFailure { throw CheckFailure.failed("prepared save should have failed") }
    catch {}
    try FileManager.default.removeItem(at: prepared.destination.url)
    _ = try await sessions.start(name: "Changed Session")
    let retried = try await service.save(prepared)
    let replayed = try await service.save(prepared)
    let retryText = try checkRead(prepared.destination.url)
    try require(retried.captureID == retryID && replayed == retried && retried.destination == prepared.destination,
                "retry must preserve ID, date, and destination after session changes")
    try require(retryText.components(separatedBy: checkCaptureMarker(retryID)).count - 1 == 1,
                "replaying a prepared capture must not duplicate its marker")
    let parsedRetry = NoteParser.parse(contents: retryText, notePath: "Retry Destination.md", titleFallback: "", calendar: calendar)
    try require(parsedRetry.blocks.first?.createdAt == now, "retry must preserve the original timestamp")
    try await checkDirectCaptureMethodsRejectLinks(base: base, calendar: calendar, now: now, png: png)
    print("CaptureService checks passed (including fixed-destination, idempotent retries).")
}

private func checkDirectCaptureMethodsRejectLinks(base: URL, calendar: Calendar, now: Date, png: Data) async throws {
    let fm = FileManager.default
    let textRoot = base.appendingPathComponent("DirectTextVault", isDirectory: true)
    try fm.createDirectory(at: textRoot, withIntermediateDirectories: true)
    let outsideNote = base.appendingPathComponent("direct-outside.md")
    try checkWrite("outside text\n", to: outsideNote)
    let textVault = Vault(root: textRoot)
    try fm.createSymbolicLink(at: textVault.inboxURL, withDestinationURL: outsideNote)
    let textSessions = SessionStore(stateDirectory: base.appendingPathComponent("DirectTextState", isDirectory: true),
                                    vault: textVault, calendar: calendar, now: { now })
    let textWriter = NoteWriter(vault: textVault, calendar: calendar)
    let textService = CaptureService(vault: textVault, sessions: textSessions, writer: textWriter, now: { now })
    do {
        _ = try await textService.saveText("must not escape", source: CaptureSource(), noteTitle: nil)
        throw CheckFailure.failed("direct saveText must reject a linked Inbox.md")
    } catch is CheckFailure { throw CheckFailure.failed("direct saveText unexpectedly accepted a linked Inbox.md") }
    catch {}
    let outsideText = try checkRead(outsideNote)
    try require(outsideText == "outside text\n", "direct saveText changed the Inbox symlink target")

    let imageRoot = base.appendingPathComponent("DirectImageVault", isDirectory: true)
    try fm.createDirectory(at: imageRoot, withIntermediateDirectories: true)
    let outsideAssets = base.appendingPathComponent("direct-assets", isDirectory: true)
    try fm.createDirectory(at: outsideAssets, withIntermediateDirectories: true)
    let imageVault = Vault(root: imageRoot)
    try fm.createSymbolicLink(at: imageVault.assetsURL, withDestinationURL: outsideAssets)
    let imageSessions = SessionStore(stateDirectory: base.appendingPathComponent("DirectImageState", isDirectory: true),
                                     vault: imageVault, calendar: calendar, now: { now })
    let imageWriter = NoteWriter(vault: imageVault, calendar: calendar)
    let imageService = CaptureService(vault: imageVault, sessions: imageSessions, writer: imageWriter, now: { now })
    do {
        _ = try await imageService.saveImage(png: png, source: CaptureSource(), noteTitle: nil)
        throw CheckFailure.failed("direct saveImage must reject a linked assets directory")
    } catch is CheckFailure { throw CheckFailure.failed("direct saveImage unexpectedly accepted a linked assets directory") }
    catch {}
    do {
        _ = try await imageWriter.saveImage(png: png, createdAt: now)
        throw CheckFailure.failed("direct NoteWriter.saveImage must reject a linked assets directory")
    } catch is CheckFailure { throw CheckFailure.failed("direct NoteWriter.saveImage unexpectedly accepted a linked assets directory") }
    catch {}
    let outsideAssetNames = try fm.contentsOfDirectory(atPath: outsideAssets.path)
    try require(outsideAssetNames.isEmpty, "image writes through a linked assets directory created an outside file")
}
