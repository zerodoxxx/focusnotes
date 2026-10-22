import CaptureKit
import Core
import Foundation
import os

enum CaptureTrigger: Sendable {
    case selection, region

    var hotkey: Hotkey { self == .selection ? .captureSelection : .captureRegion }
}

struct PendingCapture: Sendable {
    enum Content: Sendable {
        case text(String)
        case image(png: Data, ocr: String?)
    }

    let id: UUID
    let createdAt: Date
    let trigger: CaptureTrigger
    let content: Content
    let source: CaptureSource
    let subtitle: String
    let deferredOCR: Task<OCRResult?, Never>?

    init(id: UUID = UUID(), createdAt: Date = Date(), trigger: CaptureTrigger, content: Content,
         source: CaptureSource, subtitle: String, deferredOCR: Task<OCRResult?, Never>? = nil) {
        self.id = id; self.createdAt = createdAt; self.trigger = trigger
        self.content = content; self.source = source; self.subtitle = subtitle; self.deferredOCR = deferredOCR
    }
}

struct CapturePipeline: Sendable {
    let vault: Vault
    let sessions: SessionStore
    let service: CaptureService
    let index: SearchIndex
    let semantic: SemanticIndexer
    let monitor: VaultMonitor
    let journal: CaptureJournal
    let drafts: NoteDraftStore
    let pins: NotePinStore
    let calendar: Calendar
    let logger: Logger
    private let noteIDForPin: (@Sendable (URL) throws -> String)?

    init(vault: Vault, sessions: SessionStore, service: CaptureService, index: SearchIndex,
         semantic: SemanticIndexer, monitor: VaultMonitor, journal: CaptureJournal,
         drafts: NoteDraftStore, pins: NotePinStore, calendar: Calendar, logger: Logger,
         noteIDForPin: (@Sendable (URL) throws -> String)? = nil) {
        self.vault = vault
        self.sessions = sessions
        self.service = service
        self.index = index
        self.semantic = semantic
        self.monitor = monitor
        self.journal = journal
        self.drafts = drafts
        self.pins = pins
        self.calendar = calendar
        self.logger = logger
        self.noteIDForPin = noteIDForPin
    }

