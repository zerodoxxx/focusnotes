import AppKit
import CaptureKit
import Core
import OverlayKit

/// Regressions that run without OCR, model downloads, or system permission prompts.
@MainActor
func checkAppReliability() async throws {
    try checkUnavailableShortcutMenu()
    try checkRelaunchLifecycle()
    try await checkChangesDuringInitialScan()
    try await checkDraftTerminationVeto()
    try await checkSessionRenameIdentity()
}

@MainActor
private func checkSessionRenameIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-session-rename-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultRoot = root.appendingPathComponent("Vault")
    let state = root.appendingPathComponent("State")
    let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    let original = try await pipeline.sessions.start(name: "archive/Standup")
    let oldURL = vaultRoot.appendingPathComponent(original.notePath)
    let candidate = SessionCandidate(name: original.name, notePath: original.notePath, modifiedAt: .distantPast)
    try pipeline.pins.set(original.notePath, pinned: true)
    _ = try await pipeline.index.sync()
    let capture = Capture(id: UUID(), createdAt: Date(), content: .text("queuedrenameneedle"),
                          source: CaptureSource(appName: "Rename check", windowTitle: nil))
    let prepared = PreparedCapture(capture: capture, destination: Destination(url: oldURL, title: original.name, kind: .session),
                                   noteMarkerIsIdentity: true)
    let job = CaptureJob(prepared: prepared, png: nil, ocr: nil, noteDraft: "retain draft metadata")
    try await pipeline.journal.store(job)
    // An unrelated malformed job must not block an otherwise valid rename.
    let corrupt = state.appendingPathComponent("unsaved/unrelated.json")
    try Data("{invalid".utf8).write(to: corrupt)
    let outcome = try await pipeline.renameSession(candidate, to: "Daily sync", preparedJobs: [job])
    let newPath = "Sessions/archive/Daily sync.md"
    guard !outcome.identityUpdatePending, outcome.session.notePath == newPath,
          pipeline.pins.isPinned(newPath), !pipeline.pins.isPinned(original.notePath),
          await pipeline.sessions.current()?.notePath == newPath else {
        throw SelfTestFailure("Session rename did not migrate pins and active identity")
    }
    let suggestions = try await pipeline.index.titleSuggestions(prefix: "", limit: Int.max)
    guard suggestions.contains(where: { $0.path == newPath && $0.title == "Daily sync" }),
          !suggestions.contains(where: { $0.path == original.notePath }) else {
        throw SelfTestFailure("Session rename left its old search identity or failed to index the new heading")
    }
    let redirected = try await pipeline.journal.redirected(job)
    guard redirected.prepared.capture == capture, redirected.prepared.destination.url == vaultRoot.appendingPathComponent(newPath),
          redirected.prepared.noteMarkerIsIdentity == true, redirected.noteDraft == job.noteDraft else {
        throw SelfTestFailure("Session rename changed capture identity or lost prepared metadata")
    }
    // Store and commit a stale in-memory preparation after the rename. Both
    // paths must resolve the UUID redirect without recreating the old filename.
    try await pipeline.journal.store(job)
    let recordURL = state.appendingPathComponent("unsaved/\(capture.id.uuidString.lowercased()).json")
    let persisted = try await pipeline.journal.load(record: recordURL)
    guard persisted.prepared.destination.url == redirected.prepared.destination.url else {
        throw SelfTestFailure("A stale journal write restored the old session destination")
    }
    let saved = try await pipeline.commit(job)
    guard saved.destination.url == vaultRoot.appendingPathComponent(newPath),
          !FileManager.default.fileExists(atPath: oldURL.path),
          try String(contentsOf: saved.destination.url, encoding: .utf8).contains("queuedrenameneedle") else {
        throw SelfTestFailure("A stale prepared capture recreated the old session after rename")
    }

    // Simulate a crash after the Markdown move and before any identity updates.
    let recoverySession = try await pipeline.sessions.start(name: "archive/Recovery")
    let recoveryCandidate = SessionCandidate(name: recoverySession.name, notePath: recoverySession.notePath, modifiedAt: .distantPast)
    try pipeline.pins.set(recoverySession.notePath, pinned: true)
    let recoveryCapture = Capture(id: UUID(), createdAt: Date(), content: .text("recoveredrenamecapture"), source: capture.source)
    let recoveryJob = CaptureJob(prepared: PreparedCapture(capture: recoveryCapture,
                                                          destination: Destination(url: vaultRoot.appendingPathComponent(recoverySession.notePath),
                                                                                   title: recoverySession.name, kind: .session)), png: nil, ocr: nil)
    try await pipeline.journal.store(recoveryJob)
    let planned = try await pipeline.sessions.renameDestination(recoveryCandidate, to: "Recovered")
    let intent = try await pipeline.journal.beginSessionRename(oldPath: recoverySession.notePath, session: planned,
                                                              vault: pipeline.vault, preparedJobs: [recoveryJob])
    let recorder = await pipeline.journal.installationRecorder(for: intent)
    _ = try await pipeline.sessions.rename(recoveryCandidate, to: "Recovered", beforeInstall: recorder)
    let reopened = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    guard try await reopened.journal.pendingSessionRename() == nil,
          reopened.pins.isPinned(planned.notePath), !reopened.pins.isPinned(recoverySession.notePath),
          await reopened.sessions.current()?.notePath == planned.notePath,
          !FileManager.default.fileExists(atPath: state.appendingPathComponent("capture-destinations.json").path) else {
        throw SelfTestFailure("Startup did not complete a committed session rename and prune previous-process redirects")
    }
    let replayed = await reopened.replayUnsaved()
    guard replayed == 1, !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(recoverySession.notePath).path),
          try String(contentsOf: vaultRoot.appendingPathComponent(planned.notePath), encoding: .utf8).contains("recoveredrenamecapture") else {
        throw SelfTestFailure("Journal recovery did not keep captures on the renamed session")
    }

    // Simulate a crash before file installation. Recovery may finish the user's
    // request only while the recorded original identity and contents still match.
    let before = try await reopened.sessions.start(name: "archive/Before install")
    let beforeCandidate = SessionCandidate(name: before.name, notePath: before.notePath, modifiedAt: .distantPast)
    let beforeTarget = try await reopened.sessions.renameDestination(beforeCandidate, to: "After install")
    _ = try await reopened.journal.beginSessionRename(oldPath: before.notePath, session: beforeTarget,
                                                     vault: reopened.vault, preparedJobs: [])
    // A rollback swap (or a harmless touch) updates inode timestamps. Its
    // unchanged bytes still prove that this is the recorded original note.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                         ofItemAtPath: vaultRoot.appendingPathComponent(before.notePath).path)
    let finished = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    guard await finished.sessions.current()?.notePath == beforeTarget.notePath,
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(before.notePath).path) else {
        throw SelfTestFailure("Startup did not safely resume a staged rename before installation")
    }

    let repeated = try await finished.sessions.start(name: "archive/Repeated A")
    let unstagedCapture = Capture(id: UUID(), createdAt: Date(), content: .text("unstaged repeated rename"), source: capture.source)
    let unstaged = CaptureJob(prepared: PreparedCapture(capture: unstagedCapture,
                                                       destination: Destination(url: vaultRoot.appendingPathComponent(repeated.notePath),
                                                                                title: repeated.name, kind: .session)), png: nil, ocr: nil)
    let repeatedA = SessionCandidate(name: repeated.name, notePath: repeated.notePath, modifiedAt: .distantPast)
    let firstRename = try await finished.renameSession(repeatedA, to: "Repeated B", preparedJobs: [unstaged])
    let repeatedB = SessionCandidate(name: firstRename.session.name, notePath: firstRename.session.notePath, modifiedAt: .distantPast)
    let secondRename = try await finished.renameSession(repeatedB, to: "Repeated C", preparedJobs: [unstaged])
    let repeatedSaved = try await finished.commit(unstaged)
    guard repeatedSaved.destination.url == vaultRoot.appendingPathComponent(secondRename.session.notePath),
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(repeated.notePath).path),
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(firstRename.session.notePath).path) else {
        throw SelfTestFailure("Repeated renames did not update an unstaged in-memory capture's existing UUID redirect")
    }

    // If metadata storage fails after installation, every preparation entry
    // point must finish recovery before it can route a newly acquired UUID.
    try finished.pins.set(secondRename.session.notePath, pinned: true)
    let pinBackup = state.appendingPathComponent("saved-pins.json")
    try FileManager.default.moveItem(at: finished.pins.url, to: pinBackup)
    try FileManager.default.createDirectory(at: finished.pins.url, withIntermediateDirectories: false)
    let pendingCandidate = SessionCandidate(name: secondRename.session.name, notePath: secondRename.session.notePath, modifiedAt: .distantPast)
    let pendingOutcome = try await finished.renameSession(pendingCandidate, to: "Waiting metadata", preparedJobs: [])
    guard pendingOutcome.identityUpdatePending,
          await finished.sessions.current()?.notePath == pendingOutcome.session.notePath else {
        throw SelfTestFailure("A metadata failure did not retain the installed session identity and recovery intent")
    }
    let pendingCapture = PendingCapture(trigger: .selection, content: .text("new UUID after rename"), source: capture.source, subtitle: "check")
    let directCapture = Capture(id: UUID(), createdAt: Date(), content: .note("typed UUID after rename"), source: capture.source)
    do {
        _ = try await finished.prepare(pendingCapture, noteTitle: nil)
        throw SelfTestFailure("Capture preparation routed around an unfinished rename")
    } catch is SelfTestFailure { throw SelfTestFailure("Capture preparation routed around an unfinished rename") } catch {}
    do {
        _ = try await finished.prepareNote(directCapture, destination: nil, newNote: false)
        throw SelfTestFailure("Typed-note preparation routed around an unfinished rename")
    } catch is SelfTestFailure { throw SelfTestFailure("Typed-note preparation routed around an unfinished rename") } catch {}
    do {
        _ = try await finished.prepareCapture(directCapture, destination: nil)
        throw SelfTestFailure("Subheading preparation routed around an unfinished rename")
    } catch is SelfTestFailure { throw SelfTestFailure("Subheading preparation routed around an unfinished rename") } catch {}
    try FileManager.default.removeItem(at: finished.pins.url)
    try FileManager.default.moveItem(at: pinBackup, to: finished.pins.url)
    let afterRepair = try await finished.prepare(pendingCapture, noteTitle: nil)
    guard afterRepair.prepared.destination.url == vaultRoot.appendingPathComponent(pendingOutcome.session.notePath),
          finished.pins.isPinned(pendingOutcome.session.notePath),
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(secondRename.session.notePath).path) else {
        throw SelfTestFailure("Preparation did not recover pin metadata and route to the installed session after storage repair")
    }

    let changed = try await finished.sessions.start(name: "archive/Changed source")
    let changedCandidate = SessionCandidate(name: changed.name, notePath: changed.notePath, modifiedAt: .distantPast)
    let changedTarget = try await finished.sessions.renameDestination(changedCandidate, to: "Must not move")
    _ = try await finished.journal.beginSessionRename(oldPath: changed.notePath, session: changedTarget,
                                                     vault: finished.vault, preparedJobs: [])
    let changedURL = vaultRoot.appendingPathComponent(changed.notePath)
    let writer = try FileHandle(forWritingTo: changedURL)
    try writer.seekToEnd()
    try writer.write(contentsOf: Data("external edit after intent\n".utf8))
    try writer.close()
    do {
        _ = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
        throw SelfTestFailure("Rename recovery accepted a modified original inode")
    } catch is SelfTestFailure { throw SelfTestFailure("Rename recovery accepted a modified original inode") }
    catch {}
    guard FileManager.default.fileExists(atPath: changedURL.path),
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(changedTarget.notePath).path),
          try String(contentsOf: changedURL, encoding: .utf8).contains("external edit after intent") else {
        throw SelfTestFailure("Rejected rename recovery altered the externally modified source")
    }
}

