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
    try require(cleaned.notePath == "Sessions/A/B.md" && cleaned.resumed == false,
                "a slash in a session name must resolve as a qualified path")
    try require(cleanedResume.notePath == "Sessions/a-b.md" && cleanedResume.resumed == false,
                "a colon in a bare session name must use filename cleaning without colliding with folders")
    let explicitCleanedResume = try await store.start(name: "A/B")
    try require(explicitCleanedResume.notePath == cleaned.notePath && explicitCleanedResume.resumed == true,
                "a folder-qualified session name must resume the exact nested note")
    for name in ["TODO/", "Read https://x.com", "a//b", "pros / cons"] {
        let flat = try await store.start(name: name)
        let expected = "Sessions/\(NoteTitle.fileStem(for: NoteTitle.cleanTitle(name))).md"
        try require(flat.notePath == expected && !flat.notePath.dropFirst("Sessions/".count).contains("/"),
                    "invalid or whitespace-qualified session name \(name.debugDescription) must stay flat, got \(flat.notePath)")
    }
    let beforeInvalidPaths = await store.current()
    for name in ["/outside", " /outside", "science/../escape", "science/\0name", "science/~$draft"] {
        do {
            _ = try await store.start(name: name)
            throw CheckFailure.failed("unsafe or HOME-relative session path unexpectedly started: \(name.debugDescription)")
        } catch let error as NotePathNameError {
            try require(error == .invalidComponent,
                        "unsafe or HOME-relative session path should retain its validation error: \(name.debugDescription)")
        } catch is CheckFailure {
            throw CheckFailure.failed("unsafe or HOME-relative session path was accepted: \(name.debugDescription)")
        }
        let flatName = NoteTitle.fileStem(for: NoteTitle.cleanTitle(name))
        try require(!FileManager.default.fileExists(atPath: vault.sessionsURL.appendingPathComponent("\(flatName).md").path),
                    "unsafe or HOME-relative session path must not create a flat note: \(name.debugDescription)")
    }
    let afterInvalidPaths = await store.current()
    try require(afterInvalidPaths == beforeInvalidPaths,
                "an unsafe or HOME-relative session path must not change the active session")
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

    let nestedNote = vault.sessionsURL.appendingPathComponent("archive/Standup.md")
    let nestedBytes = "# Standup\n\narchived notes\n"
    try checkWrite(nestedBytes, to: nestedNote)
    let nestedResume = try await store.start(name: "Standup")
    try require(nestedResume.notePath == "Sessions/archive/Standup.md" && nestedResume.resumed == true,
                "a bare nested session match must resume its full path")
    let nestedAfterResume = try checkRead(nestedNote)
    try require(nestedAfterResume == nestedBytes, "resuming a nested session must preserve its note")
    try require(!FileManager.default.fileExists(atPath: vault.sessionsURL.appendingPathComponent("Standup.md").path),
                "resuming a nested session must not create a top-level duplicate")

    let ambiguousVault = Vault(root: base.appendingPathComponent("AmbiguousVault", isDirectory: true))
    try ambiguousVault.prepare()
    let olderNote = ambiguousVault.sessionsURL.appendingPathComponent("Standup.md")
    let newerNote = ambiguousVault.sessionsURL.appendingPathComponent("archive/Standup.md")
    let tiedNote = ambiguousVault.sessionsURL.appendingPathComponent("z-archive/Standup.md")
    try checkWrite("# Root Standup\n", to: olderNote)
    try checkWrite("# Archived Standup\n", to: newerNote)
    try checkWrite("# Z Standup\n", to: tiedNote)
    let olderModified = now.addingTimeInterval(-86_400)
    let newerModified = now.addingTimeInterval(-3_600)
    try FileManager.default.setAttributes([.modificationDate: olderModified], ofItemAtPath: olderNote.path)
    try FileManager.default.setAttributes([.modificationDate: newerModified], ofItemAtPath: newerNote.path)
    try FileManager.default.setAttributes([.modificationDate: newerModified], ofItemAtPath: tiedNote.path)
    let olderActual = try FileManager.default.attributesOfItem(atPath: olderNote.path)[.modificationDate] as? Date
    let newerActual = try FileManager.default.attributesOfItem(atPath: newerNote.path)[.modificationDate] as? Date
    let tiedActual = try FileManager.default.attributesOfItem(atPath: tiedNote.path)[.modificationDate] as? Date
    guard let olderActual, let newerActual, let tiedActual else {
        throw CheckFailure.failed("session ambiguity fixtures must expose modification dates")
    }
    try require(olderActual < newerActual && newerActual == tiedActual,
                "the ambiguity fixture must contain one older note and two equal-time notes")
    let ambiguousState = base.appendingPathComponent("AmbiguousState", isDirectory: true)
    let ambiguousStore = SessionStore(stateDirectory: ambiguousState, vault: ambiguousVault, calendar: calendar, now: clock)
    do {
        _ = try await ambiguousStore.start(name: "Standup")
        throw CheckFailure.failed("duplicate bare session names must require an explicit selection")
    } catch SessionStoreError.ambiguous(let candidates) {
        let paths = candidates.map(\.notePath)
        try require(paths == ["Sessions/archive/Standup.md", "Sessions/z-archive/Standup.md", "Sessions/Standup.md"],
                    "ambiguous sessions must be newest first with a stable path tie-break, got \(paths)")
        try require(candidates.map(\.name) == ["Archived Standup", "Z Standup", "Root Standup"],
                    "ambiguous sessions must expose their note titles")
    } catch is CheckFailure {
        throw CheckFailure.failed("duplicate bare session names were not reported as ambiguous")
    }
    let ambiguousCurrent = await ambiguousStore.current()
    try require(ambiguousCurrent == nil, "an ambiguous session must not become active")
    try require(!FileManager.default.fileExists(atPath: ambiguousState.appendingPathComponent("session.json").path),
                "an ambiguous session must not persist active state")
    let rootBytesAfterAmbiguity = try checkRead(olderNote)
    let archivedBytesAfterAmbiguity = try checkRead(newerNote)
    let tiedBytesAfterAmbiguity = try checkRead(tiedNote)
    try require(rootBytesAfterAmbiguity == "# Root Standup\n" &&
                archivedBytesAfterAmbiguity == "# Archived Standup\n" &&
                tiedBytesAfterAmbiguity == "# Z Standup\n",
                "an ambiguous session must not alter or create notes")

    let qualifiedResume = try await ambiguousStore.start(name: "archive/Standup")
    try require(qualifiedResume.notePath == "Sessions/archive/Standup.md" && qualifiedResume.resumed == true,
                "a folder-qualified session name must resume directly without ambiguity")
    let qualifiedCreate = try await ambiguousStore.start(name: "new-group/Planning")
    try require(qualifiedCreate.notePath == "Sessions/new-group/Planning.md" && qualifiedCreate.resumed == false,
                "a missing folder-qualified name must create its nested session note")
    let qualifiedBytes = try checkRead(ambiguousVault.sessionsURL.appendingPathComponent("new-group/Planning.md"))
    try require(qualifiedBytes == "# Planning\n", "a qualified session note must use its leaf name as the title")

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
    print("SessionStore checks passed.")
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