    @concurrent
    static func open(vaultRoot: URL, stateDirectory: URL, calendar: Calendar, modelsDirectory: URL? = nil) async throws -> Self {
        let vault = Vault(root: vaultRoot,
                          externalNoteRegistryURL: stateDirectory.appendingPathComponent("external-notes.json"))
        try vault.prepare()
        let index = try SearchIndex(vault: vault, databaseURL: stateDirectory.appendingPathComponent("index.sqlite"), calendar: calendar)
        let semantic = SemanticIndexer(index: index, vault: vault, stateDirectory: stateDirectory,
                                       modelsDirectory: modelsDirectory ?? stateDirectory.appendingPathComponent("models", isDirectory: true))
        let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "pipeline")
        let monitor = VaultMonitor(vault: vault) { request in
            if request.notes { await Self.syncIndex(index: index, semantic: semantic, logger: logger) }
            if request.assets, !Task.isCancelled {
                await Self.backfillAssets(vault: vault, index: index, semantic: semantic,
                                          recheckingAssetPaths: request.recheckingAssetPaths, logger: logger)
            }
        }
        let sessions = SessionStore(stateDirectory: stateDirectory, vault: vault, calendar: calendar, now: Date.init)
        let writer = NoteWriter(vault: vault, calendar: calendar)
        let pipeline = Self(
            vault: vault, sessions: sessions,
            service: CaptureService(vault: vault, sessions: sessions, writer: writer, now: Date.init),
            index: index,
            semantic: semantic, monitor: monitor,
            journal: CaptureJournal(stateDirectory: stateDirectory),
            drafts: NoteDraftStore(stateDirectory: stateDirectory),
            pins: NotePinStore(stateDirectory: stateDirectory),
            calendar: calendar, logger: logger
        )
        try await pipeline.recoverSessionRename(allowFileRename: true)
        try await pipeline.journal.discardPreviousProcessRedirects()
        return pipeline
    }

    func prepare(_ capture: PendingCapture, noteTitle: String?, destination: Destination? = nil) async throws -> CaptureJob {
        try await recoverSessionIdentity()
        let content: CaptureContent
        let png: Data?
        let ocr: String?
        switch capture.content {
        case .text(let text):
            content = .text(text); png = nil; ocr = nil
        case .image(let data, let text):
            let formatter = DateFormatter()
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            content = .image(assetPath: "assets/\(formatter.string(from: capture.createdAt))-\(capture.id.uuidString.lowercased()).png")
            png = data; ocr = text
        }
        let value = Capture(id: capture.id, createdAt: capture.createdAt, content: content, source: capture.source)
        let prepared: PreparedCapture
        if let destination { prepared = PreparedCapture(capture: value, destination: destination) }
        else { prepared = try await service.prepare(value, noteTitle: noteTitle) }
        return CaptureJob(prepared: prepared, png: png, ocr: ocr, deferredOCR: capture.deferredOCR)
    }

    func prepareNote(_ capture: Capture, destination: Destination?, newNote: Bool, outsideSession: Bool = false) async throws -> PreparedCapture {
        try await recoverSessionIdentity()
        return try await service.prepareNote(capture, destination: destination, newNote: newNote, outsideSession: outsideSession, calendar: calendar)
    }

    func prepareCapture(_ capture: Capture, destination: Destination?) async throws -> PreparedCapture {
        try await recoverSessionIdentity()
        if let destination { return PreparedCapture(capture: capture, destination: destination) }
        return try await service.prepare(capture, noteTitle: nil)
    }

    func recoverSessionIdentity() async throws {
        try await recoverSessionRename(allowFileRename: false)
    }

    func commit(_ originalJob: CaptureJob, pinOnSave: Bool? = nil,
                onNoteSaved: (@MainActor @Sendable (SavedCapture, Bool) -> Void)? = nil) async throws -> SavedCapture {
        try await recoverSessionRename(allowFileRename: false)
        let job = try await journal.redirected(originalJob)
        let saved = try await service.save(job.prepared, png: job.png)
        monitor.refreshExternalRoots()
        // A cache failure must not retry an already appended capture. Startup sync repairs it.
        do {
            try await index.reindex(note: saved.destination.url)
            if let text = job.ocr, let png = job.png,
               let asset = try await index.capture(id: saved.captureID)?.assetPath {
                try await index.setImageText(assetPath: asset, text: text, fingerprint: SearchIndex.imageFingerprint(png))
            }
        } catch {
            logger.error("Capture saved; index update failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
        }
        if let deferred = job.deferredOCR, let png = job.png, case .image(let asset) = job.prepared.capture.content {
            Task.detached(priority: .utility) {
                guard let result = await deferred.value else { return } // Missing text remains eligible for backfill.
                do {
                    try await index.setImageText(assetPath: asset, text: result.text, fingerprint: SearchIndex.imageFingerprint(png))
                    await semantic.schedule()
                } catch { logger.error("Deferred OCR cache update failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)") }
            }
        }
        let pinFailed = try completeNoteSave(job, saved: saved, pinOnSave: pinOnSave)
        try await journal.remove(id: saved.captureID)
        Task.detached(priority: .utility) { await semantic.schedule() }
        if let pinFailed { await onNoteSaved?(saved, pinFailed) }
        return saved
    }

    /// Called only after the controller drains capture writes. The durable
    /// intent survives a crash between the file operation and identity updates.
    func renameSession(_ candidate: SessionCandidate, to name: String,
                       preparedJobs: [CaptureJob],
                       beforeInstall: (@Sendable (SessionRenameStage) throws -> Void)? = nil,
                       afterSwap: (@Sendable () throws -> Void)? = nil) async throws -> SessionRenameOutcome {
        try await recoverSessionRename(allowFileRename: true)
        let renamed = try await sessions.renameDestination(candidate, to: name)
        let intent = try await journal.beginSessionRename(oldPath: candidate.notePath, session: renamed,
                                                         vault: vault, preparedJobs: preparedJobs)
        let recorder = await journal.installationRecorder(for: intent)
        do {
            _ = try await sessions.rename(candidate, to: name, beforeInstall: { stage in
                try recorder(stage)
                try beforeInstall?(stage)
            }, afterSwap: afterSwap)
        }
        catch {
            let renameError = error
            do {
                if let recorded = try await journal.pendingSessionRename(),
                   try vault.fileSnapshot(relativePath: renamed.notePath, includingContents: false).map(recorded.isInstalled) != true {
                    if let source = try vault.fileSnapshot(relativePath: recorded.oldPath, includingContents: false),
                       recorded.isInstalled(source) {
                        if try await recoverSessionRename(allowFileRename: true) {
                            logger.error("Session rename completed after interrupted swap (\(AppErrorLog.summary(renameError), privacy: .public))")
                            return SessionRenameOutcome(session: renamed, identityUpdatePending: false)
                        }
                    } else {
                        try await abandonSessionRename(recorded, error: renameError)
                    }
                }
            } catch {
                logger.error("Rename cleanup failed after \(AppErrorLog.summary(renameError), privacy: .public): \(AppErrorLog.summary(error), privacy: .public)")
            }
            // Persistence can fail after the file has committed. Detect that
            // outcome by the staged inode recorded before installation.
            guard let recorded = try? await journal.pendingSessionRename(),
                  let target = try? vault.fileSnapshot(relativePath: renamed.notePath, includingContents: false),
                  recorded.isInstalled(target) else { throw renameError }
            // The file is installed; report success and let recovery finish identity updates.
            do {
                try await recoverSessionRename(allowFileRename: false)
                return SessionRenameOutcome(session: renamed, identityUpdatePending: false)
            } catch {
                logger.error("Session renamed; identity update pending (\(AppErrorLog.summary(renameError), privacy: .public); \(AppErrorLog.summary(error), privacy: .public))")
                return SessionRenameOutcome(session: renamed, identityUpdatePending: true)
            }
        }
        do {
            try await recoverSessionRename(allowFileRename: false)
            return SessionRenameOutcome(session: renamed, identityUpdatePending: false)
        } catch {
            logger.error("Session renamed; identity update pending (\(AppErrorLog.summary(error), privacy: .public))")
            return SessionRenameOutcome(session: renamed, identityUpdatePending: true)
        }
    }

    /// Returns true only when a pending rename completed its identity migration.
    @discardableResult
    private func recoverSessionRename(allowFileRename: Bool) async throws -> Bool {
        guard var intent = try await journal.pendingSessionRename() else { return false }
        if allowFileRename {
            // Startup must never stay blocked on the file step: any failure before
            // the target holds the installed identity abandons, leaving files as they are.
            do { intent = try await resumeSessionRename(intent) }
            catch {
                // Abandon the latest intent so stages recorded during the resume are cleaned up too.
                try await abandonSessionRename((try? await journal.pendingSessionRename()) ?? intent, error: error)
                return false
            }
        } else {
            let target = try vault.fileSnapshot(relativePath: intent.session.notePath, includingContents: false)
            if target.map(intent.isInstalled) != true {
                // Startup finishes the app's own staged swap; anything else is a stale request.
                if let source = try vault.fileSnapshot(relativePath: intent.oldPath), intent.isInstalled(source) {
                    throw SessionRenameRecoveryError.changedFile
                }
                try await abandonSessionRename(intent, error: SessionRenameRecoveryError.changedFile)
                return false
            }
        }
        try await sessions.recoverRenamedSession(intent.session)
        try await journal.finishSessionRename(intent, vault: vault)
        try pins.rename(from: intent.oldPath, to: intent.session.notePath)
        try await cleanupSessionRename(intent, completed: true)
        try await journal.clearSessionRename()
        do {
            _ = try await index.sync()
            await semantic.schedule()
        } catch {
            logger.error("Session renamed; index update failed (\(AppErrorLog.summary(error), privacy: .public))")
        }
        return true
    }

    /// Returns the intent whose installed identity is at the target. Throws only
    /// while the target does not hold that identity.
    private func resumeSessionRename(_ intent: CaptureJournal.SessionRenameIntent) async throws -> CaptureJournal.SessionRenameIntent {
        let target = try vault.fileSnapshot(relativePath: intent.session.notePath, includingContents: false)
        if target.map(intent.isInstalled) == true { return intent }
        let source = try vault.fileSnapshot(relativePath: intent.oldPath)
        guard let source, intent.isOriginal(source) || intent.isInstalled(source) else {
            throw SessionRenameRecoveryError.changedFile
        }
        let candidate = SessionCandidate(name: intent.session.name, notePath: intent.oldPath, modifiedAt: source.modifiedAt)
        let recorder = await journal.installationRecorder(for: intent)
        do { _ = try await sessions.rename(candidate, to: intent.session.name, beforeInstall: recorder) }
        catch {
            // State persistence can fail after installation; keep that committed file.
            guard let recorded = try await journal.pendingSessionRename(),
                  let installed = try vault.fileSnapshot(relativePath: recorded.session.notePath, includingContents: false),
                  recorded.isInstalled(installed) else { throw error }
            return recorded
        }
        guard let recorded = try await journal.pendingSessionRename() else { throw SessionRenameRecoveryError.changedFile }
        return recorded
    }

    private func abandonSessionRename(_ intent: CaptureJournal.SessionRenameIntent, error: any Error) async throws {
        logger.error("Session rename abandoned; preserving note files (\(AppErrorLog.summary(error), privacy: .public))")
        try await cleanupSessionRename(intent)
        try await journal.clearSessionRename()
    }

    private func cleanupSessionRename(_ intent: CaptureJournal.SessionRenameIntent, completed: Bool = false) async throws {
        for stage in intent.previousInstallations + (intent.installation.map { [$0] } ?? []) {
            let parent = (intent.session.notePath as NSString).deletingLastPathComponent
            let path = parent + "/" + stage.temporaryName
            do {
                guard let temporary = try vault.fileSnapshot(relativePath: path, includingContents: false) else { continue }
                let source = try vault.fileSnapshot(relativePath: intent.oldPath, includingContents: false)
                if !completed {
                    // Abandoning may only discard an unswapped staged copy whose original is
                    // still at the old name. Any swapped-out original may hold user edits.
                    guard ManagedFileIdentity(temporary) == stage.installed,
                          source.map(ManagedFileIdentity.init) == stage.original else {
                        logger.error("Session rename temporary retained at \(path, privacy: .private)")
                        continue
                    }
                } else if stage.original == intent.source,
                          source.map(ManagedFileIdentity.init) != intent.source {
                    // Only a confirmed completed install may discard its original backup.
                    let target = try vault.fileSnapshot(relativePath: intent.session.notePath, includingContents: false)
                    guard target.map(intent.isInstalled) == true else {
                        logger.error("Session rename temporary retained at \(path, privacy: .private); original identity absent from old path")
                        continue
                    }
                }
                try await sessions.cleanupRenameTemporary(stage, in: intent.session)
            }
            catch {
                // Cleanup must not block captures or remove an uncertain file.
                logger.error("Session temporary retained at \(path, privacy: .private) (\(AppErrorLog.summary(error), privacy: .public))")
            }
        }
    }

    /// Shared by interactive commits, shutdown retry and startup replay. Keep the
    /// journal identity until pin handling and matching-draft cleanup have completed.
    private func completeNoteSave(_ job: CaptureJob, saved: SavedCapture, pinOnSave: Bool?) throws -> Bool? {
        guard case .note(let text) = job.prepared.capture.content else { return nil }
        var pinFailed = false
        try drafts.completeSave(matching: job.noteDraft ?? text, pinOnSave: pinOnSave) { intent in
            guard intent else { return }
            let noteID: String
            do { noteID = try (noteIDForPin ?? { try vault.noteID(for: $0) })(saved.destination.url) }
            catch {
                pinFailed = true
                logger.error("Couldn't resolve note to pin (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
                return
            }
            do { try pins.set(noteID, pinned: true) }
            catch {
                pinFailed = true
                logger.error("Couldn't pin note (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
            }
        }
        return pinFailed
    }

    @discardableResult
    func replayUnsaved(onNoteSaved: (@MainActor @Sendable (SavedCapture, Bool) -> Void)? = nil) async -> Int {
        var restored = 0
        do {
            for url in try await journal.recordURLs() {
                do {
                    let job = try await journal.load(record: url)
                    // A missing image may have been recovered as OCR text. Persist that
                    // exact block before appending, including if cleanup later fails.
                    try await journal.store(job)
                    _ = try await commit(job, onNoteSaved: onNoteSaved)
                    restored += 1
                } catch {
                    logger.error("Journal replay failed for \(url.lastPathComponent, privacy: .private) (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
                    if error is CaptureJournal.RecordError {
                        do { try await journal.quarantine(record: url) }
                        catch { logger.error("Journal quarantine failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)") }
                    }
                }
            }
        } catch { logger.error("Journal read failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)") }
        logger.notice("Journal replay: restored=\(restored)")
        return restored
    }

    func sync() async { await monitor.sync() }

    private static func syncIndex(index: SearchIndex, semantic: SemanticIndexer, logger: Logger) async {
        guard !Task.isCancelled else { return }
        do {
            let stats = try await index.sync()
            logger.notice("Index sync: added=\(stats.added) updated=\(stats.updated) removed=\(stats.removed) unchanged=\(stats.unchanged)")
            await semantic.schedule()
        } catch {
            logger.error("Index sync failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
        }
    }

    func backfill() async { await monitor.backfill() }

    private static func backfillAssets(vault: Vault, index: SearchIndex, semantic: SemanticIndexer,
                                      recheckingAssetPaths: Set<String>?, logger: Logger) async {
        do {
            for path in try await index.assetsMissingText(recheckingAssetPaths: recheckingAssetPaths) {
                guard !Task.isCancelled else { return }
                do {
                    let data = try assetData(path, vault: vault)
                    let fingerprint = SearchIndex.imageFingerprint(data)
                    let result = try await OCR.recognize(pngData: data)
                    guard !Task.isCancelled else { return }
                    try await index.setImageText(assetPath: path, text: result.text, fingerprint: fingerprint)
                } catch {
                    logger.error("OCR backfill failed for \(path, privacy: .private) (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
                }
            }
            await semantic.schedule()
        } catch {
            logger.error("OCR backfill list failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
        }
    }

    @concurrent
    func assetData(_ path: String) async throws -> Data {
        try Self.assetData(path, vault: vault)
    }

    func assetURL(_ path: String) throws -> URL {
        try Self.assetURL(path, vault: vault)
    }

    private static func assetData(_ path: String, vault: Vault) throws -> Data {
        guard let snapshot = try vault.fileSnapshot(relativePath: path), let contents = snapshot.contents else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return contents
    }

    private static func assetURL(_ path: String, vault: Vault) throws -> URL {
        let url = vault.root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), url.path.hasPrefix(vault.root.path + "/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return url
    }

    @concurrent
    func region(png: Data, context: FrontmostContext, id: UUID = UUID(), createdAt: Date = Date(),
                recognize: @escaping @Sendable (Data) async throws -> OCRResult = { try await OCR.recognize(pngData: $0) }) async -> PendingCapture {
        let race = OCRBudgetRace()
        let recognition = Task.detached(priority: .userInitiated) { () -> OCRResult? in
            do { return try await recognize(png) }
            catch {
                logger.error("OCR failed; retaining image (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
                return nil
            }
        }
        Task { await race.resolve(.finished(await recognition.value)) }
        let timer = Task {
            do { try await Task.sleep(for: .milliseconds(1500)); await race.resolve(.expired) }
            catch {} // An on-time result cancels the one-shot deadline.
        }
        let outcome = await race.wait()
        timer.cancel()
        guard case .finished(let recognized) = outcome else {
            return PendingCapture(id: id, createdAt: createdAt, trigger: .region, content: .image(png: png, ocr: nil),
                                  source: Self.source(context), subtitle: "Image", deferredOCR: recognition)
        }
        let result = recognized ?? OCRResult(text: "", lines: [], imageSize: .zero)
        let classification = CaptureClassifier.classify(result)
        logger.notice("Region classifier: decision=\(classification.decision.rawValue, privacy: .public) coverage=\(classification.metrics.textCoverage) confidence=\(classification.metrics.meanConfidence) lines=\(classification.metrics.lineCount)")
        let preview = Self.firstLine(result.text)
        return PendingCapture(
            id: id, createdAt: createdAt,
            trigger: .region,
            content: classification.decision == .text ? .text(result.text) : .image(png: png, ocr: recognized?.text),
            source: Self.source(context),
            subtitle: classification.decision == .text ? "Text · \(preview)" : (preview.isEmpty ? "Image" : "Image · \(preview)")
        )
    }

    static func selection(text: String, context: FrontmostContext) -> PendingCapture {
        PendingCapture(trigger: .selection, content: .text(text), source: source(context), subtitle: firstLine(text))
    }

    static func source(_ context: FrontmostContext) -> CaptureSource {
        CaptureSource(appName: context.appName, windowTitle: context.windowTitle)
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 100 ? String(line.prefix(99)) + "…" : line
    }
}

enum SessionRenameRecoveryError: Error {
    case changedFile
}

/// An unstructured race returns at the deadline without waiting for Vision to stop.
private actor OCRBudgetRace {
    enum Outcome: Sendable { case finished(OCRResult?), expired }
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?
    func resolve(_ value: Outcome) {
        guard outcome == nil else { return }
        outcome = value
        continuation?.resume(returning: value)
        continuation = nil
    }
    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }
}
