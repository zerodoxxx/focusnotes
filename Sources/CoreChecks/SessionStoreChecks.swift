import Core
import Foundation

func checkSessionStore() async throws {
    let base = try checkMakeDirectory("sessions")
    defer { checkRemoveDirectory(base) }
    let calendar = checkCalendar()
    let vault = Vault(root: base.appendingPathComponent("Vault", isDirectory: true))
    let stateDirectory = base.appendingPathComponent("State", isDirectory: true)
    let stateFile = stateDirectory.appendingPathComponent("session.json")
    let now = checkDate(2026, 10, 13, 10, 0)
    let clock: @Sendable () -> Date = { now }

    let store = SessionStore(stateDirectory: stateDirectory, vault: vault, calendar: calendar, now: clock)
    let initial = await store.current()
    try require(initial == nil, "a new store should have no session")

    let started = try await store.start(name: "Design Review")
    try require(started.name == "Design Review", "session name was \(started.name)")
    try require(
        started.notePath == "Sessions/Design Review.md",
        "session note path was \(started.notePath)"
    )
    try require(started.startedAt == now, "session start time was \(started.startedAt)")
    let noteURL = vault.sessionsURL.appendingPathComponent("Design Review.md")
    let noteText = try checkRead(noteURL)
    try require(noteText == "# Design Review\n", "new session note was \(noteText.debugDescription)")
    try require(FileManager.default.fileExists(atPath: stateFile.path), "start should persist session.json")

    let reopened = SessionStore(stateDirectory: stateDirectory, vault: vault, calendar: calendar, now: clock)
    let restored = await reopened.current()
    try require(restored == started, "a new store on the same folder should restore the session")

    // Same name on the different days reuses the existing note instead of rewriting it.
    try checkWrite(noteText + "extra line\n", to: noteURL)
    _ = try await store.start(name: "Design Review")
    let reused = try checkRead(noteURL)
    try require(reused == noteText + "extra line\n", "starting the same name on the different days should reuse the note")
    let sessionFiles = try FileManager.default.contentsOfDirectory(atPath: vault.sessionsURL.path)
    try require(sessionFiles == ["Design Review.md"], "unexpected files in Sessions: \(sessionFiles)")

    let later = SessionStore(stateDirectory: stateDirectory, vault: vault, calendar: calendar, now: { now.addingTimeInterval(86_400) })
    let resumed = try await later.start(name: "design review")
    try require(resumed.notePath == started.notePath && resumed.name == "Design Review" && resumed.resumed == true,
                "case-insensitive resume must keep the existing filename and title")
    let cleaned = try await store.start(name: "A/B")
    let cleanedResume = try await store.start(name: "a:b")
    try require(cleaned.notePath == cleanedResume.notePath && cleanedResume.resumed == true, "resume must use filename cleaning")
    let legacy = vault.sessionsURL.appendingPathComponent("2026-10-12 Legacy.md")
    try checkWrite("# Legacy\n\nold bytes\n", to: legacy)
    let oldSession = Session(name: "Legacy", notePath: "Sessions/2026-10-12 Legacy.md", startedAt: now)
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(oldSession).write(to: stateFile)
    let legacyStore = SessionStore(stateDirectory: stateDirectory, vault: vault, calendar: calendar, now: clock)
    let restoredLegacy = await legacyStore.current()
    let legacyBytes = try checkRead(legacy)
    try require(restoredLegacy?.notePath == oldSession.notePath && legacyBytes == "# Legacy\n\nold bytes\n", "dated sessions must stay where they are")

    let resumedLegacy = try await store.start(name: "legacy")
    try require(resumedLegacy.notePath == oldSession.notePath && resumedLegacy.resumed == true, "resuming an old dated note must keep its path")

    let blank = try await store.start(name: "   ")
    try require(blank.name == "Session", "a blank name should become Session, got \(blank.name)")
    try require(
        blank.notePath == "Sessions/Session.md",
        "blank session note path was \(blank.notePath)"
    )

    try await store.end()
    let ended = await store.current()
    try require(ended == nil, "end should clear the active session")
    try require(!FileManager.default.fileExists(atPath: stateFile.path), "end should delete session.json")
    try await store.end()

    let afterEnd = SessionStore(stateDirectory: stateDirectory, vault: vault, calendar: calendar, now: clock)
    let restoredAfterEnd = await afterEnd.current()
    try require(restoredAfterEnd == nil, "a new store after end should have no session")

    try checkWrite("{not json", to: stateFile)
    let corrupt = SessionStore(stateDirectory: stateDirectory, vault: vault, calendar: calendar, now: clock)
    let corruptSession = await corrupt.current()
    try require(corruptSession == nil, "a corrupt session.json should load as no session")
    let kept = try await store.start(name: "Keep on failure")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDirectory.path)
    do {
        try await store.end()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        throw CheckFailure.failed("end should fail when the state directory cannot be modified")
    } catch is CheckFailure { throw CheckFailure.failed("end unexpectedly succeeded") }
    catch {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    }
    let retained = await store.current()
    try require(retained == kept && FileManager.default.fileExists(atPath: stateFile.path), "failed state deletion must keep the session active")
    try await store.end()
    try await checkSessionStartRejectsLinkedDirectory(calendar: calendar, now: now)
    try await checkSessionResumeRanking(calendar: calendar, now: now)
    print("SessionStore checks passed.")
}

