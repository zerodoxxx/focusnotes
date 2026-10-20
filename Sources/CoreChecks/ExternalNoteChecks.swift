@_spi(Checks) import Core
import Foundation

private final class ExternalWatcherRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var recorded: [VaultChange] = []

    func append(_ change: VaultChange) {
        condition.lock()
        recorded.append(change)
        condition.broadcast()
        condition.unlock()
    }

    func waitForChange(timeout: TimeInterval, matching predicate: (VaultChange) -> Bool) -> VaultChange? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let change = recorded.first(where: predicate) { return change }
            guard condition.wait(until: deadline) else { return nil }
        }
    }

    func waitForQuiet(for interval: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let initialCount = recorded.count
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            guard condition.wait(until: deadline) else { break }
            if recorded.count != initialCount { return false }
        }
        return recorded.count == initialCount
    }
}

func checkExternalNoteRegistry() async throws {
    try checkOwnedFileDescriptorClosesOnlyOnce()
    let base = try checkMakeDirectory("external-notes")
    defer { checkRemoveDirectory(base) }

    let home = base.appendingPathComponent("Home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let registryURL = base.appendingPathComponent("State/external-notes.json")
    let vaultRoot = home.appendingPathComponent("ProjectVault", isDirectory: true)
    let vault = Vault(root: vaultRoot, externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try vault.prepare()

    let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    let unregistered = try vault.resolveNoteName("/Desktop/Private")
    try checkWrite("# Private\n\nunregisteredhomephrase", to: unregistered.url)
    try require(unregistered.scope == .home, "leading slash should resolve relative to the injected HOME root")
    let initialNotes = try vault.listNotes()
    try require(!initialNotes.contains { $0.url.standardizedFileURL == unregistered.url.standardizedFileURL },
                "unregistered HOME notes must not be discovered")

    let now = checkDate(2026, 10, 13, 10, 0)
    let calendar = checkCalendar()
    let state = base.appendingPathComponent("CaptureState", isDirectory: true)
    let service = externalCaptureService(vault: vault, stateDirectory: state, now: now, calendar: calendar)

    let recorder = ExternalWatcherRecorder()
    let watcher = VaultWatcher(vault: vault, latency: 0.1) { recorder.append($0) }
    watcher.start()
    try require(watcher.isRunning, "external-note watcher should start before registration")
    let initialGeneration = watcher.streamGenerationForChecks

    let capture = externalNoteCapture("/Desktop/Research/Registered", body: "externalregistryneedle", now: now)
    let prepared = try await service.prepareNote(capture, calendar: calendar)
    let expectedURL = home.appendingPathComponent("Desktop/Research/Registered.md")
    try require(prepared.destination.url.standardizedFileURL == expectedURL.standardizedFileURL,
                "typed HOME-relative note should resolve beneath the injected home")
    _ = try await service.save(prepared)

    let reopened = Vault(root: vaultRoot, externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    let registered = try reopened.resolveNoteName("/Desktop/Research/Registered")
    try require(registered.scope == .home && registered.id == registered.url.absoluteString,
                "registered HOME notes should use canonical file URL identities")
    let listedAfterReopen = try reopened.listNotes()
    try require(listedAfterReopen.contains { $0.url.standardizedFileURL == registered.url.standardizedFileURL },
                "explicit external-note registration should persist across Vault instances")
    try require(!listedAfterReopen.contains { $0.url.standardizedFileURL == unregistered.url.standardizedFileURL },
                "reopening a Vault must not scan unrelated files in HOME")

    // The app refreshes external vnode membership after a successful save.
    // The recursive FSEvents stream remains attached to the vault root.
    watcher.refreshExternalRoots()
    try require(watcher.streamGenerationForChecks == initialGeneration,
                "adding an external note must not replace the vault FSEvents stream")
    let rootRefresh = recorder.waitForChange(timeout: 3.0) { $0.needsFullSync }
    try require(rootRefresh != nil, "adding external vnode sources should request a bounded full sync")
    let activeGeneration = watcher.streamGenerationForChecks
    watcher.refreshExternalRoots()
    try require(watcher.streamGenerationForChecks == activeGeneration,
                "refreshing unchanged external membership should preserve the vault stream")
    try checkWrite("# Registered\n\nexternalregistryneedle updated", to: registered.url)
    let externalChange = recorder.waitForChange(timeout: 3.0) { $0.notesChanged.contains(registered.id) }
    watcher.stop()
    try require(externalChange != nil, "watcher should report an explicitly registered external note by scoped ID")

    let index = try SearchIndex(vault: reopened, databaseURL: base.appendingPathComponent("Index/search.sqlite"), calendar: calendar)
    do {
        try await index.reindex(note: unregistered.url)
        throw CheckFailure.failed("indexing an unregistered HOME URL should be rejected")
    } catch is CheckFailure {
        throw CheckFailure.failed("indexing an unregistered HOME URL should be rejected")
    } catch {}

    let indexed = try await index.sync()
    try require(indexed.added == 2, "index sync should include Inbox and only explicitly registered external notes")
    let hits = try await index.search("externalregistryneedle")
    try require(hits.count == 1 && hits[0].notePath == registered.id,
                "external search results should retain their scoped note ID")

    try FileManager.default.removeItem(at: registered.url)
    let listedAfterRemoval = try reopened.listNotes()
    try require(!listedAfterRemoval.contains { $0.url.standardizedFileURL == registered.url.standardizedFileURL },
                "a missing registered external note should be skipped")
    let removal = try await index.sync()
    let removedHits = try await index.search("externalregistryneedle")
    try require(removal.removed == 1 && removedHits.isEmpty,
                "sync should remove a missing registered external note from the index")

    try await checkExternalLinksAreRejected(vault: reopened, home: home, base: base,
                                            service: service, calendar: calendar, now: now)
    try await checkHomeNoteInsideVaultIsListedOnce(home: home, base: base, calendar: calendar, now: now)
    try await checkDirectHomeWatcherFiltering(base: base, now: now, calendar: calendar)
    try await checkExternalRegistryCorruptionPreserved(base: base, now: now, calendar: calendar)
    try checkTamperedExternalRegistryPathsRejected(base: base)
    try checkExternalDirectorySymlinkRejected(base: base)
    try await checkExternalRegistrySymlinkRejected(base: base, now: now, calendar: calendar)
    print("External note registry checks passed (persistence, scoped indexing, watcher refresh, and path safety).")
}

private func checkOwnedFileDescriptorClosesOnlyOnce() throws {
    var pipeDescriptors: [Int32] = [-1, -1]
    try require(pipe(&pipeDescriptors) == 0, "could not create descriptors for ownership check")
    defer { Darwin.close(pipeDescriptors[1]) }

    let original = pipeDescriptors[0]
    var owned: OwnedFileDescriptor? = OwnedFileDescriptor(owning: original)
    owned?.close()
    try require(owned?.descriptor == nil, "closing an owned descriptor should clear its stored value")
    try require(fcntl(original, F_GETFD) == -1 && errno == EBADF,
                "closing an owned descriptor should close the underlying handle")

    let temporary = open("/dev/null", O_RDONLY | O_CLOEXEC)
    try require(temporary >= 0, "could not open a descriptor for the reuse check")
    defer {
        if temporary != original { Darwin.close(temporary) }
    }
    let replacement = temporary == original ? temporary : dup2(temporary, original)
    try require(replacement == original, "could not reuse the released descriptor number")
    defer { Darwin.close(replacement) }

    owned?.close()
    owned = nil
    try require(fcntl(replacement, F_GETFD) >= 0,
                "repeated close or deinitialization must not close a descriptor reused by another owner")
}

private func checkExternalLinksAreRejected(
    vault: Vault,
    home: URL,
    base: URL,
    service: CaptureService,
    calendar: Calendar,
    now: Date
) async throws {
    let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
    let outsideSymbolicTarget = base.appendingPathComponent("outside-symbolic.md")
    let outsideHardTarget = base.appendingPathComponent("outside-hard.md")
    try checkWrite("outside symbolic target\n", to: outsideSymbolicTarget)
    try checkWrite("outside hardlink target\n", to: outsideHardTarget)

    let symbolicURL = desktop.appendingPathComponent("Linked.md")
    let hardURL = desktop.appendingPathComponent("Hardlinked.md")
    try FileManager.default.createSymbolicLink(at: symbolicURL, withDestinationURL: outsideSymbolicTarget)
    try FileManager.default.linkItem(at: outsideHardTarget, to: hardURL)

    for (name, url) in [("/Desktop/Linked", symbolicURL), ("/Desktop/Hardlinked", hardURL)] {
        let prepared = try await service.prepareNote(
            externalNoteCapture(name, body: "must not overwrite linked content", now: now), calendar: calendar
        )
        try require(prepared.destination.url.standardizedFileURL == url.standardizedFileURL,
                    "unsafe external fixture should resolve to its existing path")
        do {
            _ = try await service.save(prepared)
            throw CheckFailure.failed("external symlink and hardlink targets must reject writes")
        } catch is CheckFailure {
            throw CheckFailure.failed("external symlink and hardlink targets must reject writes")
        } catch {}
    }

    let listed = try vault.listNotes()
    try require(!listed.contains { $0.url.standardizedFileURL == symbolicURL.standardizedFileURL },
                "registered external symlinks must not be discovered")
    try require(!listed.contains { $0.url.standardizedFileURL == hardURL.standardizedFileURL },
                "registered external hardlinks must not be discovered")
    let symbolicContents = try checkRead(outsideSymbolicTarget)
    let hardlinkContents = try checkRead(outsideHardTarget)
    try require(symbolicContents == "outside symbolic target\n",
                "external symlink writes must leave their target unchanged")
    try require(hardlinkContents == "outside hardlink target\n",
                "external hardlink writes must leave their target unchanged")
}

private func checkHomeNoteInsideVaultIsListedOnce(
    home: URL,
    base: URL,
    calendar: Calendar,
    now: Date
) async throws {
    let registryURL = base.appendingPathComponent("DedupeState/external-notes.json")
    let vaultRoot = home.appendingPathComponent("DedupeVault", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
    let vault = Vault(root: vaultRoot, externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try vault.prepare()

    let location = try vault.resolveNoteName("/DedupeVault/Subfolder/Inside")
    try require(location.scope == .vault && location.id == "Subfolder/Inside.md",
                "a HOME-style name inside the selected vault should keep its vault-relative identity")
    let service = externalCaptureService(
        vault: vault,
        stateDirectory: base.appendingPathComponent("DedupeCaptureState"),
        now: now,
        calendar: calendar
    )
    let prepared = try await service.prepareNote(
        externalNoteCapture("/DedupeVault/Subfolder/Inside", body: "dedupedhomephrase", now: now),
        calendar: calendar
    )
    _ = try await service.save(prepared)

    let ownRefs = try vault.listNotes().filter { $0.url.standardizedFileURL == location.url.standardizedFileURL }
    try require(ownRefs.count == 1, "HOME-style notes inside the selected vault should be listed exactly once")

    let observer = Vault(root: home.appendingPathComponent("ObserverVault", isDirectory: true),
                         externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try observer.prepare()
    let observerNotes = try observer.listNotes()
    try require(!observerNotes.contains { $0.url.standardizedFileURL == location.url.standardizedFileURL },
                "a note inside one vault must not be registered as an external note for another vault")
}

private func checkDirectHomeWatcherFiltering(base: URL, now: Date, calendar: Calendar) async throws {
    let home = base.appendingPathComponent("DirectHome", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let registryURL = base.appendingPathComponent("DirectHomeState/external-notes.json")
    let vault = Vault(root: home.appendingPathComponent("Vault", isDirectory: true),
                      externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try vault.prepare()

    let service = externalCaptureService(
        vault: vault,
        stateDirectory: base.appendingPathComponent("DirectHomeCaptureState"),
        now: now,
        calendar: calendar
    )
    let directCapture = externalNoteCapture("/DirectNote", body: "directhomenotephrase", now: now)
    let prepared = try await service.prepareNote(directCapture, calendar: calendar)
    _ = try await service.save(prepared)

    let directLocation = try vault.resolveNoteName("/DirectNote")
    let unregisteredSibling = home.appendingPathComponent("UnregisteredSibling.md")
    try checkWrite("# Unregistered sibling\n\nunregistered sibling", to: unregisteredSibling)

    let recorder = ExternalWatcherRecorder()
    let watcher = VaultWatcher(vault: vault, latency: 0.1) { recorder.append($0) }
    watcher.start()
    defer { watcher.stop() }
    try require(watcher.isRunning, "watcher with a direct-HOME note should start")

    try checkWrite("# Direct Note\n\ndirecthomenotephrase changed", to: directLocation.url)
    let directChange = recorder.waitForChange(timeout: 3.0) { $0.notesChanged.contains(directLocation.id) }
    try require(directChange != nil, "direct-HOME watcher should report the registered note by its scoped ID")

    // Drain late coalesced events for the registered note so only the sibling write is measured.
    var drained = false
    for _ in 0..<10 where !drained { drained = recorder.waitForQuiet(for: 0.5) }
    try require(drained, "direct-HOME watcher should go quiet after the registered note change")
    try checkWrite("# Unregistered sibling\n\nchanged", to: unregisteredSibling)
    try require(recorder.waitForQuiet(for: 0.5), "direct-HOME watcher must ignore unregistered sibling files")
}

private func checkExternalRegistrySymlinkRejected(base: URL, now: Date, calendar: Calendar) async throws {
    let home = base.appendingPathComponent("RegistryLinkHome", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop", isDirectory: true),
                                            withIntermediateDirectories: true)
    let registryDirectory = base.appendingPathComponent("RegistryLinkState", isDirectory: true)
    try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
    let registryURL = registryDirectory.appendingPathComponent("external-notes.json")
    let registryTarget = base.appendingPathComponent("registry-target.json")
    let originalRegistry = "{\"version\":1,\"paths\":[\"Desktop/Leaked.md\"]}"
    try checkWrite(originalRegistry, to: registryTarget)

    let leakedNote = home.appendingPathComponent("Desktop/Leaked.md")
    try checkWrite("# Should remain unlisted\n\nregistrylinkleak", to: leakedNote)
    try FileManager.default.createSymbolicLink(at: registryURL, withDestinationURL: registryTarget)

    let vault = Vault(root: home.appendingPathComponent("Vault", isDirectory: true),
                      externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try vault.prepare()
    do {
        _ = try vault.listNotes()
        throw CheckFailure.failed("listing must fail closed when the registry is a symlink")
    } catch is CheckFailure {
        throw CheckFailure.failed("a symlinked registry must not be treated as an empty external-note list")
    } catch let error as ExternalNoteRegistryError {
        try require(error == .unreadableRegistry, "a symlinked registry should surface an unreadable-registry error")
    }

    let service = externalCaptureService(
        vault: vault,
        stateDirectory: base.appendingPathComponent("RegistryLinkCaptureState"),
        now: now,
        calendar: calendar
    )
    let blockedURL = home.appendingPathComponent("Desktop/Blocked.md")
    let prepared = try await service.prepareNote(
        externalNoteCapture("/Desktop/Blocked", body: "must not replace registry link", now: now),
        calendar: calendar
    )
    do {
        _ = try await service.save(prepared)
        throw CheckFailure.failed("external registration must reject a symlinked registry file")
    } catch is CheckFailure {
        throw CheckFailure.failed("external registration must reject a symlinked registry file")
    } catch let error as ExternalNoteRegistryError {
        try require(error == .unreadableRegistry, "symlinked registries should report an unreadable-registry error")
    } catch {
        throw CheckFailure.failed("symlinked registry failed for an unexpected reason: \(error)")
    }

    try require(!FileManager.default.fileExists(atPath: blockedURL.path),
                "a failed symlinked-registry save must not write its external note")
    let targetContents = try checkRead(registryTarget)
    try require(targetContents == originalRegistry, "registry symlink operations must leave the target file unchanged")
}

private func checkExternalRegistryCorruptionPreserved(base: URL, now: Date, calendar: Calendar) async throws {
    let cases: [(String, Data, ExternalNoteRegistryError, Bool)] = [
        ("Malformed", Data(#"{"version":1,"paths":["Desktop/a.md","Desktop/b.md"]}x"#.utf8), .malformedRegistry, false),
        ("NewerVersion", Data(#"{"version":2,"paths":["Desktop/a.md","Desktop/b.md"]}"#.utf8), .unsupportedVersion(2), false),
        ("Unreadable", Data(#"{"version":1,"paths":["Desktop/a.md"]}"#.utf8), .unreadableRegistry, true)
    ]

    for (label, originalBytes, expectedError, registryIsSymlink) in cases {
        let caseRoot = base.appendingPathComponent("Registry\(label)", isDirectory: true)
        let home = caseRoot.appendingPathComponent("Home", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let vaultRoot = home.appendingPathComponent("Vault", isDirectory: true)
        let registryURL = caseRoot.appendingPathComponent("State/external-notes.json")
        try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if registryIsSymlink {
            let registryTarget = caseRoot.appendingPathComponent("registry-target.json")
            try originalBytes.write(to: registryTarget)
            try FileManager.default.createSymbolicLink(at: registryURL, withDestinationURL: registryTarget)
        } else {
            try originalBytes.write(to: registryURL)
        }

        let first = desktop.appendingPathComponent("a.md")
        let second = desktop.appendingPathComponent("b.md")
        try checkWrite("# A\n", to: first)
        try checkWrite("# B\n", to: second)

        let vault = Vault(root: vaultRoot, externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
        try vault.prepare()
        let listingError: Error?
        do {
            _ = try vault.listNotes()
            listingError = nil
        } catch {
            listingError = error
        }
        guard let listingRegistryError = listingError as? ExternalNoteRegistryError else {
            throw CheckFailure.failed("listing with a \(label.lowercased()) registry must surface ExternalNoteRegistryError")
        }
        try require(listingRegistryError == expectedError,
                    "listing should preserve the specific \(label.lowercased()) registry error")

        let service = externalCaptureService(
            vault: vault,
            stateDirectory: caseRoot.appendingPathComponent("CaptureState"),
            now: now,
            calendar: calendar
        )
        let localMatch = vaultRoot.appendingPathComponent("A.md")
        let routedCapture = Capture(id: UUID(), createdAt: now, content: .text("must not be misrouted"), source: CaptureSource())
        let routingError: Error?
        do {
            let routed = try await service.prepare(routedCapture, noteTitle: "A")
            _ = try await service.save(routed)
            routingError = nil
        } catch {
            routingError = error
        }
        guard let routingRegistryError = routingError as? ExternalNoteRegistryError else {
            throw CheckFailure.failed("capture preparation with a \(label.lowercased()) registry must fail instead of routing to a new vault note")
        }
        try require(routingRegistryError == expectedError,
                    "capture preparation should preserve the specific \(label.lowercased()) registry error")
        try require(!FileManager.default.fileExists(atPath: localMatch.path),
                    "a capture matching a registered HOME note must not create a same-name vault note")

        let destination = desktop.appendingPathComponent("c.md")
        let prepared = try await service.prepareNote(
            externalNoteCapture("/Desktop/c", body: "must not overwrite a damaged registry", now: now),
            calendar: calendar
        )
        let saveError: Error?
        do {
            _ = try await service.save(prepared)
            saveError = nil
        } catch {
            saveError = error
        }
        guard let registryError = saveError as? ExternalNoteRegistryError else {
            throw CheckFailure.failed("saving with a \(label.lowercased()) registry must throw ExternalNoteRegistryError")
        }
        try require(registryError == expectedError, "the registry should report its specific corruption or version error")
        let finalBytes = try Data(contentsOf: registryURL)
        try require(finalBytes == originalBytes, "a failed external save must preserve the registry bytes exactly")
        try require(!FileManager.default.fileExists(atPath: destination.path),
                    "a failed registry read must stop the external note write before append")
    }
}

private func checkTamperedExternalRegistryPathsRejected(base: URL) throws {
    let home = base.appendingPathComponent("TamperedRegistryHome", isDirectory: true)
    let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)

    let traversalTarget = home.deletingLastPathComponent().appendingPathComponent("TraversalEscape.md")
    let absoluteTarget = base.appendingPathComponent("AbsoluteEscape.md")
    let absolutePathCandidate = home.appendingPathComponent(absoluteTarget.path).standardizedFileURL
    try checkWrite("# Traversal escape\n", to: traversalTarget)
    try checkWrite("# Absolute escape\n", to: absoluteTarget)
    try checkWrite("# Absolute path candidate\n", to: absolutePathCandidate)

    let backslashPath = "Desktop/Back\\slash.md"
    let controlPath = "Desktop/Bad\u{0007}.md"
    let textPath = "Desktop/NotMarkdown.txt"
    try checkWrite("# Backslash path\n", to: home.appendingPathComponent(backslashPath))
    try checkWrite("# Control path\n", to: home.appendingPathComponent(controlPath))
    try checkWrite("Not markdown\n", to: home.appendingPathComponent(textPath))
    let safePath = "Desktop/Allowed.md"
    let safeNote = home.appendingPathComponent(safePath)
    try checkWrite("# Allowed\n", to: safeNote)

    let paths = ["../TraversalEscape.md", absoluteTarget.path, backslashPath, controlPath, textPath, safePath]
    let registryURL = base.appendingPathComponent("TamperedRegistryState/external-notes.json")
    try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let registryData = try JSONSerialization.data(withJSONObject: ["version": 1, "paths": paths])
    try registryData.write(to: registryURL)

    let vault = Vault(root: home.appendingPathComponent("Vault", isDirectory: true),
                      externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try vault.prepare()
    let listed = try vault.listNotes()
    try require(listed.contains { $0.url.standardizedFileURL == safeNote.standardizedFileURL },
                "a safe entry should remain available beside tampered registry entries")
    for rejectedURL in [traversalTarget, absoluteTarget, absolutePathCandidate, home.appendingPathComponent(backslashPath),
                        home.appendingPathComponent(controlPath), home.appendingPathComponent(textPath)] {
        try require(!listed.contains { $0.url.standardizedFileURL == rejectedURL.standardizedFileURL },
                    "tampered registry paths must not expose traversal, absolute, backslash, control, or non-Markdown targets")
    }
}

private func checkExternalDirectorySymlinkRejected(base: URL) throws {
    let home = base.appendingPathComponent("DirectorySymlinkHome", isDirectory: true)
    let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    let outsideDirectory = base.appendingPathComponent("DirectorySymlinkOutside", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    let outsideNote = outsideDirectory.appendingPathComponent("Outside.md")
    try checkWrite("# Outside\n\nthis must stay outside the registry scope", to: outsideNote)

    let escapedDirectory = home.appendingPathComponent("Escaped", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: escapedDirectory, withDestinationURL: outsideDirectory)
    let safeNote = desktop.appendingPathComponent("Allowed.md")
    try checkWrite("# Allowed\n", to: safeNote)

    let registryURL = base.appendingPathComponent("DirectorySymlinkState/external-notes.json")
    try FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let registryData = try JSONSerialization.data(withJSONObject: ["version": 1, "paths": ["Escaped/Outside.md", "Desktop/Allowed.md"]])
    try registryData.write(to: registryURL)

    let vault = Vault(root: home.appendingPathComponent("Vault", isDirectory: true),
                      externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try vault.prepare()
    let listed = try vault.listNotes()
    try require(listed.contains { $0.url.standardizedFileURL == safeNote.standardizedFileURL },
                "listing should succeed and retain a valid registered note beside a symlink escape")
    let escapedNoteURL = escapedDirectory.appendingPathComponent("Outside.md")
    try require(!listed.contains { $0.url.standardizedFileURL == escapedNoteURL.standardizedFileURL ||
                                   $0.url.standardizedFileURL == outsideNote.standardizedFileURL },
                "registered paths crossing a directory symlink must not expose the outside note")
}

private func externalCaptureService(vault: Vault, stateDirectory: URL, now: Date, calendar: Calendar) -> CaptureService {
    let clock: @Sendable () -> Date = { now }
    let sessions = SessionStore(stateDirectory: stateDirectory, vault: vault, calendar: calendar, now: clock)
    let writer = NoteWriter(vault: vault, calendar: calendar)
    return CaptureService(vault: vault, sessions: sessions, writer: writer, now: clock)
}

private func externalNoteCapture(_ name: String, body: String, now: Date) -> Capture {
    Capture(id: UUID(), createdAt: now, content: .note("# \(name)\n\n\(body)"), source: CaptureSource())
}