@MainActor
private func checkRelaunchLifecycle() throws {
    var launches = 0
    let lifecycle = RelaunchLifecycle { launches += 1 }
    lifecycle.request()
    guard launches == 0 else {
        throw SelfTestFailure("A relaunch must wait until AppKit confirms termination")
    }
    lifecycle.terminationWasVetoed()
    lifecycle.applicationWillTerminate()
    guard launches == 0 else {
        throw SelfTestFailure("A vetoed termination must discard its pending relaunch")
    }

    lifecycle.request()
    guard launches == 0 else {
        throw SelfTestFailure("A slow shutdown must not launch another app instance while it is draining")
    }
    lifecycle.applicationWillTerminate()
    lifecycle.applicationWillTerminate()
    guard launches == 1 else {
        throw SelfTestFailure("An accepted termination must launch exactly one replacement instance")
    }
}

@MainActor
private func checkUnavailableShortcutMenu() throws {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    AppController.configureShortcut(item, title: "Capture Selection", hotkey: .captureSelection, failure: .conflict)
    guard item.title == "Capture Selection", item.keyEquivalent.isEmpty,
          item.keyEquivalentModifierMask.isEmpty, item.toolTip?.contains("Another app") == true,
          item.toolTip?.contains("Retry Shortcuts") == true else {
        throw SelfTestFailure("Conflicting shortcuts must retain their menu command, explain recovery, and omit the unavailable key")
    }
    AppController.configureShortcut(item, title: "Capture Selection", hotkey: .captureSelection, failure: nil)
    guard item.keyEquivalent == "c", item.keyEquivalentModifierMask == [.option, .shift], item.toolTip == nil else {
        throw SelfTestFailure("A recovered shortcut must regain its menu key and clear its failure message")
    }
    AppController.configureShortcut(item, title: "End Session", hotkey: .toggleSession, failure: .registrationFailed(status: -1))
    guard item.title == "End Session", item.keyEquivalent.isEmpty,
          item.toolTip?.contains("macOS could not register") == true else {
        throw SelfTestFailure("Non-conflict registration failures must also explain the unavailable shortcut")
    }
}

