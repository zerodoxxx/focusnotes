@_spi(Checks) import Core
import Foundation

private final class VaultChangeRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var recorded: [VaultChange] = []

    func append(_ change: VaultChange) {
        condition.lock()
        recorded.append(change)
        condition.broadcast()
        condition.unlock()
    }

    func changes() -> [VaultChange] {
        condition.lock()
        defer { condition.unlock() }
        return recorded
    }

    func waitForChange(after offset: Int = 0, timeout: TimeInterval,
                       matching predicate: (VaultChange) -> Bool) -> VaultChange? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while let change = recorded.dropFirst(offset).first(where: predicate) {
            return change
        }
        while condition.wait(until: deadline) {
            if let change = recorded.dropFirst(offset).first(where: predicate) {
                return change
            }
        }
        return nil
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

func checkVaultWatcher() throws {
    let root = try checkMakeDirectory("vault-watcher")
    defer { checkRemoveDirectory(root) }
    let vault = Vault(root: root)
    try vault.prepare()
    let recorder = VaultChangeRecorder()
    let watcher = VaultWatcher(vault: vault, latency: 0.1) { recorder.append($0) }
    try require(!watcher.isRunning, "VaultWatcher should not report running before start")
    watcher.start()
    try require(watcher.isRunning, "VaultWatcher should report a successfully started stream")
    let initialGeneration = watcher.streamGenerationForChecks
    watcher.refreshExternalRoots()
    try require(watcher.streamGenerationForChecks == initialGeneration,
                "refreshing unchanged roots should preserve the active FSEvents stream")

    try checkWrite("# Foo\n", to: root.appendingPathComponent("Foo.md"))
    let fooChange = recorder.waitForChange(timeout: 3.0) { $0.notesChanged.contains("Foo.md") }
    try require(fooChange != nil, "VaultWatcher did not report Foo.md within 3 seconds")

    try checkWrite("# S\n", to: vault.sessionsURL.appendingPathComponent("S.md"))
    let sessionChange = recorder.waitForChange(timeout: 2.5) { $0.notesChanged.contains("Sessions/S.md") }
    try require(sessionChange != nil, "VaultWatcher did not report Sessions/S.md within 3 seconds")

    try checkWrite("# Nested\n", to: root.appendingPathComponent("science/math/Trigonometry.md"))
    let nestedChange = recorder.waitForChange(timeout: 2.5) { $0.notesChanged.contains("science/math/Trigonometry.md") }
    try require(nestedChange != nil, "VaultWatcher did not report a note nested under user folders")

    try checkWrite("metadata", to: root.appendingPathComponent(".DS_Store"))
    try checkWrite("temporary", to: root.appendingPathComponent("Foo.md.swp"))
    try checkWrite("lock", to: root.appendingPathComponent("~$draft.md"))
    try require(recorder.waitForQuiet(for: 0.5), "VaultWatcher reported a hidden or swap file")

    try checkWrite("# Bar\n", to: root.appendingPathComponent("Bar.md"))
    let barChange = recorder.waitForChange(timeout: 2.5) { $0.notesChanged.contains("Bar.md") }
    try require(barChange != nil, "own writes must reach fingerprint-based sync")

    // FSEvents may merge both writes into one path event; it must still reach sync.
    let coalesced = root.appendingPathComponent("Coalesced.md")
    try checkWrite("# Coalesced\n\napp append\n", to: coalesced)
    try checkWrite("# Coalesced\n\napp append\nexternal edit\n", to: coalesced)
    let mergedChange = recorder.waitForChange(timeout: 2.5) { $0.notesChanged.contains("Coalesced.md") }
    try require(mergedChange != nil, "coalesced own and external writes must never be suppressed")

    try checkWrite("image bytes", to: vault.assetsURL.appendingPathComponent("image.png"))
    let assetChange = recorder.waitForChange(timeout: 2.25) { $0.assetsChanged.contains("assets/image.png") }
    try require(assetChange != nil, "VaultWatcher did not report assets/image.png")

    let uppercaseAssetImage = root.appendingPathComponent("ASSETS/UpperWatcherImage.png")
    try checkWrite("upper-case asset bytes", to: uppercaseAssetImage)
    let uppercaseAssetChange = recorder.waitForChange(timeout: 2.25) {
        $0.assetsChanged.contains { $0.lowercased().hasSuffix("assets/upperwatcherimage.png") }
    }
    try require(uppercaseAssetChange != nil, "VaultWatcher did not report an image under ASSETS/")

    let uppercaseAssetNote = root.appendingPathComponent("ASSETS/UpperWatcherNote.md")
    let uppercaseNoteOffset = recorder.changes().count
    try checkWrite("# Asset note\n", to: uppercaseAssetNote)
    let uppercaseAssetNoteChange = recorder.waitForChange(after: uppercaseNoteOffset, timeout: 2.25) {
        $0.assetsChanged.contains { $0.lowercased().hasSuffix("assets/upperwatchernote.md") }
    }
    try require(uppercaseAssetNoteChange != nil, "VaultWatcher did not classify ASSETS/note.md as an asset path")
    try require(recorder.waitForQuiet(for: 0.2), "ASSETS/note.md produced a delayed note event")
    let uppercaseNoteChanges = recorder.changes().dropFirst(uppercaseNoteOffset)
    try require(uppercaseNoteChanges.allSatisfy { change in
        !change.notesChanged.contains { $0.lowercased().hasSuffix("assets/upperwatchernote.md") }
    }, "a Markdown file under ASSETS/ must not be reported as a vault note")

    watcher.stop()
    try require(!watcher.isRunning, "VaultWatcher should report stopped after stop()")
    let countAfterStop = recorder.changes().count
    try checkWrite("# After stop\n", to: root.appendingPathComponent("After stop.md"))
    try require(recorder.waitForQuiet(for: 0.5), "VaultWatcher delivered a change after stop()")
    try require(recorder.changes().count == countAfterStop, "VaultWatcher callback count changed after stop()")

    try checkBoundedExternalWatcher()
    try checkExternalWatcherDescriptorCapAndPolling()
    print("Vault watcher checks passed.")
}

