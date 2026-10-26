import AppKit
import CaptureKit
import Core
import Foundation
import OverlayKit
import os

enum AppErrorLog {
    /// A public diagnostic that excludes localized descriptions and associated values.
    static func summary(_ error: Error) -> String {
        "\(String(reflecting: type(of: error))) code=\((error as NSError).code)"
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var terminationRequested = false
    private let relaunchLifecycle = RelaunchLifecycle(launch: { ApplicationDelegate.launchRelaunchHelper() })

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let base = home.appendingPathComponent("Library/Application Support").appendingPathComponent(AppInfo.bundleIdentifier, isDirectory: true)
                // Claim existing state before setup or recovery can select a different folder.
                _ = try NotesFolder.stateDirectory(for: NotesFolder.configuredRoot(), base: base)
                guard let root = NotesFolder.startupRoot() else { NSApp.terminate(nil); return }
                let state = try NotesFolder.stateDirectory(for: root, base: base)
                let pipeline = try await CapturePipeline.open(vaultRoot: root, stateDirectory: state, calendar: .current,
                                                            modelsDirectory: base.appendingPathComponent("models", isDirectory: true))
                let controller = AppController(pipeline: pipeline)
                connectRelaunchHandler(to: controller)
                self.controller = controller
                await controller.start()
            } catch {
                Logger(subsystem: AppInfo.bundleIdentifier, category: "startup")
                    .error("Startup failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        relaunchLifecycle.applicationWillTerminate()
    }

    private func connectRelaunchHandler(to controller: AppController) {
        controller.onRelaunchRequested = { [weak self] in self?.requestRelaunch() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        let shutdown = controller.beginTermination()
        Task {
            let shouldTerminate = await shutdown.value
            if !shouldTerminate {
                relaunchLifecycle.terminationWasVetoed()
                terminationRequested = false
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    private func requestRelaunch() {
        relaunchLifecycle.request()
        NSApp.terminate(nil)
    }

    private static func launchRelaunchHelper() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "parent_pid=\"$1\"; app_path=\"$2\"; while /bin/kill -0 \"$parent_pid\" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open -n \"$app_path\"",
            "relaunch-helper",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundlePath,
        ]
        try? process.run()
    }
}

/// Holds a relaunch request until AppKit confirms the app is actually terminating.
@MainActor
final class RelaunchLifecycle {
    private let launch: @MainActor () -> Void
    private var isRequested = false

    init(launch: @escaping @MainActor () -> Void) {
        self.launch = launch
    }

    func request() {
        isRequested = true
    }

    func terminationWasVetoed() {
        isRequested = false
    }

    func applicationWillTerminate() {
        guard isRequested else { return }
        isRequested = false
        launch()
    }
}

@MainActor
private final class SearchSnapshot {
    var hits: [String: SearchHit] = [:]
    var generation = 0
    var currentIDs = Set<String>()
}

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    let pipeline: CapturePipeline
    let presentsUI: Bool
    private let onToast: ((Toast) -> Void)?
    private let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "app")
    private let hotkeys = HotkeyCenter()
    private let toast = ToastController()
    private var input: InputPanelController?
    private var search: SearchPanelController?
    private var editor: NoteEditorPanel?
    private var inputCloseWaiters: [CheckedContinuation<Void, Never>] = []
    private var searchCloseWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: PendingCapture?
    private var pendingOutsideSession = false
    private var pendingToastID: UUID?
    private var pendingNeedsRetryChoice = false
    private var isChoosingDestination = false
    private var stagedJob: (id: UUID, preparation: Task<CaptureJob, Error>, persistence: Task<Void, Error>)?
    private(set) var commitTail: Task<SavedCapture, Error>?
    private var commitGeneration = 0
    private var preparedJobs: [UUID: Task<CaptureJob, Error>] = [:]
    private var acquisitionTask: Task<Void, Never>?
    private var acquisitionGeneration = 0
    private var acquisitionFallback: PendingCapture?
    private var acquisitionOutsideSession = false
    private var recoveryJobs: [UUID: Task<CaptureJob, Error>] = [:]
    private var recoveryPersistences: [UUID: Task<Void, Error>] = [:]
    private var processingTail: Task<Void, Never>?
    private var processingGeneration = 0
    private var isTerminating = false
    private var shutdownFinished = false
    private var shutdownTask: Task<Bool, Never>?
    private var startupReplayTask: Task<Int, Never>?
    private var startupIndexTask: Task<Void, Never>?
    private(set) var acquisitionInProgress = false
    private var actionTail: Task<Void, Never>?
    private var actionGeneration = 0
    private var activeSession: Session?
    private var statusItem: NSStatusItem?
    private var shortcutItems: [(item: NSMenuItem, hotkey: Hotkey)] = []
    private var hotkeyFailures: [Hotkey: HotkeyError] = [:]
    private var shortcutStatusItem: NSMenuItem?
    private var retryShortcutsItem: NSMenuItem?
    private var folderShortcuts: [FolderShortcut] = []
    private var folderShortcutsPanel: FolderShortcutsPanel?
    private var folderShortcutsMenu: NSMenu?
    private var recordingShortcut = false
    private var folderShortcutStore: FolderShortcutStore {
        FolderShortcutStore(url: pipeline.drafts.url.deletingLastPathComponent().appendingPathComponent("folder-shortcuts.json"))
    }
    private var sessionItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?
    private var screenRecordingItem: NSMenuItem?
    private var semanticModels: SemanticModelsMenu?
    private var powerMonitor: PowerMonitor?
    private var reportedExternalRegistryWarnings = Set<String>()
    private var menuTracking = false
    private var menuAction: (@MainActor () -> Void)?
    private var requestedScreenCapture = false
    private let permissionGuide = PermissionGuide()
    private var appUpdater: AppUpdater?
    var onRelaunchRequested: (() -> Void)?

    init(pipeline: CapturePipeline, presentsUI: Bool = true, onToast: ((Toast) -> Void)? = nil) {
        self.pipeline = pipeline
        self.presentsUI = presentsUI
        self.onToast = onToast
        super.init()
        permissionGuide.onGranted = { [weak self] _ in self?.refreshStatus() }
        permissionGuide.onRelaunch = { [weak self] in self?.onRelaunchRequested?() }
        toast.onExpire = { [weak self] in
            guard let self, self.pendingToastID == self.pending?.id else { return }
            _ = self.commitPending()
        }
    }

    @discardableResult
    func start() async -> Int {
        let pipeline = pipeline
        let replay = Task.detached(priority: .userInitiated) { [weak self] in
            await pipeline.replayUnsaved { [weak self] saved, pinFailed in
                self?.showNoteSaveFeedback(saved, pinFailed: pinFailed)
            }
        }
        startupReplayTask = replay
        let restored = await replay.value
        startupReplayTask = nil
        activeSession = await pipeline.sessions.current()
        guard !isTerminating else { return restored }
        if presentsUI {
            do { folderShortcuts = try folderShortcutStore.load() }
            catch { report(error, title: "Couldn't load folder shortcuts") }
            registerHotkeys()
            installStatusItem()
            // The guide replaces the system AX prompt, and only the first launch ever shows it.
            let guideKey = "didShowAccessibilityGuide"
            if !CapturePermissions.accessibilityTrusted, !UserDefaults.standard.bool(forKey: guideKey) {
                UserDefaults.standard.set(true, forKey: guideKey)
                permissionGuide.show(for: .accessibility)
            }
        }
        await pipeline.monitor.setExternalRegistryErrorHandler { [weak self] error in
            Task { @MainActor [weak self] in
                self?.reportExternalRegistryProblem(error, forSave: false)
            }
        }
        await pipeline.monitor.setExternalRegistryRecoveryHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.reportedExternalRegistryWarnings.removeAll()
            }
        }
        do {
            try pipeline.vault.validateExternalNoteRegistry()
        } catch {
            reportExternalRegistryProblem(error, forSave: false)
        }
        let indexing = Task.detached(priority: .utility) {
            // Observe first: events received during the initial scan queue another pass.
            pipeline.monitor.start()
            await pipeline.sync()
            guard !Task.isCancelled else { return }
            await pipeline.backfill()
        }
        startupIndexTask = indexing
        if !presentsUI { await indexing.value }
        logger.notice("Ready: vault=\(pipeline.vault.root.path, privacy: .private) session=\(self.activeSession?.name ?? "none", privacy: .private)")
        return restored
    }

    private func registerHotkeys(showFailures: Bool = true) {
        hotkeys.unregisterAll()
        guard !isTerminating, !recordingShortcut else { return }
        hotkeyFailures.removeAll()
        var bindings: [(Hotkey, @MainActor @Sendable () -> Void)] = [
            (.captureSelection, { [weak self] in self?.capture(.selection) }),
            (.captureRegion, { [weak self] in self?.capture(.region) }),
            (.captureSelectionOutsideSession, { [weak self] in self?.capture(.selection, outsideSession: true) }),
            (.captureRegionOutsideSession, { [weak self] in self?.capture(.region, outsideSession: true) }),
            (.search, { [weak self] in self?.openSearch() }),
            (.toggleSession, { [weak self] in self?.toggleSession() }),
            (.writeNote, { [weak self] in self?.openNoteEditor() }),
            (.writeNoteOutsideSession, { [weak self] in self?.openNoteEditor(outsideSession: true) }),
            (.addSubheading, { [weak self] in self?.openSubheading() }),
            (.openLibrary, { [weak self] in self?.openNotesFolder() })
        ]
        for binding in folderShortcuts {
            bindings.append((binding.hotkey, { [weak self] in self?.runFolderShortcut(binding) }))
        }
        for (offset, binding) in bindings.enumerated() {
            switch hotkeys.register(binding.0, id: UInt32(offset + 1), handler: binding.1) {
            case .success:
                logger.notice("Hotkey \(binding.0.displayString, privacy: .public): registered")
            case .failure(let error):
                hotkeyFailures[binding.0] = error
                logger.error("Hotkey \(binding.0.displayString, privacy: .public) failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
            }
        }
        refreshShortcutStatus()
        if showFailures, !hotkeyFailures.isEmpty {
            showToast(Toast(style: .warning, title: "Some keyboard shortcuts are unavailable",
                            subtitle: "Use the menu bar commands, then choose Retry Shortcuts", duration: 6))
        }
    }

    private func openFolderShortcuts() {
        guard !isTerminating else { return }
        if let folderShortcutsPanel { folderShortcutsPanel.show(); return }
        do {
            // Never overwrite an unreadable or newer settings file with an empty list.
            let saved = try folderShortcutStore.load()
            let panel = FolderShortcutsPanel(bindings: saved, failures: hotkeyFailures,
                onSave: { [weak self] proposed in try self?.saveFolderShortcuts(proposed) },
                onRecordingChanged: { [weak self] recording in
                    guard let self else { return }
                    self.recordingShortcut = recording
                    self.registerHotkeys(showFailures: false)
                }, onClose: { [weak self] in self?.folderShortcutsPanel = nil })
            folderShortcutsPanel = panel
            panel.show()
        } catch { report(error, title: "Couldn't open folder shortcuts") }
    }

    private func saveFolderShortcuts(_ proposed: [FolderShortcut]) throws {
        try FolderShortcutStore.validate(proposed)
        let previous = folderShortcuts
        folderShortcuts = proposed
        registerHotkeys(showFailures: false)
        do {
            for binding in proposed where hotkeyFailures[binding.hotkey] != nil {
                throw FolderShortcutValidationError(message: "\(binding.hotkey.displayString) is unavailable. Release it in the other app or record another shortcut.")
            }
            try folderShortcutStore.save(proposed)
        } catch {
            folderShortcuts = previous
            registerHotkeys(showFailures: false)
            throw error
        }
        rebuildFolderShortcutsMenu()
    }

    func runFolderShortcut(_ binding: FolderShortcut) {
        guard !isTerminating else { return }
        do {
            let folder = try NoteFolder(rawValue: binding.folder)
            switch binding.action {
            case .quickNote: openNoteEditor(folder: folder)
            case .startSession:
                enqueue { controller in
                    await controller.drainCaptures()
                    guard await controller.closePanels() else { return }
                    await controller.waitForCommits()
                    guard !controller.isTerminating else { return }
                    let suggestions = await controller.suggestionSnapshot(sessionsOnly: true)
                        .filter { Self.sessionPath($0.path, isIn: folder) }
                    controller.presentInput(placeholder: "Session name", title: "Start Session",
                        secondary: "In Sessions/\(folder.rawValue)", suggestions: suggestions,
                        suggestionValue: { "/" + $0.path },
                        onSubmit: { [weak controller] name in
                            guard !NoteTitle.cleanTitle(name).isEmpty else { return }
                            controller?.enqueue { controller in
                                _ = controller.commitPending()
                                await controller.waitForCommits()
                                guard !controller.isTerminating else { return }
                                do {
                                    if let selected = suggestions.first(where: { "/" + $0.path == name }),
                                       Self.sessionPath(selected.path, isIn: folder) {
                                        _ = try await controller.resumeSession(SessionCandidate(name: selected.title,
                                            notePath: selected.path, modifiedAt: selected.modified))
                                    } else {
                                        _ = try await controller.startFolderSession(name: name, in: folder)
                                    }
                                }
                                catch SessionStoreError.ambiguous(let candidates) {
                                    controller.presentSessionCandidates(candidates.filter { Self.sessionPath($0.notePath, isIn: folder) })
                                } catch { controller.report(error, title: "Couldn't start folder session") }
                            }
                        }, onCancel: {})
                }
            }
        } catch { report(error, title: "Couldn't use folder shortcut") }
    }

    @discardableResult
    func startFolderSession(name: String, in folder: NoteFolder) async throws -> Session {
        guard !NoteTitle.cleanTitle(name).isEmpty else { throw NotePathNameError.emptyPath }
        try await pipeline.recoverSessionIdentity()
        let session = try await pipeline.sessions.start(name: name, in: folder)
        return try await activateSession(session)
    }

    static func sessionPath(_ path: String, isIn folder: NoteFolder) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.caseInsensitiveCompare("Sessions/\(folder.rawValue)") == .orderedSame
    }

    /// UI commands run in order, while their context is snapshotted at hotkey/menu entry.
    private func enqueue(_ action: @escaping @MainActor (AppController) async -> Void) {
        guard !isTerminating else { return }
        let previous = actionTail
        actionGeneration += 1
        let generation = actionGeneration
        actionTail = Task { [weak self] in
            await previous?.value
            guard let self, !self.isTerminating else { return }
            await action(self)
            if self.actionGeneration == generation { self.actionTail = nil }
        }
    }

    func capture(_ trigger: CaptureTrigger, outsideSession: Bool = false, fromHotkey: Bool = true, context suppliedContext: FrontmostContext? = nil) {
        guard !isTerminating, !acquisitionInProgress else { return }
        let context = suppliedContext ?? FrontmostContext.capture()
        guard context.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if !outsideSession, fromHotkey, let pending, pending.trigger == trigger, pendingToastID == pending.id, toast.isVisible {
            showTitlePicker(for: pending.id)
            return
        }
        if !outsideSession, fromHotkey, pendingNeedsRetryChoice, let pending, pending.trigger == trigger {
            showTitlePicker(for: pending.id)
            return
        }
        _ = commitPending()
        beginAcquisition(outsideSession: outsideSession) { [self] in
            guard await closePanels() else { return nil }
            guard !Task.isCancelled else { return nil }
            switch trigger {
            case .selection:
                switch await SelectionReader.read(context: context) {
                case .success(let capture):
                    return CapturePipeline.selection(text: capture.text, context: capture.context)
                case .failure(let error): selectionFailed(error)
                }
            case .region:
                do {
                    switch try await RegionCapturer.capture(context: context) {
                    case .captured(let capture):
                        let fallback = PendingCapture(trigger: .region, content: .image(png: capture.pngData, ocr: nil),
                                                      source: CapturePipeline.source(capture.context), subtitle: "Image")
                        recordAcquiredImage(fallback)
                        return fallback
                    case .cancelled: break
                    case .permissionNeeded:
                        if !requestedScreenCapture, !isTerminating {
                            requestedScreenCapture = true
                            permissionGuide.show(for: .screenCapture)
                        }
                        showToast(Toast(style: .warning, title: "Allow Screen Recording to capture areas",
                                                   subtitle: "Open the menu bar icon → Permissions"))
                    }
                } catch {
                    report(error, title: "Couldn't capture area")
                }
            }
            return nil
        } postprocess: { [pipeline] acquired in
            guard case .image(let png, _) = acquired.content else { return acquired }
            return await pipeline.region(png: png, context: context, id: acquired.id, createdAt: acquired.createdAt)
        }
    }

    @discardableResult
    func beginAcquisition(outsideSession: Bool = false, _ operation: @escaping @MainActor () async -> PendingCapture?,
                          postprocess: (@Sendable (PendingCapture) async -> PendingCapture)? = nil) -> Bool {
        guard !isTerminating, !acquisitionInProgress else { return false }
        acquisitionInProgress = true
        acquisitionOutsideSession = outsideSession
        acquisitionGeneration += 1
        let generation = acquisitionGeneration
        acquisitionTask = Task { [self] in
            let result = await operation()
            guard acquisitionGeneration == generation, !shutdownFinished else { return }
            acquisitionFallback = nil
            acquisitionInProgress = false
            acquisitionTask = nil
            guard let result else { return }
            journalAcquisition(result, outsideSession: outsideSession)
            let processed = Task { await postprocess?(result) ?? result }
            let previous = processingTail
            processingGeneration += 1
            let processingID = processingGeneration
            processingTail = Task { [self] in
                await previous?.value
                await stage(processed.value, outsideSession: outsideSession)
                if processingGeneration == processingID { processingTail = nil }
            }
        }
        return true
    }

    func recordAcquiredImage(_ capture: PendingCapture) {
        acquisitionFallback = capture
        if isTerminating { journalAcquisition(capture, outsideSession: acquisitionOutsideSession) }
    }

    private func journalAcquisition(_ capture: PendingCapture, outsideSession: Bool = false) {
        guard recoveryJobs[capture.id] == nil else { return }
        let pipeline = pipeline
        let preparation = Task.detached(priority: .userInitiated) {
            try await pipeline.prepare(capture, noteTitle: nil, outsideSession: outsideSession)
        }
        recoveryJobs[capture.id] = preparation
        recoveryPersistences[capture.id] = Task.detached(priority: .userInitiated) {
            try await pipeline.journal.store(try await preparation.value)
        }
    }

    private func selectionFailed(_ failure: SelectionFailure) {
        let warning: Toast
        switch failure {
        case .noSelection:
            warning = Toast(style: .warning, title: "No text selected", subtitle: "Select text first, or use ⌥⇧S for an area")
        case .secureInput:
            warning = Toast(style: .warning, title: "Can't capture from secure fields")
        case .accessibilityNotTrusted:
            warning = Toast(style: .warning, title: "Allow Accessibility to capture text", subtitle: "Open the menu bar icon → Permissions")
        case .ownApp: return
        }
        showToast(warning)
    }

    func stage(_ capture: PendingCapture, outsideSession: Bool = false) async {
        guard !shutdownFinished else { return }
        _ = commitPending()
        let pipeline = pipeline
        let recovery = recoveryJobs[capture.id]
        let recoveryPersistence = recoveryPersistences[capture.id]
        let preparation = Task.detached(priority: .userInitiated) {
            let recovered = try? await recovery?.value
            return try await pipeline.prepare(capture, noteTitle: nil, destination: recovered?.prepared.destination, outsideSession: outsideSession)
        }
        let persistence = Task.detached(priority: .userInitiated) {
            _ = try? await recoveryPersistence?.value
            try await pipeline.journal.store(try await preparation.value)
        }
        stagedJob = (capture.id, preparation, persistence)
        pending = capture
        pendingOutsideSession = outsideSession
        // Persist the default job before showing the toast or accepting a note title.
        do { try await persistence.value }
        catch { report(error, title: "Couldn't journal capture") }
        guard pending?.id == capture.id else { return }
        if isTerminating { _ = commitPending(); return }
        let session = await pipeline.sessions.current()
        guard presentsUI, pending?.id == capture.id, !isTerminating else { return }
        if outsideSession {
            showTitlePicker(for: capture.id)
            return
        }
        pendingToastID = capture.id
        toast.show(Toast(style: .success,
                         title: session.map { "Added to \($0.name)" } ?? "Saved to \(Vault.inboxTitle)",
                         subtitle: capture.subtitle, hint: .init(key: capture.trigger.hotkey.displayString, label: "choose note")))
    }

    @discardableResult
    func commitPending(noteTitle: String? = nil, destination: Destination? = nil, announce: Bool = false) -> Task<SavedCapture, Error>? {
        guard let capture = pending else { return nil }
        let outsideSession = pendingOutsideSession
        pending = nil
        pendingOutsideSession = false
        pendingToastID = nil
        pendingNeedsRetryChoice = false
        if presentsUI { toast.dismiss(expire: false) }
        let previous = commitTail
        let pipeline = pipeline
        let staged = stagedJob.flatMap { $0.id == capture.id ? $0 : nil }
        stagedJob = nil
        // Only shutdown's acquired-pixel fallback forces its original destination.
        let recovery = isTerminating ? recoveryJobs[capture.id] : nil
        let recoveryPersistence = recoveryPersistences[capture.id]
        let preparation = Task.detached(priority: .userInitiated) {
            let resolvedDestination: Destination?
            if let recovery { resolvedDestination = try? await recovery.value.prepared.destination }
            else if let destination { resolvedDestination = destination }
            else if noteTitle == nil { resolvedDestination = try? await staged?.preparation.value.prepared.destination }
            else { resolvedDestination = nil }
            if destination != nil {
                guard let resolvedDestination,
                      let noteID = try? pipeline.vault.noteID(for: resolvedDestination.url),
                      try pipeline.vault.fileSnapshot(relativePath: noteID, includingContents: false) != nil else {
                    throw CocoaError(.fileNoSuchFile)
                }
            }
            return try await pipeline.prepare(capture, noteTitle: noteTitle, destination: resolvedDestination, outsideSession: outsideSession)
        }
        preparedJobs[capture.id] = preparation
        // Journal before waiting for earlier writes, so even queued work is recoverable.
        let task = Task.detached(priority: .userInitiated) {
            let job = try await preparation.value
            _ = try? await staged?.persistence.value
            _ = try? await recoveryPersistence?.value
            try await pipeline.journal.store(job)
            _ = try? await previous?.value
            return try await pipeline.commit(job)
        }
        commitTail = task
        commitGeneration += 1
        let generation = commitGeneration
        Task { [weak self] in
            do {
                let saved = try await task.value
                self?.preparedJobs.removeValue(forKey: capture.id)
                self?.recoveryJobs.removeValue(forKey: capture.id)
                self?.recoveryPersistences.removeValue(forKey: capture.id)
                if announce, self?.pending == nil {
                    let session = outsideSession ? await pipeline.sessions.current() : nil
                    let title = "\(outsideSession ? "Added" : "Saved") to \(saved.destination.title)"
                        + (session.map { " · \($0.name) still active" } ?? "")
                    if self?.pending == nil { self?.showToast(Toast(style: .success, title: title, duration: 1.6)) }
                }
            } catch {
                if (noteTitle != nil || destination != nil), case .failure = await preparation.result, let staged {
                    self?.preparedJobs.removeValue(forKey: capture.id)
                    if self?.pending == nil {
                        self?.stagedJob = staged
                        self?.pending = capture
                        self?.pendingOutsideSession = outsideSession
                        self?.pendingToastID = nil
                        self?.pendingNeedsRetryChoice = true
                        if let routerError = error as? RouterError,
                           case .ambiguous(let candidates) = routerError {
                            self?.showAmbiguousDestinationPicker(candidates, capture: capture)
                        } else {
                            self?.showRetrySaveFailure(error, capture: capture)
                        }
                    } else {
                        let fallback = try? await staged.preparation.value.prepared.destination
                        self?.preparedJobs[capture.id] = staged.preparation
                        self?.showPreviousCaptureRecoveryNotice(destination: fallback)
                    }
                } else {
                    self?.reportUserSaveFailure(error, title: "Couldn't save capture")
                }
            }
            if self?.commitGeneration == generation { self?.commitTail = nil }
        }
        return task
    }

    func waitForProcessing() async { await processingTail?.value }

    private func waitForCommits() async { _ = try? await commitTail?.value }

    func drainCaptures() async {
        // Acquisition assigns the destination during staging. Drain it before
        // ending or starting a session so the active session cannot change first.
        let acquisition = acquisitionTask
        await acquisition?.value
        _ = commitPending()
        await processingTail?.value
        _ = commitPending()
        await waitForCommits()
    }

    /// Keep the main actor running while acquisitions and journaled writes drain.
    func beginTermination(timeout: Duration = .seconds(5)) -> Task<Bool, Never> {
        if let shutdownTask { return shutdownTask }
        // A failed final draft write must leave the app and its services usable for retry.
        editor?.dismiss()
        guard editor?.isVisible != true else { return Task { false } }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        isTerminating = true
        folderShortcutsPanel?.close()
        permissionGuide.dismiss()
        startupIndexTask?.cancel()
        pipeline.monitor.stop()
        powerMonitor?.stop()
        powerMonitor = nil
        hotkeys.unregisterAll()
        // Interactive dismissal is synchronous; cancel commits the pending default first.
        input?.dismiss()
        search?.dismiss()
        _ = commitPending()
        let pipeline = pipeline
        // OCR already owns pixels. Keep those pixels in a fixed-destination recovery
        // record while waiting, so a deadline cannot discard an unfinished OCR result.
        if let fallback = acquisitionFallback {
            journalAcquisition(fallback, outsideSession: acquisitionOutsideSession)
        }
        let acquisition = acquisitionTask
        let actions = actionTail
        let startup = startupReplayTask
        semanticModels?.cancelDownload()
        let drain = Task { [self] in
            await pipeline.semantic.stop()
            _ = await startup?.value
            await acquisition?.value
            await processingTail?.value
            await actions?.value
            for persistence in recoveryPersistences.values {
                do { try await persistence.value }
                catch { logger.error("Shutdown recovery journal failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)") }
            }
            guard !shutdownFinished else { return }
            _ = commitPending()
            await waitForCommits()
            guard !shutdownFinished else { return }
            // A journal write itself may have failed earlier. Retry the exact prepared
            // capture, never its title or destination routing.
            for (id, preparation) in preparedJobs {
                do {
                    let job = try await preparation.value
                    try await pipeline.journal.store(job)
                    _ = try await pipeline.commit(job) { [weak self] saved, pinFailed in
                        self?.showNoteSaveFeedback(saved, pinFailed: pinFailed)
                    }
                    preparedJobs.removeValue(forKey: id)
                } catch { logger.error("Shutdown save retained in journal (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)") }
            }
        }
        let task = Task { [self] in
            let completed = await waitForShutdown(drain, until: deadline)
            shutdownFinished = true
            if !completed {
                acquisitionGeneration += 1
                acquisitionTask?.cancel()
                drain.cancel()
                logger.warning("Shutdown reached its deadline; prepared captures remain in the recovery journal")
            }
            return true
        }
        shutdownTask = task
        return task
    }

    private func showTitlePicker(for id: UUID) {
        let outsideSession = pendingOutsideSession
        pendingToastID = nil
        toast.dismiss(expire: false)
        enqueue { controller in
            guard await controller.closePanels() else { return }
            guard controller.pending?.id == id else { return }
            let suggestions = await controller.suggestionSnapshot(sessionsOnly: false)
            guard controller.pending?.id == id, !controller.isTerminating else { return }
            controller.presentInput(placeholder: "Add to note…", suggestions: suggestions, onAccept: { [weak controller] noteTitle in
                guard controller?.pending?.id == id else { return }
                _ = controller?.commitPending(noteTitle: noteTitle, announce: true)
            }, onSubmit: { _ in }, onCancel: { [weak controller] in
                guard controller?.pending?.id == id else { return }
                if let controller, controller.pendingNeedsRetryChoice, let capture = controller.pending {
                    controller.showRetryChoice(capture: capture, title: "Choose where to save")
                } else {
                    _ = controller?.commitPending(announce: outsideSession)
                }
            })
        }
    }

    private func showAmbiguousDestinationPicker(_ candidates: [Destination], capture: PendingCapture) {
        enqueue { controller in
            guard await controller.closePanels(), controller.pending?.id == capture.id, !controller.isTerminating else { return }
            let suggestions = candidates.map { candidate in
                let path = controller.pipeline.vault.relativePath(of: candidate.url) ?? candidate.url.path
                return Suggestion(title: candidate.title,
                                  secondary: "\(candidate.kind == .session ? "Session" : "Note") · \(path)",
                                  symbolName: candidate.kind == .session ? "record.circle" : "doc.text",
                                  value: candidate.url.absoluteString)
            }
            let panel = InputPanelController()
            controller.input = panel
            controller.isChoosingDestination = true
            panel.present(placeholder: "Choose an exact note…", title: "Several notes have that name",
                          secondary: "Select the path to choose the destination", selectionOnly: true,
                          suggestions: { prefix in
                let key = NoteTitle.matchKey(prefix)
                return suggestions.filter {
                    key.isEmpty || NoteTitle.matchKey($0.title + " " + ($0.secondary ?? "")).contains(key)
                }
            }, onSubmit: { [weak controller] urlString in
                guard let controller else { return }
                controller.inputClosed()
                guard controller.pending?.id == capture.id,
                      let candidate = candidates.first(where: { $0.url.absoluteString == urlString }) else { return }
                controller.enqueue { controller in
                    guard await controller.closePanels(), controller.pending?.id == capture.id else { return }
                    _ = controller.commitPending(destination: candidate, announce: true)
                }
            }, onCancel: { [weak controller] in
                guard let controller else { return }
                controller.inputClosed()
                guard controller.pending?.id == capture.id else { return }
                controller.showRetryChoice(capture: capture, title: "Choose where to save")
            })
        }
    }

    private func suggestionSnapshot(sessionsOnly: Bool) async -> [NoteSuggestion] {
        do {
            // InputPanel's provider is synchronous. A sorted snapshot allows the same prefix
            // filtering as titleSuggestions, without blocking the main actor on SQLite.
            return try await pipeline.index.titleSuggestions(prefix: "", limit: Int.max)
                .filter { !sessionsOnly || $0.kind == .session }
        } catch {
            logger.error("Title suggestions failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
            return []
        }
    }

    private func presentInput(placeholder: String, title: String? = nil, secondary: String? = nil,
                              suggestions: [NoteSuggestion],
                              suggestionValue: ((NoteSuggestion) -> String?)? = nil,
                              onAccept: ((String) -> Void)? = nil,
                              onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard !isTerminating else { return }
        let panel = InputPanelController()
        input = panel
        let calendar = pipeline.calendar
        panel.present(placeholder: placeholder, title: title, secondary: secondary, suggestions: { prefix in
            let key = NoteTitle.matchKey(prefix)
            return suggestions.filter { key.isEmpty || NoteTitle.matchKey($0.title).hasPrefix(key) }.prefix(8).map {
                let session = $0.kind == .session
                let date = Self.stamp($0.modified, pattern: "MMM d, yyyy", calendar: calendar)
                let detail = "\(session ? "Session" : "Note") · \(date)"
                let pathDetail = session ? "\(detail) · \($0.path)" : detail
                return Suggestion(title: $0.title,
                                  secondary: pathDetail,
                                  symbolName: session ? "record.circle" : "doc.text",
                                  value: suggestionValue?($0))
            }
        }, onAccept: onAccept, onSubmit: { [weak self] text in
            self?.inputClosed()
            onSubmit(text)
        }, onCancel: { [weak self] in
            self?.inputClosed()
            onCancel()
        })
    }

    private func inputClosed() {
        input = nil
        isChoosingDestination = false
        let waiters = inputCloseWaiters
        inputCloseWaiters = []
        waiters.forEach { $0.resume() }
    }

    @discardableResult
    private func closePanels() async -> Bool {
        if let editor {
            editor.dismiss()
            if editor.isVisible { return false }
        }
        if let input {
            await withCheckedContinuation { continuation in
                inputCloseWaiters.append(continuation)
                input.dismiss()
            }
        }
        if let search {
            await withCheckedContinuation { continuation in
                searchCloseWaiters.append(continuation)
                search.dismiss()
            }
        }
        return true
    }

    private func toggleSession() {
        enqueue { controller in
            await controller.drainCaptures()
            guard await controller.closePanels() else { return }
            await controller.waitForCommits()
            guard !controller.isTerminating else { return }
            if let session = await controller.pipeline.sessions.current() {
                do { _ = try await controller.endSession(session) }
                catch { controller.report(error, title: "Couldn't end session") }
            } else {
                let suggestions = await controller.suggestionSnapshot(sessionsOnly: true)
                controller.presentInput(placeholder: "Session name", suggestions: suggestions, onSubmit: { [weak controller] name in
                    controller?.enqueue { controller in
                        _ = controller.commitPending()
                        await controller.waitForCommits()
                        do { _ = try await controller.startSession(name: name) }
                        catch SessionStoreError.ambiguous(let candidates) {
                            controller.presentSessionCandidates(candidates)
                        } catch { controller.report(error, title: "Couldn't start session") }
                    }
                }, onCancel: {})
            }
        }
    }

    @discardableResult
    func startSession(name: String) async throws -> Session {
        try await pipeline.recoverSessionIdentity()
        let session = try await pipeline.sessions.start(name: name)
        return try await activateSession(session)
    }

    private func resumeSession(_ candidate: SessionCandidate) async throws -> Session {
        try await pipeline.recoverSessionIdentity()
        let session = try await pipeline.sessions.resume(candidate)
        return try await activateSession(session)
    }

    @discardableResult
    func renameSession(_ candidate: SessionCandidate, to name: String) async throws -> Session {
        var knownJobs: [CaptureJob] = []
        var tasks = Array(preparedJobs.values) + Array(recoveryJobs.values)
        if let stagedJob { tasks.append(stagedJob.preparation) }
        for task in tasks {
            if let job = try? await task.value { knownJobs.append(job) }
        }
        let outcome = try await pipeline.renameSession(candidate, to: name, preparedJobs: knownJobs)
        activeSession = outcome.session
        refreshStatus()
        if outcome.identityUpdatePending {
            showToast(Toast(style: .warning, title: "Session renamed · \(outcome.session.name)",
                            subtitle: "State updates will be retried before the next save."))
        } else {
            showToast(Toast(style: .session, title: "Session resumed · \(outcome.session.name)", subtitle: "Captures go here until ⌥⇧A"))
        }
        return outcome.session
    }

    private func activateSession(_ session: Session) async throws -> Session {
        activeSession = session
        refreshStatus()
        try await pipeline.index.reindex(note: pipeline.vault.root.appendingPathComponent(session.notePath))
        showToast(Toast(style: .session, title: "Session \(session.resumed == true ? "resumed" : "started") · \(session.name)", subtitle: "Captures go here until ⌥⇧A"))
        return session
    }

    var inputForChecks: InputPanelController? { input }
    var pendingForChecks: PendingCapture? { pending }
    var isChoosingDestinationForChecks: Bool { isChoosingDestination }

    func presentSessionCandidates(_ candidates: [SessionCandidate], selectedPath: String? = nil) {
        let calendar = pipeline.calendar
        let choices = candidates.map {
            Suggestion(title: $0.name,
                       secondary: "Modified \(Self.stamp($0.modifiedAt, pattern: "MMM d, yyyy", calendar: calendar)) · \($0.notePath)",
                       symbolName: "record.circle",
                       value: $0.notePath)
        }
        let panel = InputPanelController()
        input = panel
        panel.present(placeholder: "Select a session…",
                      title: "Multiple sessions found with the given name",
                      secondary: "↩ Resume · ⌘↩ Rename and resume",
                      selectionOnly: true,
                      selectedValue: selectedPath,
                      suggestions: { prefix in
            let key = NoteTitle.matchKey(prefix)
            return choices.filter { key.isEmpty || NoteTitle.matchKey($0.title).hasPrefix(key) }
        }, onAlternateSubmit: { [weak self] path in
            self?.inputClosed()
            guard let self, let candidate = candidates.first(where: { $0.notePath == path }) else { return }
            self.presentSessionRename(candidate, candidates: candidates)
        }, onSubmit: { [weak self] path in
            self?.inputClosed()
            guard let self, let candidate = candidates.first(where: { $0.notePath == path }) else { return }
            self.enqueue { controller in
                _ = controller.commitPending()
                await controller.waitForCommits()
                do { _ = try await controller.resumeSession(candidate) }
                catch { controller.report(error, title: "Couldn't resume session") }
            }
        }, onCancel: { [weak self] in self?.inputClosed() })
    }

    private func presentSessionRename(_ candidate: SessionCandidate, candidates: [SessionCandidate],
                                      name: String? = nil, errorMessage: String? = nil) {
        guard !isTerminating else { return }
        let panel = InputPanelController()
        input = panel
        panel.present(placeholder: "New session name", initialText: name ?? candidate.name, selectInitialText: true, title: "Rename session",
                      secondary: errorMessage ?? candidate.notePath, allowEmptySubmission: true, suggestions: { _ in [] },
                      onEscape: { [weak self] in
            self?.inputClosed()
            self?.presentSessionCandidates(candidates, selectedPath: candidate.notePath)
        },
                      onSubmit: { [weak self] name in
            self?.inputClosed()
            self?.enqueue { controller in
                await controller.drainCaptures()
                guard !controller.isTerminating else { return }
                do { _ = try await controller.renameSession(candidate, to: name) }
                catch {
                    controller.presentSessionRename(candidate, candidates: candidates, name: name,
                                                    errorMessage: error.localizedDescription)
                }
            }
        }, onCancel: { [weak self] in self?.inputClosed() })
    }

    @discardableResult
    func endSession(_ session: Session) async throws -> Int {
        try await pipeline.recoverSessionIdentity()
        try await pipeline.sessions.end()
        activeSession = nil
        refreshStatus()
        let count = try await pipeline.index.captureCount(notePath: session.notePath)
        showToast(Toast(style: .session, title: "Session ended · \(session.name)", subtitle: count == 1 ? "1 capture" : "\(count) captures"))
        return count
    }

    func openNoteEditor(folder requestedFolder: NoteFolder? = nil, outsideSession requestedOutside: Bool = false) {
        enqueue { controller in
            if requestedFolder == nil, !requestedOutside, let editor = controller.editor, editor.isVisible {
                if editor.isKey { editor.dismiss() } else { editor.focus() }
                return
            }
            let pendingCommit = controller.commitPending()
            await controller.processingTail?.value
            let processedCommit = controller.commitPending()
            guard await controller.closePanels() else { return }
            let tail = controller.commitTail
            do {
                _ = try await pendingCommit?.value
                _ = try await processedCommit?.value
                _ = try await tail?.value
            } catch { controller.report(error, title: "Couldn't save pending capture"); return }
            guard !controller.isTerminating else { return }
            let pipeline = controller.pipeline
            do { try await pipeline.recoverSessionIdentity() }
            catch { controller.report(error, title: "Couldn't restore session state"); return }
            let active = await pipeline.sessions.current()
            let restored: NoteDraftSnapshot
            do { restored = try pipeline.drafts.loadSnapshot() }
            catch { controller.report(error, title: "Couldn't restore draft"); return }
            let folder = requestedFolder ?? restored.folder
            let sessionDestination: Destination?
            if folder == nil, let active {
                do {
                    sessionDestination = try Router.destination(noteTitle: nil, activeSession: active,
                                                                 notes: [], vault: pipeline.vault)
                } catch {
                    controller.report(error, title: "Couldn't resolve note destination")
                    return
                }
            } else { sessionDestination = nil }
            do {
                let draft = restored.text
                let editor = NoteEditorPanel()
                controller.editor = editor
                // Outside launch only matters with a session; otherwise it is a plain quick note.
                let state = QuickNoteState(destination: sessionDestination, pinOnSave: restored.pinOnSave, folder: folder,
                                           outsideSession: requestedOutside && sessionDestination != nil)
                let calendar = pipeline.calendar
                func noteID(_ destination: Destination?) -> String? {
                    destination.flatMap { try? pipeline.vault.noteID(for: $0.url) }
                }
                @MainActor func save(_ text: String, controller: AppController, newNote: Bool = false) async throws -> SavedCapture? {
                    return try await controller.addNote(text, destination: state.destination, pinOnSave: state.pinOnSave, newNote: newNote, outsideSession: state.outsideSession, folder: state.folder)
                }
                let initiallyPinned = noteID(state.destination).map { pipeline.pins.isPinned($0) } ?? state.pinOnSave
                // Persist a shortcut's explicit destination before editing an existing draft.
                try pipeline.drafts.store(draft, pinOnSave: state.pinOnSave, folder: folder)
                editor.present(destination: state.destinationLabel, isPinned: initiallyPinned, draft: draft, handlers: NoteEditorHandlers(
                    onDraft: { [weak editor] text in
                        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        try pipeline.drafts.flushScheduledStore(text, pinOnSave: blank ? false : state.pinOnSave, folder: state.folder)
                        if blank {
                            state.pinOnSave = false
                            editor?.setDestination(state.destinationLabel, isPinned: noteID(state.destination).map { pipeline.pins.isPinned($0) } ?? false)
                        }
                    },
                    onSubmit: { [weak controller] text in
                        controller?.enqueue { controller in
                            do { _ = try await save(text, controller: controller) }
                            catch { controller.reportUserSaveFailure(error, title: "Couldn't add note; draft kept") }
                        }
                    },
                    onNew: { [weak controller, weak editor] text in
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            do { try state.restoreSessionDestination(sessionDestination, drafts: pipeline.drafts) }
                            catch { controller?.report(error, title: "Couldn't reset draft pin"); return }
                            editor?.setDestination(state.destinationLabel, isPinned: noteID(state.destination).map { pipeline.pins.isPinned($0) } ?? false)
                            return
                        }
                        controller?.enqueue { controller in
                            do {
                                _ = try await save(text, controller: controller)
                                controller.openNoteEditor(folder: state.folder, outsideSession: requestedOutside)
                            } catch { controller.reportUserSaveFailure(error, title: "Couldn't add note; draft kept") }
                        }
                    },
                    onOpenAsNote: { [weak controller] text in
                        controller?.enqueue { controller in
                            do {
                                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    if let saved = try await save(text, controller: controller) { controller.openNote(saved.destination.url); return }
                                } else if let url = state.destination?.url, FileManager.default.fileExists(atPath: url.path) {
                                    controller.openNote(url); return
                                }
                                controller.showToast(Toast(style: .warning, title: "Nothing to open yet", subtitle: "Write something first"))
                            } catch { controller.reportUserSaveFailure(error, title: "Couldn't add note; draft kept") }
                        }
                    },
                    browseItems: {
                        let pinned = pipeline.pins.paths()
                        return state.suggestions.sorted { $0.modified > $1.modified }.map {
                            let session = $0.kind == .session
                            let symbol = session ? "record.circle" : "doc.text"
                            return BrowseItem(id: $0.path, title: $0.title,
                                              detail: "\(session ? "Session" : "Note") · \(Self.stamp($0.modified, pattern: "MMM d", calendar: calendar))",
                                              symbolName: symbol, isPinned: pinned.contains($0.path))
                        }
                    },
                    onBrowse: { [weak controller, weak editor] item, choice in
                        switch choice {
                        case .write:
                            do { try state.resetPinOnSave(in: pipeline.drafts) }
                            catch { controller?.report(error, title: "Couldn't reset draft pin"); return }
                            do {
                                let location = try pipeline.vault.noteLocation(forID: item.id)
                                state.destination = Destination(url: location.url, title: item.title, kind: state.kinds[item.id] ?? .note)
                            } catch { controller?.report(error, title: "Couldn't select note"); return }
                            editor?.setDestination(item.title, isPinned: pipeline.pins.isPinned(item.id))
                        case .open:
                            do { controller?.openNote(try pipeline.vault.noteLocation(forID: item.id).url) }
                            catch { controller?.report(error, title: "Couldn't open note") }
                        case .reveal:
                            do { controller?.revealNote(try pipeline.vault.noteLocation(forID: item.id).url) }
                            catch { controller?.report(error, title: "Couldn't reveal note") }
                        }
                    },
                    onTogglePin: { [weak controller] in
                        do {
                            guard let destination = state.destination else { return try state.togglePinOnSave(in: pipeline.drafts) }
                            guard let path = noteID(destination) else { return false }
                            guard FileManager.default.fileExists(atPath: destination.url.path) else { return try state.togglePinOnSave(in: pipeline.drafts) }
                            return try pipeline.pins.toggle(path)
                        } catch {
                            controller?.report(error, title: "Couldn't update Pinned")
                            return noteID(state.destination).map { pipeline.pins.isPinned($0) } ?? state.pinOnSave
                        }
                    },
                    onClose: { [weak controller] in controller?.editor = nil },
                    onError: { [weak controller] error in controller?.report(error, title: "Couldn't keep draft; editor stays open") },
                    titleForText: { TypedNote(markdown: $0, createdAt: Date(), calendar: calendar).title },
                    onScheduleDraft: { [weak controller, weak editor] text in
                        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        pipeline.drafts.scheduleStore(text, pinOnSave: blank ? false : state.pinOnSave, folder: state.folder) { [weak controller] error in
                            Task { @MainActor in controller?.report(error, title: "Couldn't keep draft; editor stays open") }
                        }
                        if blank {
                            state.pinOnSave = false
                            editor?.setDestination(state.destinationLabel, isPinned: noteID(state.destination).map { pipeline.pins.isPinned($0) } ?? false)
                        }
                    },
                    existingTitleForText: { text in
                        // A session or Browse destination takes precedence over typed-name matching, as in prepareNote.
                        guard state.destination == nil, sessionDestination == nil || state.outsideSession else { return nil }
                        let note = TypedNote(markdown: text, createdAt: Date(), calendar: calendar)
                        return (try? CaptureService.appendTarget(for: note, reserved: pipeline.service.reservedNoteURLs, vault: pipeline.vault, folder: state.folder))?.title
                    },
                    onSaveAsNew: { [weak controller] text in
                        controller?.enqueue { controller in
                            do { _ = try await save(text, controller: controller, newNote: true) }
                            catch { controller.reportUserSaveFailure(error, title: "Couldn't add note; draft kept") }
                        }
                    },
                    onWriteOutsideSession: sessionDestination.map { sessionDestination in
                        { [weak controller, weak editor] in
                            do { try state.toggleOutsideSession(sessionDestination: sessionDestination, drafts: pipeline.drafts) }
                            catch { controller?.report(error, title: "Couldn't change note destination"); return }
                            editor?.setDestination(state.destinationLabel, isPinned: noteID(state.destination).map { pipeline.pins.isPinned($0) } ?? false)
                        }
                    }))
                Task { @MainActor [weak controller, weak state, weak editor] in
                    guard let controller else { return }
                    let list = await controller.suggestionSnapshot(sessionsOnly: false)
                    guard !controller.isTerminating, let state else { return }
                    state.suggestions = list
                    editor?.refreshBrowseItems()
                }
            } catch { controller.report(error, title: "Couldn't restore draft") }
        }
    }

    private func openNote(_ url: URL) { NSWorkspace.shared.open(url) }
    private func revealNote(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Used by both ⌥⇧N and the permission-free self-test. Persist text before any
    /// suspension; failed saves retain the draft and the exact journaled identity.
    /// `newNote` forces a new note (Save as New Note) even when the title names an existing one.
    @discardableResult
    func addNote(_ rawText: String, destination: Destination? = nil, pinOnSave: Bool = false, newNote: Bool = false, outsideSession: Bool = false, folder: NoteFolder? = nil) async throws -> SavedCapture? {
        guard !isTerminating else { return nil }
        try pipeline.drafts.store(rawText, pinOnSave: pinOnSave, folder: folder)
        let text = CaptureFormat.noteBody(rawText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let pendingCommit = commitPending()
        await processingTail?.value
        let processedCommit = commitPending()
        _ = try await pendingCommit?.value
        _ = try await processedCommit?.value
        let pipeline = pipeline
        var retry: Task<CaptureJob, Error>?
        var superseded: [UUID: UUID] = [:]
        for (key, candidate) in Array(preparedJobs) {
            guard let job = try? await candidate.value else { continue }
            if job.noteDraft.map(CaptureFormat.noteBody) == text || (job.noteDraft == nil && job.prepared.capture.content == .note(text)) {
                if job.noteOutsideSession != outsideSession || job.noteFolder != folder || (destination != nil && job.prepared.destination != destination) {
                    superseded[key] = job.prepared.capture.id
                    continue
                }
                if destination == nil || job.prepared.destination == destination {
                    if newNote && job.prepared.createsNote != true {
                        superseded[key] = job.prepared.capture.id
                        continue
                    }
                    retry = candidate; break
                }
            }
        }
        // A changed route or Save as New Note replaces the earlier job for this draft; replay must not also append it.
        // Remove from the journal first; on failure the draft is kept and the old job stays retryable.
        for (key, id) in superseded {
            try await pipeline.journal.remove(id: id)
            preparedJobs.removeValue(forKey: key)
        }
        let capture = Capture(id: UUID(), createdAt: Date(), content: .note(text), source: CaptureSource())
        let preparation = retry ?? Task.detached(priority: .userInitiated) {
            let prepared = try await pipeline.prepareNote(capture, destination: destination, newNote: newNote, outsideSession: outsideSession, folder: folder)
            return CaptureJob(prepared: prepared, png: nil, ocr: nil, noteDraft: rawText, noteOutsideSession: outsideSession, noteFolder: folder)
        }
        let preparedNote = try await preparation.value.prepared
        let noteID = preparedNote.capture.id
        preparedJobs[noteID] = preparation
        let previous = commitTail
        let outsideSessionName = outsideSession ? await pipeline.sessions.current()?.name : nil
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let job = try await preparation.value
            try await pipeline.journal.store(job)
            _ = try? await previous?.value
            return try await pipeline.commit(job, pinOnSave: pinOnSave) { [weak self] saved, pinFailed in
                self?.showNoteSaveFeedback(saved, pinFailed: pinFailed, created: job.prepared.createsNote == true, text: text, outsideSessionName: outsideSessionName)
            }
        }
        commitTail = task
        commitGeneration += 1
        let generation = commitGeneration
        // A failed commit must clear the tail too, or later editor opens keep rethrowing it.
        defer { if commitGeneration == generation { commitTail = nil } }
        let saved = try await task.value
        preparedJobs.removeValue(forKey: noteID)
        return saved
    }

    func openSubheading() {
        enqueue { controller in
            await controller.drainCaptures()
            guard await controller.closePanels() else { return }
            await controller.waitForCommits()
            guard !controller.isTerminating else { return }
            let destination: Destination
            do {
                try await controller.pipeline.recoverSessionIdentity()
                let active = await controller.pipeline.sessions.current()
                destination = try Router.destination(noteTitle: nil, activeSession: active,
                                                     notes: [], vault: controller.pipeline.vault)
            } catch {
                controller.report(error, title: "Couldn't resolve note destination")
                return
            }
            controller.presentInput(placeholder: "Subheading", title: "Add subheading", secondary: "In \(destination.title)",
                                    suggestions: [], onSubmit: { [weak controller] text in
                controller?.enqueue { controller in
                    do { _ = try await controller.addSubheading(text, destination: destination) }
                    catch { controller.report(error, title: "Couldn't add subheading") }
                }
            }, onCancel: {})
        }
    }

    /// The hotkey's submit path is also callable by the permission-free self-test.
    @discardableResult
    func addSubheading(_ text: String, destination: Destination? = nil) async throws -> SavedCapture? {
        let text = CaptureFormat.cleanSubheading(text)
        guard !text.isEmpty, !isTerminating else { return nil }
        _ = commitPending()
        await processingTail?.value
        _ = commitPending()
        let pipeline = pipeline
        let capture = Capture(id: UUID(), createdAt: Date(), content: .subheading(text), source: CaptureSource())
        let preparation = Task.detached(priority: .userInitiated) {
            let prepared = try await pipeline.prepareCapture(capture, destination: destination)
            return CaptureJob(prepared: prepared, png: nil, ocr: nil)
        }
        preparedJobs[capture.id] = preparation
        let previous = commitTail
        let task = Task.detached(priority: .userInitiated) {
            let job = try await preparation.value
            try await pipeline.journal.store(job)
            _ = try? await previous?.value
            return try await pipeline.commit(job)
        }
        commitTail = task
        commitGeneration += 1
        let generation = commitGeneration
        defer { if commitGeneration == generation { commitTail = nil } }
        let saved = try await task.value
        preparedJobs.removeValue(forKey: capture.id)
        showToast(Toast(style: .success, title: "Subheading added", subtitle: text))
        return saved
    }

    private func openSearch() {
        enqueue { controller in
            await controller.drainCaptures()
            guard await controller.closePanels() else { return }
            await controller.waitForCommits()
            guard !controller.isTerminating else { return }
            let pipeline = controller.pipeline
            if !pipeline.monitor.isRunning {
                Task.detached(priority: .utility) { await pipeline.sync() }
            }
            Task.detached(priority: .utility) { await pipeline.semantic.warm() }
            let panel = SearchPanelController()
            controller.search = panel
            let snapshot = SearchSnapshot()
            panel.present(query: { [weak controller] query in
                guard let controller else { return [] }
                do {
                    let empty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let hits: [SearchHit]
                    if empty {
                        hits = try await pipeline.index.recent(limit: 20)
                    } else {
                        async let keyword = pipeline.index.search(query)
                        async let semantic = pipeline.semantic.search(query)
                        hits = try await SemanticIndexer.fuse(keyword: keyword, semantic: semantic)
                    }
                    guard !Task.isCancelled else { return [] }
                    // Old rows may still be rendered while the next generation is built.
                    let previousIDs = snapshot.currentIDs
                    snapshot.hits = snapshot.hits.filter { previousIDs.contains($0.key) }
                    snapshot.currentIDs = []
                    snapshot.generation += 1
                    let generation = snapshot.generation
                    let rows = hits.map { hit in
                        let id = "\(generation):\(hit.blockID)"
                        snapshot.hits[id] = hit
                        snapshot.currentIDs.insert(id)
                        return controller.row(hit, id: id)
                    }
                    return [SearchSection(title: empty ? "Recent" : "Results", rows: rows)]
                } catch {
                    controller.logger.error("Search failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
                    return [SearchSection(title: "Results", rows: [], errorMessage: "Search failed. Try again.")]
                }
            }, actions: SearchActions(primary: { _ in }, open: { _ in }, reveal: { _ in }, onClose: { [weak controller] in
                guard let controller else { return }
                controller.search = nil
                let waiters = controller.searchCloseWaiters
                controller.searchCloseWaiters = []
                waiters.forEach { $0.resume() }
            }, freeze: { [weak controller] row, action in
                guard let hit = snapshot.hits[row.id] else { return nil }
                // Capture the full SearchHit now; query results cannot change the action.
                switch action {
                case .primary: return { [weak controller] in controller?.copy(hit) }
                case .open: return { [weak controller] in
                    do { _ = NSWorkspace.shared.open(try pipeline.vault.noteLocation(forID: hit.notePath).url) }
                    catch { controller?.report(error, title: "Couldn't open note") }
                }
                case .reveal: return { [weak controller] in
                    do { NSWorkspace.shared.activateFileViewerSelecting([try pipeline.vault.noteLocation(forID: hit.notePath).url]) }
                    catch { controller?.report(error, title: "Couldn't reveal note") }
                }
                }
            }))
        }
    }

    private func row(_ hit: SearchHit, id: String) -> SearchRow {
        var parts: [String] = []
        if let date = hit.createdAt {
            let pattern = pipeline.calendar.isDateInToday(date) ? "HH:mm" : (hit.blockKind == .note ? "MMM d · HH:mm" : "MMM d")
            parts.append(Self.stamp(date, pattern: pattern, calendar: pipeline.calendar))
        }
        if let app = hit.sourceApp, !app.isEmpty { parts.append(app) }
        let kind: SearchRow.Kind = switch hit.blockKind {
        case .text: .text
        case .image: .image
        case .loose, .note: .note
        }
        let loader: (@MainActor () async -> NSImage?)?
        if let assetPath = hit.assetPath {
            loader = {
                do {
                    let data = try await self.pipeline.assetData(assetPath)
                    guard let image = await AppMedia.thumbnail(pngData: data), !Task.isCancelled else { return nil }
                    return NSImage(cgImage: image, size: .zero)
                } catch { return nil }
            }
        } else { loader = nil }
        return SearchRow(id: id, title: hit.title, snippet: hit.snippet,
                         snippetMatches: hit.snippetMatches.map { NSRange($0, in: hit.snippet) },
                         meta: parts.joined(separator: " · "), kind: kind,
                         thumbnailLoader: loader)
    }

    private static func stamp(_ date: Date, pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func copy(_ hit: SearchHit) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let item = NSPasteboardItem()
                if hit.blockKind == .image, let path = hit.assetPath {
                    let data = try await pipeline.assetData(path)
                    let representations = try await AppMedia.imageRepresentations(pngData: data)
                    item.setData(representations.png, forType: .png)
                    item.setData(representations.tiff, forType: .tiff)
                } else {
                    item.setString(hit.body, forType: .string)
                }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
                showToast(Toast(style: .copied, title: "Copied"))
            } catch { report(error, title: "Couldn't copy capture") }
        }
    }

    private func showNoteSaveFeedback(_ saved: SavedCapture, pinFailed: Bool, created: Bool? = nil, text: String = "", outsideSessionName: String? = nil) {
        if pinFailed {
            showToast(Toast(style: .warning, title: "Note saved, but not pinned", subtitle: saved.destination.title))
        } else if let outsideSessionName {
            showToast(Toast(style: .success, title: "Saved to \(saved.destination.title) · \(outsideSessionName) still active"))
        } else if let created {
            let appended = !created && saved.destination.kind == .session
            showToast(Toast(style: .success, title: created ? "Note created" : appended ? "Saved to \(saved.destination.title)" : "Note added",
                            subtitle: created ? saved.destination.title : CapturePipeline.firstLine(text)))
        }
    }

    private func showToast(_ value: Toast) {
        _ = commitPending()
        pendingToastID = nil
        onToast?(value)
        if presentsUI, !isTerminating { toast.show(value) }
    }

    private func report(_ error: Error, title: String) {
        logger.error("\(title, privacy: .public) (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
        showToast(Toast(style: .warning, title: title))
    }

    private func reportUserSaveFailure(_ error: Error, title: String) {
        if let registryError = error as? ExternalNoteRegistryError {
            reportExternalRegistryProblem(registryError, forSave: true)
        } else {
            report(error, title: title)
        }
    }

    private func showRetrySaveFailure(_ error: Error, capture: PendingCapture) {
        logger.error("Couldn't save capture (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
        showRetryChoice(capture: capture, title: "Couldn't save to that note")
    }

    private func showRetryChoice(capture: PendingCapture, title: String) {
        let warning = Toast(style: .warning, title: title, subtitle: "Capture kept · press \(capture.trigger.hotkey.displayString) to choose again",
                            hint: .init(key: capture.trigger.hotkey.displayString, label: "choose note"))
        onToast?(warning)
        if presentsUI, !isTerminating { toast.show(warning) }
    }

    private func showPreviousCaptureRecoveryNotice(destination: Destination?) {
        let location = destination.map { "Recovery will retry: \($0.title)." } ?? "Recovery will retry the staged capture."
        let warning = Toast(style: .warning, title: "Couldn't save the previous capture", subtitle: location)
        onToast?(warning)
        if presentsUI, !isTerminating { toast.show(warning) }
    }

    private func reportExternalRegistryProblem(_ error: Error, forSave: Bool) {
        let key: String
        if let registryError = error as? ExternalNoteRegistryError {
            key = String(reflecting: registryError)
        } else {
            key = AppErrorLog.summary(error)
        }
        if !forSave, !reportedExternalRegistryWarnings.insert(key).inserted { return }

        let title = forSave ? "Couldn't save external note" : "External notes unavailable"
        let subtitle: String
        if let registryError = error as? ExternalNoteRegistryError {
            switch registryError {
            case .malformedRegistry:
                subtitle = forSave
                    ? "The registry is damaged. Its existing entries were preserved; this note was not saved."
                    : "The registry is damaged. Existing entries were preserved; external saves are paused. Vault notes still work."
            case .unsupportedVersion(let version):
                subtitle = forSave
                    ? "The registry uses version \(version). Its entries were preserved; this note was not saved."
                    : "The registry uses version \(version). Existing entries were preserved; update this app. Vault notes still work."
            case .unreadableRegistry:
                subtitle = forSave
                    ? "The registry could not be read safely. Its entries were preserved; this note was not saved."
                    : "The registry could not be read safely. Existing entries were preserved; external notes are unavailable. Vault notes still work."
            }
        } else {
            subtitle = forSave
                ? "The registry could not be read; its contents were left unchanged and this note was not saved."
                : "The registry could not be read. External notes are unavailable; vault notes still work."
        }
        logger.error("\(title, privacy: .public) (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
        showToast(Toast(style: .warning, title: title, subtitle: subtitle))
    }

    private func installStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = status
        status.button?.toolTip = AppInfo.name
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("Capture Selection", hotkey: .captureSelection, action: #selector(menuCaptureSelection)))
        menu.addItem(menuItem("Capture Area", hotkey: .captureRegion, action: #selector(menuCaptureRegion)))
        menu.addItem(menuItem("Capture Selection Outside Session…", hotkey: .captureSelectionOutsideSession, action: #selector(menuCaptureSelectionOutsideSession)))
        menu.addItem(menuItem("Capture Area Outside Session…", hotkey: .captureRegionOutsideSession, action: #selector(menuCaptureRegionOutsideSession)))
        menu.addItem(menuItem("Search Notes…", hotkey: .search, action: #selector(menuSearch)))
        let session = menuItem("Start Session…", hotkey: .toggleSession, action: #selector(menuSession))
        sessionItem = session
        menu.addItem(session)
        menu.addItem(menuItem("Quick-note", hotkey: .writeNote, action: #selector(menuWriteNote)))
        menu.addItem(menuItem("Quick-note Outside Session", hotkey: .writeNoteOutsideSession, action: #selector(menuWriteNoteOutsideSession)))
        menu.addItem(menuItem("Add Subheading…", hotkey: .addSubheading, action: #selector(menuSubheading)))
        menu.addItem(menuItem("Folder Shortcuts…", action: #selector(menuFolderShortcuts)))
        let folders = NSMenuItem(title: "Use Folder Shortcut", action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.delegate = self
        folderShortcutsMenu = folderMenu
        folders.submenu = folderMenu
        menu.addItem(folders)
        rebuildFolderShortcutsMenu()
        let shortcuts = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        shortcuts.isEnabled = false
        shortcutStatusItem = shortcuts
        menu.addItem(shortcuts)
        let retry = menuItem("Retry Shortcuts", action: #selector(menuRetryShortcuts))
        retry.toolTip = "Release conflicting shortcuts in other apps, then retry. Menu commands remain available."
        retryShortcutsItem = retry
        menu.addItem(retry)
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Notes Folder", hotkey: .openLibrary, action: #selector(menuOpenFolder)))
        menu.addItem(menuItem("Choose Notes Folder…", action: #selector(menuChooseFolder)))
        let models = SemanticModelsMenu(
            semantic: pipeline.semantic, target: self,
            download: #selector(menuSemanticModels), remove: #selector(menuRemoveSemanticModels),
            changed: { [weak self] in self?.refreshStatus() },
            failed: { [weak self] error, title in self?.report(error, title: title) },
            succeeded: { [weak self] in self?.showToast(Toast(style: .success, title: "Semantic search is ready")) })
        semanticModels = models
        menu.addItem(models.item)
        let permissions = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        let accessibility = menuItem("Accessibility", action: #selector(menuAccessibility))
        let screen = menuItem("Screen Recording", action: #selector(menuScreenRecording))
        accessibilityItem = accessibility
        screenRecordingItem = screen
        submenu.addItem(accessibility)
        submenu.addItem(screen)
        permissions.submenu = submenu
        menu.addItem(permissions)
        let updater = AppUpdater()
        appUpdater = updater
        if let updateItem = updater.menuItem { menu.addItem(updateItem) }
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit \(AppInfo.name)", action: #selector(menuQuit)))
        status.menu = menu
        refreshStatus()
    }

    private func menuItem(_ title: String, hotkey: Hotkey? = nil, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let hotkey {
            shortcutItems.append((item, hotkey))
            setMenuTitle(item, title: title, hotkey: hotkey)
        }
        return item
    }

    /// Shown natively in the menu's shortcut column. The Carbon hotkey consumes the keystroke system-wide, so the menu never handles it a second time.
    private func setMenuTitle(_ item: NSMenuItem, title: String, hotkey: Hotkey) {
        Self.configureShortcut(item, title: title, hotkey: hotkey, failure: hotkeyFailures[hotkey])
    }

    static func configureShortcut(_ item: NSMenuItem, title: String, hotkey: Hotkey, failure: HotkeyError?) {
        item.attributedTitle = nil
        item.title = title
        if let failure {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            let reason = failure == .conflict ? "Another app uses this shortcut." : "macOS could not register this shortcut."
            item.toolTip = "\(hotkey.displayString) unavailable. \(reason) Use this menu command, then choose Retry Shortcuts."
            return
        }
        item.toolTip = nil
        item.keyEquivalent = hotkey.menuKeyEquivalent
        var mask: NSEvent.ModifierFlags = []
        if hotkey.modifiers.contains(.control) { mask.insert(.control) }
        if hotkey.modifiers.contains(.option) { mask.insert(.option) }
        if hotkey.modifiers.contains(.shift) { mask.insert(.shift) }
        if hotkey.modifiers.contains(.command) { mask.insert(.command) }
        item.keyEquivalentModifierMask = mask
    }

    private func refreshShortcutStatus() {
        for entry in shortcutItems { setMenuTitle(entry.item, title: entry.item.title, hotkey: entry.hotkey) }
        for item in folderShortcutsMenu?.items ?? [] {
            guard let id = item.representedObject as? UUID,
                  let binding = folderShortcuts.first(where: { $0.id == id }) else { continue }
            setMenuTitle(item, title: item.title, hotkey: binding.hotkey)
        }
        shortcutStatusItem?.title = hotkeyFailures.count == 1 ? "1 keyboard shortcut unavailable" : "\(hotkeyFailures.count) keyboard shortcuts unavailable"
        shortcutStatusItem?.isHidden = hotkeyFailures.isEmpty
        retryShortcutsItem?.isHidden = hotkeyFailures.isEmpty
    }

    private func rebuildFolderShortcutsMenu() {
        guard let menu = folderShortcutsMenu else { return }
        menu.removeAllItems()
        for binding in folderShortcuts {
            let folder = binding.action == .startSession ? "Sessions/\(binding.folder)" : binding.folder
            let item = menuItem("\(binding.action.title) → \(folder)", action: #selector(menuUseFolderShortcut(_:)))
            item.representedObject = binding.id
            setMenuTitle(item, title: item.title, hotkey: binding.hotkey)
            menu.addItem(item)
        }
        if folderShortcuts.isEmpty {
            let empty = NSMenuItem(title: "Add bindings in Folder Shortcuts…", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }

    private func refreshStatus() {
        // Bundled template icons; the SF Symbol fallback covers unbundled `swift run` builds.
        let resource = activeSession == nil ? "MenuBarIcon" : "MenuBarIcon-active"
        let symbol = activeSession == nil ? "tray.and.arrow.down" : "tray.and.arrow.down.fill"
        let image = Bundle.main.url(forResource: resource, withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        image?.accessibilityDescription = AppInfo.name
        statusItem?.button?.image = image
        if let sessionItem {
            setMenuTitle(sessionItem, title: activeSession.map { "End Session “\($0.name)”" } ?? "Start Session…", hotkey: .toggleSession)
        }
        refreshShortcutStatus()
        let axGranted = CapturePermissions.accessibilityTrusted
        accessibilityItem?.title = axGranted ? "Accessibility" : "Accessibility…"
        accessibilityItem?.state = axGranted ? .on : .off
        let screenGranted = CapturePermissions.screenCaptureAllowed
        screenRecordingItem?.title = screenGranted ? "Screen Recording" : "Screen Recording…"
        screenRecordingItem?.state = screenGranted ? .on : .off
        let semantic = pipeline.semantic
        let enabled = SemanticIndexer.modelsInstalled(in: semantic.modelsDirectory)
        semanticModels?.refresh(installed: enabled)
        Task.detached(priority: .utility) { await semantic.setEnabled(enabled) }
        if enabled, !isTerminating, powerMonitor == nil {
            powerMonitor = PowerMonitor { Task { await semantic.schedule() } }
        } else if !enabled {
            powerMonitor?.stop()
            powerMonitor = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshStatus() }
    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem?.menu { menuTracking = true }
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menuTracking = false
        if let action = menuAction {
            menuAction = nil
            DispatchQueue.main.async(execute: action)
        }
    }

    private func afterMenu(_ action: @escaping @MainActor () -> Void) {
        if menuTracking { menuAction = action }
        else { DispatchQueue.main.async(execute: action) }
    }

    @objc private func menuCaptureSelection() {
        guard !isTerminating, !acquisitionInProgress else { return }
        let context = FrontmostContext.capture()
        afterMenu { [weak self] in self?.capture(.selection, fromHotkey: false, context: context) }
    }
    @objc private func menuCaptureRegion() {
        guard !isTerminating, !acquisitionInProgress else { return }
        let context = FrontmostContext.capture()
        afterMenu { [weak self] in self?.capture(.region, fromHotkey: false, context: context) }
    }
    @objc private func menuCaptureSelectionOutsideSession() {
        guard !isTerminating, !acquisitionInProgress else { return }
        let context = FrontmostContext.capture()
        afterMenu { [weak self] in self?.capture(.selection, outsideSession: true, fromHotkey: false, context: context) }
    }
    @objc private func menuCaptureRegionOutsideSession() {
        guard !isTerminating, !acquisitionInProgress else { return }
        let context = FrontmostContext.capture()
        afterMenu { [weak self] in self?.capture(.region, outsideSession: true, fromHotkey: false, context: context) }
    }
    @objc private func menuSearch() { afterMenu { [weak self] in self?.openSearch() } }
    @objc private func menuWriteNote() { afterMenu { [weak self] in self?.openNoteEditor() } }
    @objc private func menuWriteNoteOutsideSession() { afterMenu { [weak self] in self?.openNoteEditor(outsideSession: true) } }
    @objc private func menuFolderShortcuts() { afterMenu { [weak self] in self?.openFolderShortcuts() } }
    @objc private func menuUseFolderShortcut(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID,
              let binding = folderShortcuts.first(where: { $0.id == id }) else { return }
        afterMenu { [weak self] in self?.runFolderShortcut(binding) }
    }
    @objc private func menuSubheading() { afterMenu { [weak self] in self?.openSubheading() } }
    @objc private func menuRetryShortcuts() { afterMenu { [weak self] in self?.registerHotkeys() } }
    @objc private func menuSession() { afterMenu { [weak self] in self?.toggleSession() } }
    @objc private func menuOpenFolder() { afterMenu { [weak self] in self?.openNotesFolder() } }
    @objc private func menuChooseFolder() { afterMenu { [weak self] in self?.chooseNotesFolder() } }
    @objc private func menuSemanticModels() { afterMenu { [weak self] in self?.semanticModels?.activate() } }
    @objc private func menuRemoveSemanticModels() { afterMenu { [weak self] in self?.semanticModels?.confirmRemove() } }
    @objc private func menuAccessibility() {
        afterMenu { [weak self] in self?.handlePermissionMenu(.accessibility) }
    }
    @objc private func menuScreenRecording() {
        afterMenu { [weak self] in self?.handlePermissionMenu(.screenCapture) }
    }

    /// Not granted: the guide walks the user through it. Granted: open the pane only, so the user can revoke.
    private func handlePermissionMenu(_ permission: CapturePermission) {
        let granted = permission == .accessibility ? CapturePermissions.accessibilityTrusted : CapturePermissions.screenCaptureAllowed
        if granted {
            CapturePermissions.openSettings(for: permission)
        } else {
            permissionGuide.show(for: permission)
        }
    }
    /// A run-loop perform, not a main-queue block: terminate's terminate-later wait must leave the main queue free for the shutdown tasks.
    @objc private func menuQuit() { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
    private func openNotesFolder() { NSWorkspace.shared.open(pipeline.vault.root) }

    private func chooseNotesFolder() {
        guard !isTerminating, let selected = NotesFolder.choose(current: NotesFolder.configuredRoot()) else { return }
        guard selected != pipeline.vault.root.standardizedFileURL.resolvingSymlinksInPath() else {
            showToast(Toast(style: .success, title: "Notes folder saved", subtitle: selected.path))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Restart to use the new notes folder"
        alert.informativeText = "\(selected.path) will be used after restart. Until then, captures continue in the current folder. Existing notes stay in place."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { onRelaunchRequested?() }
    }
}