private actor InitialScanRecorder {
    private var passes = 0
    private var released = false
    private var firstPass: CheckedContinuation<Void, Never>?
    private var noteOnlyAssetRefresh = false
    private var scanFailure: String?

    func scan(_ request: VaultRefreshRequest, index: SearchIndex) async {
        guard request.notes else { return }
        do { _ = try await index.sync() }
        catch { scanFailure = String(describing: error) }
        if request.assets, request.recheckingAssetPaths?.isEmpty == true {
            noteOnlyAssetRefresh = true
        }
        passes += 1
        if passes == 1, !released {
            await withCheckedContinuation { firstPass = $0 }
        }
    }
    func count() -> Int { passes }
    func sawNoteOnlyAssetRefresh() -> Bool { noteOnlyAssetRefresh }
    func failure() -> String? { scanFailure }
    func release() { released = true; firstPass?.resume(); firstPass = nil }
}

@MainActor
private func checkChangesDuringInitialScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-startup-\(UUID().uuidString)", isDirectory: true)
    let vault = Vault(root: root)
    try vault.prepare()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = InitialScanRecorder()
    defer { Task { await recorder.release() } }
    let original = try await CapturePipeline.open(vaultRoot: root, stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let monitor = VaultMonitor(vault: vault) { request in await recorder.scan(request, index: original.index) }
    defer { monitor.stop() }
    let pipeline = CapturePipeline(vault: original.vault, sessions: original.sessions, service: original.service,
                                   index: original.index, semantic: original.semantic, monitor: monitor,
                                   journal: original.journal, drafts: original.drafts, pins: original.pins,
                                   calendar: original.calendar, logger: original.logger)
    let controller = AppController(pipeline: pipeline, presentsUI: false)
    let initialSync = Task { await controller.start() }
    let initialDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await recorder.count() == 0, ContinuousClock.now < initialDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard await recorder.count() == 1 else {
        await recorder.release()
        throw SelfTestFailure("Initial index scan did not begin")
    }
    guard monitor.isRunning else {
        await recorder.release()
        throw SelfTestFailure("The vault watcher must already be running when the initial index scan begins")
    }
    guard try await pipeline.index.search("startupeventneedle").isEmpty else {
        await recorder.release()
        throw SelfTestFailure("The startup regression needle was indexed before its note existed")
    }
    try Data("# During startup\n\nstartupeventneedle\n".utf8).write(to: root.appendingPathComponent("During startup.md"))
    // Keep the first scan suspended through the watcher's event latency. The event
    // must become a second pass, rather than disappear behind the in-flight scan.
    try await Task.sleep(for: .milliseconds(1600))
    await recorder.release()
    _ = await initialSync.value
    let reconcileDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await recorder.count() < 2, ContinuousClock.now < reconcileDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard await recorder.count() >= 2 else {
        throw SelfTestFailure("A vault change received during startup did not trigger reconciliation")
    }
    guard await recorder.failure() == nil,
          try await pipeline.index.search("startupeventneedle").contains(where: { $0.notePath == "During startup.md" }) else {
        throw SelfTestFailure("The note created during the initial scan did not become searchable through watcher reconciliation")
    }
    guard await recorder.sawNoteOnlyAssetRefresh() else {
        throw SelfTestFailure("A note-only event must check new image references without rehashing unchanged assets")
    }
}