private func checkExternalWatcherDescriptorCapAndPolling() throws {
    let base = try checkMakeDirectory("external-watcher-cap")
    defer { checkRemoveDirectory(base) }

    let home = base.appendingPathComponent("Home", isDirectory: true)
    let state = base.appendingPathComponent("State", isDirectory: true)
    let root = home.appendingPathComponent("Vault", isDirectory: true)
    let registryURL = state.appendingPathComponent("external-notes.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

    let relativePaths = (0..<10).map { String(format: "Group%02d/Note.md", $0) }
    let noteURLs = relativePaths.map { home.appendingPathComponent($0) }
    for (index, noteURL) in noteURLs.enumerated() {
        try checkWrite("# Group \(index)\n\ninitial\n", to: noteURL)
    }
    let jsonPaths = relativePaths.map { "\"\($0)\"" }.joined(separator: ",")
    try checkWrite("{\"version\":1,\"paths\":[\(jsonPaths)]}", to: registryURL)

    let vault = Vault(root: root, externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try vault.prepare()
    let noteIDs = try noteURLs.map { try vault.noteID(for: $0) }
    let recorder = VaultChangeRecorder()
    let watcher = VaultWatcher(vault: vault, latency: 0.1) { recorder.append($0) }
    watcher.configureWatchFallbackForChecks(maximumVnodeDescriptors: 8,
                                             maximumParentVnodeDescriptors: 3,
                                             interval: 0.05)
    defer { watcher.stop() }
    watcher.start()
    try require(watcher.isRunning, "descriptor-capped external watcher should start")
    try require(watcher.vnodeDescriptorCountForChecks <= 8,
                "external and registry vnode descriptors exceeded the configured total cap")
    try require(watcher.pollingFallbackCountForChecks > 0,
                "registered notes beyond the vnode cap must use exact-path polling")
    let cappedSetup = recorder.waitForChange(timeout: 1.0) { $0.needsFullSync }
    try require(cappedSetup != nil, "degraded watcher coverage must request an initial full sync")

    let fallbackID = noteIDs.last!
    var offset = recorder.changes().count
    try checkWrite("# Group 9\n\npolled edit\n", to: noteURLs.last!)
    try require(recorder.waitForChange(after: offset, timeout: 2.0) { $0.notesChanged.contains(fallbackID) } != nil,
                "timer fallback did not report an edit to a note beyond the vnode cap")

    offset = recorder.changes().count
    try FileManager.default.removeItem(at: noteURLs.last!)
    try require(recorder.waitForChange(after: offset, timeout: 2.0) { $0.notesChanged.contains(fallbackID) } != nil,
                "timer fallback did not report deletion of a note beyond the vnode cap")

    offset = recorder.changes().count
    try checkWrite("# Group 9\n\npolled recreation\n", to: noteURLs.last!)
    try require(recorder.waitForChange(after: offset, timeout: 2.0) { $0.notesChanged.contains(fallbackID) } != nil,
                "timer fallback did not report recreation of a note beyond the vnode cap")

    offset = recorder.changes().count
    try Data(#"{"version":1,"paths":["Group09/Note.md"]}"#.utf8)
        .write(to: registryURL, options: .atomic)
    try require(recorder.waitForChange(after: offset, timeout: 2.0) { $0.needsFullSync } != nil,
                "reducing the registry should request reconciliation")
    let recoveryDeadline = Date().addingTimeInterval(2.0)
    while watcher.pollingFallbackCountForChecks != 0 && Date() < recoveryDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    try require(watcher.pollingFallbackCountForChecks == 0,
                "freed descriptor slots should restore file and parent vnode coverage")
    offset = recorder.changes().count
    try checkWrite("# Group 9\n\nrecovered vnode edit\n", to: noteURLs.last!)
    try require(recorder.waitForChange(after: offset, timeout: 2.0) { $0.notesChanged.contains(fallbackID) } != nil,
                "the watcher did not recover from timer fallback after descriptor capacity became available")

    watcher.stop()
    let countAfterStop = recorder.changes().count
    try checkWrite("# Group 9\n\nafter stop\n", to: noteURLs.last!)
    try require(recorder.waitForQuiet(for: 0.2), "the stopped fallback timer delivered a change")
    try require(recorder.changes().count == countAfterStop,
                "watcher callback count changed after the fallback timer stopped")

    let healthyHome = base.appendingPathComponent("HealthyHome", isDirectory: true)
    let healthyRoot = healthyHome.appendingPathComponent("Vault", isDirectory: true)
    let healthyState = base.appendingPathComponent("HealthyState", isDirectory: true)
    let healthyRegistry = healthyState.appendingPathComponent("external-notes.json")
    let healthyNote = healthyHome.appendingPathComponent("Projects/Note.md")
    try checkWrite("# Healthy\n\ninitial\n", to: healthyNote)
    try FileManager.default.createDirectory(at: healthyRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: healthyState, withIntermediateDirectories: true)
    try checkWrite(#"{"version":1,"paths":["Projects/Note.md"]}"#, to: healthyRegistry)
    let healthyVault = Vault(root: healthyRoot, externalNoteRegistryURL: healthyRegistry, homeDirectoryURL: healthyHome)
    try healthyVault.prepare()
    let healthyRecorder = VaultChangeRecorder()
    let healthyWatcher = VaultWatcher(vault: healthyVault, latency: 0.1) { healthyRecorder.append($0) }
    healthyWatcher.configureWatchFallbackForChecks(maximumVnodeDescriptors: 8,
                                                    maximumParentVnodeDescriptors: 3,
                                                    interval: 0.05)
    defer { healthyWatcher.stop() }
    healthyWatcher.start()
    try require(healthyWatcher.isRunning, "fully watched external note should start")
    try require(healthyWatcher.pollingFallbackCountForChecks == 0,
                "a note with file and parent vnode coverage should not enter the polling fallback")
    let startupDeadline = Date().addingTimeInterval(2.0)
    var startupSettled = false
    while !startupSettled && Date() < startupDeadline {
        startupSettled = healthyRecorder.waitForQuiet(for: 0.25)
    }
    try require(startupSettled, "healthy watcher did not settle after its initial FSEvents delivery")
    let startupChanges = healthyRecorder.changes()
    try require(startupChanges.count <= 1 && startupChanges.allSatisfy { change in
        change.notesChanged == ["Inbox.md"] && change.assetsChanged.isEmpty && !change.needsFullSync &&
            change.externalRegistryError == nil && !change.externalRegistryRecovered
    }, "healthy watcher produced an unexpected startup change or full sync")

    let settledCallbackCount = startupChanges.count
    try require(healthyRecorder.waitForQuiet(for: 0.25),
                "healthy timer checks produced callbacks or periodic full syncs")
    try require(healthyRecorder.changes().count == settledCallbackCount,
                "healthy watcher emitted a callback after startup settled")
    try require(healthyRecorder.waitForQuiet(for: 0.25),
                "healthy timer checks produced callbacks or periodic full syncs")
    try require(healthyRecorder.changes().count == settledCallbackCount,
                "healthy watcher emitted a callback during the second timer window")
}

private func checkBoundedExternalWatcher() throws {
    let base = try checkMakeDirectory("bounded-external-watcher")
    defer { checkRemoveDirectory(base) }

    let home = base.appendingPathComponent("Home", isDirectory: true)
    let state = base.appendingPathComponent("State", isDirectory: true)
    let root = home.appendingPathComponent("Vault", isDirectory: true)
    let registryURL = state.appendingPathComponent("external-notes.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

    let direct = home.appendingPathComponent("Direct.md")
    let deep = home.appendingPathComponent("Projects/Research/Science/Deep.md")
    let added = home.appendingPathComponent("Added/Folder/Added.md")
    let late = home.appendingPathComponent("Late/Folder/Late.md")
    try checkWrite("# Direct\n\ninitial\n", to: direct)
    try checkWrite("# Deep\n\ninitial\n", to: deep)
    try checkWrite("# Added\n\ninitial\n", to: added)
    try checkWrite("# Late\n\ninitial\n", to: late)
    try checkWrite(
        #"{"version":1,"paths":["Direct.md","Projects/Research/Science/Deep.md"]}"#,
        to: registryURL
    )

    let vault = Vault(root: root, externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try vault.prepare()
    // Prime the in-memory registry cache, then replace it before watcher
    // subscription. Startup must close this stale-cache race itself.
    _ = try vault.listNotes()
    try Data(
        #"{"version":1,"paths":["Added/Folder/Added.md","Direct.md","Projects/Research/Science/Deep.md"]}"#.utf8
    ).write(to: registryURL, options: .atomic)
    let directID = try vault.noteID(for: direct)
    let deepID = try vault.noteID(for: deep)
    let addedID = try vault.noteID(for: added)
    let lateID = try vault.noteID(for: late)
    let recorder = VaultChangeRecorder()
    let watcher = VaultWatcher(vault: vault, latency: 0.1) { recorder.append($0) }
    defer { watcher.stop() }
    watcher.start()
    try require(watcher.isRunning, "bounded external watcher should start with a temp HOME registry")
    let initialGeneration = watcher.streamGenerationForChecks

    var offset = recorder.changes().count
    try checkWrite("# Added\n\nloaded at startup\n", to: added)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(addedID) } != nil,
                "startup must reload a cached registry changed before vnode subscription")

    offset = recorder.changes().count
    try checkWrite("# Direct\n\nupdated\n", to: direct)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(directID) } != nil,
                "a direct-HOME registered note should produce a vnode change")

    offset = recorder.changes().count
    try checkWrite("# Deep\n\nupdated\n", to: deep)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(deepID) } != nil,
                "a registered note at depth three or more should produce a vnode change")

    offset = recorder.changes().count
    try Data("# Deep\n\natomic replacement\n".utf8).write(to: deep, options: .atomic)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(deepID) } != nil,
                "an atomic replacement should be detected and its vnode rearmed")

    offset = recorder.changes().count
    try FileManager.default.removeItem(at: deep)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(deepID) } != nil,
                "deleting a registered note should report its exact external ID")

    offset = recorder.changes().count
    try checkWrite("# Deep\n\nrecreated\n", to: deep)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(deepID) } != nil,
                "the immediate-parent source should detect recreation after the file vnode is gone")

    offset = recorder.changes().count
    try FileManager.default.removeItem(at: home.appendingPathComponent("Projects", isDirectory: true))
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(deepID) } != nil,
                "removing a registered note's parent tree should report that exact note")
    for directory in ["Projects", "Projects/Research", "Projects/Research/Science"] {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(directory, isDirectory: true),
            withIntermediateDirectories: false
        )
        try require(recorder.waitForQuiet(for: 0.25),
                    "recreating a missing parent should rearm the next nearest-parent probe")
    }
    offset = recorder.changes().count
    try checkWrite("# Deep\n\nparent tree recreated\n", to: deep)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(deepID) } != nil,
                "the watcher should find a registered note after its full parent tree is recreated")

    // Delete and recreate the same immediate-parent spelling before the
    // debounce flush. A vnode bound to the deleted directory must be replaced
    // even though the registered parent path string is unchanged.
    let immediateParent = deep.deletingLastPathComponent()
    offset = recorder.changes().count
    try FileManager.default.removeItem(at: immediateParent)
    try FileManager.default.createDirectory(at: immediateParent, withIntermediateDirectories: false)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(deepID) } != nil,
                "replacing an immediate parent at the same path should report its registered note")
    offset = recorder.changes().count
    try checkWrite("# Deep\n\nsame-path parent recreated\n", to: deep)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(deepID) } != nil,
                "the watcher should rearm a parent vnode after same-path directory replacement")

    let unregisteredHomeSibling = home.appendingPathComponent("Unregistered.md")
    let unregisteredDeepSibling = deep.deletingLastPathComponent().appendingPathComponent("Unregistered.md")
    let nestedNoise = home.appendingPathComponent("Library/Caches/Level/Churn.data")
    offset = recorder.changes().count
    try checkWrite("# Unregistered\n", to: unregisteredHomeSibling)
    try checkWrite("# Unregistered\n", to: unregisteredDeepSibling)
    try checkWrite("nested churn", to: nestedNoise)
    try require(recorder.waitForQuiet(for: 0.7),
                "unregistered siblings and unrelated nested HOME churn must not produce callbacks")
    try require(recorder.changes().count == offset,
                "unrelated HOME activity must not force a full vault sync")

    // Simulate a second process atomically adding one exact path to the
    // registry. The registry-parent vnode must invalidate the in-memory map.
    offset = recorder.changes().count
    try Data(
        #"{"version":1,"paths":["Added/Folder/Added.md","Direct.md","Late/Folder/Late.md","Projects/Research/Science/Deep.md"]}"#.utf8
    ).write(to: registryURL, options: .atomic)
    let membershipRefresh = recorder.waitForChange(after: offset, timeout: 3.0) { $0.needsFullSync }
    try require(membershipRefresh != nil, "an external registry membership change should request a full sync")
    try require(watcher.streamGenerationForChecks == initialGeneration,
                "external membership changes must keep the vault FSEvents stream stable")

    offset = recorder.changes().count
    try checkWrite("# Late\n\nupdated\n", to: late)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(lateID) } != nil,
                "a newly registered note should receive a vnode source after membership refresh")

    offset = recorder.changes().count
    try Data(#"{"version":2,"paths":["Added/Folder/Added.md"]}"#.utf8)
        .write(to: registryURL, options: .atomic)
    let registryWarning = recorder.waitForChange(after: offset, timeout: 3.0) {
        $0.externalRegistryError == .unsupportedVersion(2)
    }
    try require(registryWarning != nil, "a runtime registry version change should emit a typed warning")

    offset = recorder.changes().count
    try checkWrite("unrelated state file", to: state.appendingPathComponent("session.json"))
    try require(recorder.waitForQuiet(for: 0.7),
                "unrelated app-state writes must not re-read or report the unchanged damaged registry")
    try require(recorder.changes().count == offset,
                "the same malformed registry fingerprint should not emit duplicate warnings")

    offset = recorder.changes().count
    try Data(
        #"{"version":1,"paths":["Added/Folder/Added.md","Direct.md","Late/Folder/Late.md","Projects/Research/Science/Deep.md"]}"#.utf8
    ).write(to: registryURL, options: .atomic)
    let recovery = recorder.waitForChange(after: offset, timeout: 3.0) {
        $0.needsFullSync && $0.externalRegistryRecovered
    }
    try require(recovery != nil, "a valid registry replacement should request reconciliation and clear its warning")
    offset = recorder.changes().count
    try checkWrite("# Late\n\nrecovered\n", to: late)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(lateID) } != nil,
                "external vnode sources should return after a valid registry recovery")

    let registryTarget = base.appendingPathComponent("registry-target.json")
    let validRegistry = Data(
        #"{"version":1,"paths":["Added/Folder/Added.md","Direct.md","Late/Folder/Late.md","Projects/Research/Science/Deep.md"]}"#.utf8
    )
    try validRegistry.write(to: registryTarget)
    offset = recorder.changes().count
    try FileManager.default.removeItem(at: registryURL)
    try FileManager.default.createSymbolicLink(at: registryURL, withDestinationURL: registryTarget)
    let unsafeWarning = recorder.waitForChange(after: offset, timeout: 3.0) {
        $0.needsFullSync && $0.externalRegistryError == .unreadableRegistry
    }
    try require(unsafeWarning != nil, "a runtime registry symlink should fail closed and emit one warning")

    offset = recorder.changes().count
    try checkWrite("unrelated state file", to: state.appendingPathComponent("session.json"))
    try require(recorder.waitForQuiet(for: 0.7),
                "unrelated app-state writes must not repeat an unchanged unreadable-registry warning")
    try require(recorder.changes().count == offset,
                "the same unreadable registry state should not trigger repeated full syncs")

    offset = recorder.changes().count
    try FileManager.default.removeItem(at: registryURL)
    let missingRecovery = recorder.waitForChange(after: offset, timeout: 3.0) {
        $0.needsFullSync && $0.externalRegistryRecovered
    }
    try require(missingRecovery != nil, "removing an unreadable registry should recover to a valid empty registry")

    offset = recorder.changes().count
    try validRegistry.write(to: registryURL)
    let safeRecovery = recorder.waitForChange(after: offset, timeout: 3.0) { $0.needsFullSync }
    try require(safeRecovery != nil, "adding a valid registry after removal should restore watcher membership")
    offset = recorder.changes().count
    try checkWrite("# Late\n\nrestored after unsafe registry\n", to: late)
    try require(recorder.waitForChange(after: offset, timeout: 3.0) { $0.notesChanged.contains(lateID) } != nil,
                "the external note vnode sources should resume after registry repair")

    try checkWarmRegistryCacheRejectsUnsafeReplacement(base: base)
}

