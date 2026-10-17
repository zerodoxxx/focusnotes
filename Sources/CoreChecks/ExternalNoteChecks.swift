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

    // The app refreshes watcher roots after a successful save. Exercise the
    // same refresh once the new registered parent directory exists. A changed
    // root set must start a replacement and request reconciliation for events
    // that could have occurred during the transition.
    watcher.refreshExternalRoots()
    try require(watcher.streamGenerationForChecks == initialGeneration + 1,
                "adding an external parent should replace the active watcher stream")
    let rootRefresh = recorder.waitForChange(timeout: 3.0) { $0.needsFullSync }
    try require(rootRefresh != nil, "adding an external watch root should request a bounded full sync")
    let activeGeneration = watcher.streamGenerationForChecks
    watcher.refreshExternalRoots()
    try require(watcher.streamGenerationForChecks == activeGeneration,
                "refreshing the same external roots should preserve the replacement stream")
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
    try await checkExternalRegistrySymlinkRejected(base: base, now: now, calendar: calendar)
    print("External note registry checks passed (persistence, scoped indexing, watcher refresh, and path safety).")
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
    let listed: [NoteRef]
    do {
        listed = try vault.listNotes()
    } catch {
        // Failing closed is also safe: the registry symlink must never reveal
        // its target's registered paths.
        listed = []
    }
    try require(!listed.contains { $0.url.standardizedFileURL == leakedNote.standardizedFileURL },
                "a symlinked registry must not expose paths from its outside target")

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
    } catch {}

    try require(!FileManager.default.fileExists(atPath: blockedURL.path),
                "a failed symlinked-registry save must not write its external note")
    let targetContents = try checkRead(registryTarget)
    try require(targetContents == originalRegistry, "registry symlink operations must leave the target file unchanged")
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