private func checkSessionResumeRanking(calendar: Calendar, now: Date) async throws {
    let base = try checkMakeDirectory("session-rank")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault", isDirectory: true))
    try vault.prepare()
    // Bar.md is titled "Foo" and Foo.md is titled "Something": "Foo" must resume Bar.md by title, then Foo.md by file name once it exists.
    try checkWrite("# Foo\n", to: vault.sessionsURL.appendingPathComponent("Bar.md"))
    let store = SessionStore(stateDirectory: base.appendingPathComponent("State", isDirectory: true),
                             vault: vault, calendar: calendar, now: { now })
    let byTitle = try await store.start(name: "Foo")
    try require(byTitle.notePath == "Sessions/Bar.md" && byTitle.resumed == true,
                "a session name matching a note title must resume that note, got \(byTitle.notePath)")
    try checkWrite("# Something\n", to: vault.sessionsURL.appendingPathComponent("Foo.md"))
    let byFileName = try await store.start(name: "Foo")
    try require(byFileName.notePath == "Sessions/Foo.md" && byFileName.resumed == true,
                "a file-name match must beat a title match, got \(byFileName.notePath)")
}

private func checkSessionStartRejectsLinkedDirectory(calendar: Calendar, now: Date) async throws {
    let base = try checkMakeDirectory("session-link")
    defer { checkRemoveDirectory(base) }
    let fm = FileManager.default
    let root = base.appendingPathComponent("Vault", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let outsideSessions = base.appendingPathComponent("outside-sessions", isDirectory: true)
    try fm.createDirectory(at: outsideSessions, withIntermediateDirectories: true)
    let vault = Vault(root: root)
    try fm.createSymbolicLink(at: vault.sessionsURL, withDestinationURL: outsideSessions)
    let store = SessionStore(stateDirectory: base.appendingPathComponent("State", isDirectory: true),
                             vault: vault, calendar: calendar, now: { now })
    do {
        _ = try await store.start(name: "Escaped Session")
        throw CheckFailure.failed("starting a session must reject a linked Sessions directory")
    } catch is CheckFailure { throw CheckFailure.failed("session start unexpectedly accepted a linked Sessions directory") }
    catch {}
    let active = await store.current()
    let outsideNames = try fm.contentsOfDirectory(atPath: outsideSessions.path)
    try require(active == nil, "a failed linked-directory session start must not claim an active session")
    try require(outsideNames.isEmpty, "session start through a linked Sessions directory created an outside note")
    try require(!fm.fileExists(atPath: base.appendingPathComponent("State/session.json").path),
                "a failed linked-directory session start must not persist active state")
}
