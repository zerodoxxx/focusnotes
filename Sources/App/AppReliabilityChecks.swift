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