private func checkWarmRegistryCacheRejectsUnsafeReplacement(base: URL) throws {
    let home = base.appendingPathComponent("WarmCacheHome", isDirectory: true)
    let root = home.appendingPathComponent("Vault", isDirectory: true)
    let state = base.appendingPathComponent("WarmCacheState", isDirectory: true)
    let registryURL = state.appendingPathComponent("external-notes.json")
    let note = home.appendingPathComponent("Desktop/Registered.md")
    try checkWrite("# Registered\n\nold cached entry\n", to: note)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try checkWrite(#"{"version":1,"paths":["Desktop/Registered.md"]}"#, to: registryURL)

    let vault = Vault(root: root, externalNoteRegistryURL: registryURL, homeDirectoryURL: home)
    try vault.prepare()
    let warmListing = try vault.listNotes()
    try require(warmListing.contains { $0.url.standardizedFileURL == note.standardizedFileURL },
                "the warm-cache fixture should initially list the registered HOME note")
    let externalID = try vault.noteID(for: note)

    let target = base.appendingPathComponent("warm-registry-target.json")
    try checkWrite(#"{"version":1,"paths":["Desktop/Registered.md"]}"#, to: target)
    try FileManager.default.removeItem(at: registryURL)
    try FileManager.default.createSymbolicLink(at: registryURL, withDestinationURL: target)
    do {
        try vault.validateExternalNoteRegistry()
        throw CheckFailure.failed("fresh registry validation should reject an unsafe replacement")
    } catch let error as ExternalNoteRegistryError {
        try require(error == .unreadableRegistry, "an unsafe registry replacement should have the typed unreadable error")
    }

    do {
        _ = try vault.listNotes()
        throw CheckFailure.failed("listing must fail closed when a warmed registry is replaced by a symlink")
    } catch let error as ExternalNoteRegistryError {
        try require(error == .unreadableRegistry,
                    "listing after an unsafe replacement should report the typed unreadable error")
    }
    do {
        _ = try vault.noteLocation(forID: externalID)
        throw CheckFailure.failed("a warmed external identity must not remain usable after registry replacement")
    } catch let error as ExternalNoteRegistryError {
        try require(error == .unreadableRegistry,
                    "the cached external identity should be rejected with the registry error")
    }
}