@MainActor
private func checkDraftTerminationVeto() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-quit-\(UUID().uuidString)", isDirectory: true)
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let oldText = "Previously saved draft"
    let latestText = "Latest text that must survive a failed quit"
    try pipeline.drafts.store(oldText)
    let oldDraft = try Data(contentsOf: pipeline.drafts.url)
    let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
    let controller = AppController(pipeline: pipeline, presentsUI: false)
    pipeline.monitor.start()
    controller.openNoteEditor()
    var panel: OverlayPanel?
    defer {
        // Restore a writable path before dismissing, including when an assertion fails.
        if (try? pipeline.drafts.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? FileManager.default.removeItem(at: pipeline.drafts.url)
        }
        panel?.dismiss(animated: false)
        pipeline.monitor.stop()
        try? FileManager.default.removeItem(at: root)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while panel == nil, ContinuousClock.now < deadline {
        panel = NSApp.windows.compactMap { $0 as? OverlayPanel }.first {
            $0.isVisible && !existingWindows.contains(ObjectIdentifier($0))
        }
        if panel == nil { try await Task.sleep(for: .milliseconds(20)) }
    }
    func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    guard let panel, let content = panel.contentView, let text = textView(in: content), text.string == oldText else {
        throw SelfTestFailure("Could not open the restored editor for the quit regression")
    }
    text.string = latestText
    try FileManager.default.removeItem(at: pipeline.drafts.url)
    try FileManager.default.createDirectory(at: pipeline.drafts.url, withIntermediateDirectories: false)
    try Data("block replacement".utf8).write(to: pipeline.drafts.url.appendingPathComponent("blocker"))
    guard await controller.beginTermination().value == false, panel.isVisible, pipeline.monitor.isRunning else {
        throw SelfTestFailure("Failed draft persistence must veto quit before stopping app services")
    }
    // Repair storage and make a second quit request. The veto must not poison the
    // controller's shutdown state, and the final flush must preserve the latest text.
    try FileManager.default.removeItem(at: pipeline.drafts.url)
    try oldDraft.write(to: pipeline.drafts.url)
    guard await controller.beginTermination().value, !panel.isVisible, !pipeline.monitor.isRunning,
          try pipeline.drafts.load() == latestText else {
        throw SelfTestFailure("Quit could not retry after a draft failure or lost the newest editor text")
    }
}
