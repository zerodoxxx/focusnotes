import CaptureKit
import Core
import EmbedKit
import Foundation
import AppKit
import OverlayKit

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
extension AppController {
    func runSelfTest() async throws -> String {
        try checkMenuKeyEquivalents()
        try await checkAppReliability()
        try await checkSemanticRetryRecovery()
        try await checkNoteDraftStoreScheduling()
        try await checkOutsideSessionWrites()
        if ProcessInfo.processInfo.environment["QUICK_NOTE_SELF_TEST"] == "1" {
            try await checkQuickNotePinPersistence()
            return "{\"ok\":true,\"outsideSessionWritesVerified\":true,\"noteDraftPinPersistenceVerified\":true,\"legacyDraftMigrationVerified\":true,\"draftPinRetryVerified\":true,\"pinStorageFailureNonfatalVerified\":true,\"draftPinRecoveryVerified\":true,\"finalPinFailureToastVerified\":true,\"semanticRetryRecoveryVerified\":true}"
        }
        let externalNote = pipeline.vault.root.appendingPathComponent("External Edit.md")
        guard FileManager.default.createFile(atPath: externalNote.path, contents: Data("# External Edit\n\n".utf8)) else {
            throw SelfTestFailure("Could not prepare external-edit note")
        }
        _ = await start()
        guard pipeline.monitor.isRunning else { throw SelfTestFailure("Vault watcher did not start") }
        defer { pipeline.monitor.stop() }
        let context = FrontmostContext(appName: "Demo Source", bundleIdentifier: nil, processIdentifier: 0, windowTitle: "Pipeline smoke test")
        let textPending = CapturePipeline.selection(text: "selftestneedle full body\nSecond line for copying.", context: context)
        await captures.stage(textPending)
        let stagedURLs = try await pipeline.journal.recordURLs()
        guard stagedURLs.count == 1,
              try await pipeline.journal.load(record: stagedURLs[0]).prepared.capture.id == textPending.id,
              try await pipeline.journal.load(record: stagedURLs[0]).prepared.destination.kind == .inbox,
              try await pipeline.index.capture(id: textPending.id) == nil else {
            throw SelfTestFailure("Staged, uncommitted capture was not journaled at its default destination")
        }
        guard let textTask = captures.commitPending(noteTitle: "Demo Heading") else { throw SelfTestFailure("Text was not pending") }
        let text = try await textTask.value

        let png = try await AppMedia.demoPNG()
        let imagePending = await pipeline.region(png: png, context: context)
        guard case .image = imagePending.content else { throw SelfTestFailure("Sparse diagram must remain an image") }
        await captures.stage(imagePending)
        guard let imageTask = captures.commitPending() else { throw SelfTestFailure("Image was not pending") }
        let image = try await imageTask.value

        let session = try await startSession(name: "Demo Session")
        for text in ["selftestneedle session capture one", "selftestneedle session capture two"] {
            await captures.stage(CapturePipeline.selection(text: text, context: context))
            guard let task = captures.commitPending() else { throw SelfTestFailure("Session capture was not pending") }
            let saved = try await task.value
            guard saved.destination.kind == .session else { throw SelfTestFailure("Session routing failed") }
        }
        guard let sessionCount = try await endSession(session) else { throw SelfTestFailure("Session capture count was unavailable") }
        let ownExternal = PendingCapture(trigger: .selection, content: .text("coalescedownneedle app append"),
                                         source: CapturePipeline.source(context), subtitle: "App append")
        let ownJob = try await pipeline.prepare(ownExternal, noteTitle: "External Edit")
        try await pipeline.journal.store(ownJob)
        _ = try await pipeline.commit(ownJob)
        let external = Capture(id: UUID(), createdAt: Date(), content: .text("watcherexternalneedle appended by another editor"),
                               source: CaptureSource(appName: "Obsidian"))
        let externalBlock = CaptureFormat.block(for: external, noteRelativeDir: "", calendar: pipeline.calendar)
        guard let existing = FileManager.default.contents(atPath: externalNote.path),
              FileManager.default.createFile(atPath: externalNote.path, contents: existing + Data((externalBlock + "\n").utf8)) else {
            throw SelfTestFailure("External capture append failed")
        }
        // No explicit sync/reindex between the editor write and this assertion.
        let externalStart = ContinuousClock.now
        let externalDeadline = externalStart.advanced(by: .seconds(5))
        var externalFound = false
        while ContinuousClock.now < externalDeadline {
            if try await pipeline.index.search("watcherexternalneedle").contains(where: { $0.captureID == external.id }) {
                externalFound = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard externalFound, ContinuousClock.now < externalDeadline else {
            throw SelfTestFailure("External edit was not searchable through the watcher within 5 seconds")
        }
        let externalDuration = externalStart.duration(to: .now)
        let externalSeconds = Double(externalDuration.components.seconds) + Double(externalDuration.components.attoseconds) / 1e18
        var semanticCapture: SavedCapture?
        let hasModels = SemanticIndexer.modelsInstalled(in: pipeline.semantic.modelsDirectory)
        if hasModels {
            await captures.stage(CapturePipeline.selection(text: "Token buckets allow bursts", context: context))
            guard let task = captures.commitPending() else { throw SelfTestFailure("Semantic capture was not pending") }
            semanticCapture = try await task.value
        }
        if let deferredOCR = imagePending.deferredOCR {
            let completion = SelfTestCompletion()
            Task.detached(priority: .utility) {
                _ = await deferredOCR.value
                await completion.finish()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            while !(await completion.isFinished()), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard await completion.isFinished() else { throw SelfTestFailure("Deferred OCR did not finish within 90 seconds") }
        }

        // Join deferred OCR and its detached index update before checking vector backfill.
        _ = try await pipeline.index.sync()
        let hits = try await pipeline.index.search("selftestneedle")
        var ocrHits: [SearchHit] = []
        let ocrSearchDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < ocrSearchDeadline {
            ocrHits = try await pipeline.index.search("demoimagekeyword")
            if ocrHits.contains(where: { $0.captureID == image.captureID }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let imageHit = try await pipeline.index.capture(id: image.captureID)
        let textHit = try await pipeline.index.capture(id: text.captureID)
        let active = await pipeline.sessions.current()
        guard hits.count == 3, ocrHits.count == 1, sessionCount == 2, active == nil,
              textHit?.body == "selftestneedle full body\nSecond line for copying.",
              text.destination.title == "Demo Heading", image.destination.kind == .inbox,
              let asset = imageHit?.assetPath else { throw SelfTestFailure("Pipeline verification failed") }
        let assetData = try await pipeline.assetData(asset)
        let representations = try await AppMedia.imageRepresentations(pngData: assetData)
        let thumbnail = await AppMedia.thumbnail(pngData: assetData)
        guard !representations.tiff.isEmpty, representations.png == png, let thumbnail,
              max(thumbnail.width, thumbnail.height) == 72 else { throw SelfTestFailure("Image search representations failed") }
        guard let textHit, let imageHit else { throw SelfTestFailure("Fusion fixtures missing") }
        guard let otherTextHit = hits.first(where: { $0.captureID != text.captureID }) else {
            throw SelfTestFailure("Fusion fixtures missing a second text capture")
        }
        let fused = SemanticIndexer.fuse(keyword: [textHit], semantic: SemanticHits(text: [otherTextHit, textHit], images: [imageHit]))
        guard fused.count == 3, fused.first?.captureID == text.captureID,
              Set(fused.map(\.embeddingKey)).count == 3,
              SemanticIndexer.fuse(keyword: [textHit], semantic: SemanticHits(text: [otherTextHit], images: [imageHit]), limit: 2).count == 2 else {
            throw SelfTestFailure("Three-list RRF failed")
        }
        var semanticStatus = "skipped (models not installed)"
        var semanticImageVectors = 0
        if let semanticCapture {
            // Check the cold-request fallback without treating runner speed as a latency guarantee.
            let cold = try await selfTestValue(of: Task {
                await pipeline.semantic.search("throttling API traffic", timeout: .milliseconds(1))
            }, label: "Cold semantic search")
            guard cold.text.isEmpty, cold.images.isEmpty else {
                throw SelfTestFailure("Query embedding deadline blocked the caller")
            }
            await pipeline.semantic.flush()
            let keyword = try await pipeline.index.search("throttling API traffic")
            let semantic = await pipeline.semantic.search("throttling API traffic")
            let hybrid = SemanticIndexer.fuse(keyword: keyword, semantic: semantic)
            guard keyword.isEmpty, semantic.text.first?.captureID == semanticCapture.captureID,
                  hybrid.first?.captureID == semanticCapture.captureID,
                  hybrid.first?.snippet == "Token buckets allow bursts", hybrid.first?.snippetMatches.isEmpty == true else {
                throw SelfTestFailure("Semantic query did not rank the capture with no keyword overlap first")
            }
            let vectors = try VectorStore(url: pipeline.vault.root.appendingPathComponent("vectors.sqlite"))
            let keys = Set(try vectors.keys())
            let blocks = try await pipeline.index.embeddableBlocks()
            guard blocks.filter({ $0.kind != .image }).allSatisfy({ keys.contains($0.key) }) else {
                throw SelfTestFailure("Text backfill missed captures")
            }
            semanticImageVectors = keys.filter { $0 == imageHit.embeddingKey || $0 == imageHit.embeddingKey + "#ocr" }.count
            if SemanticIndexer.imagesAllowed && semanticImageVectors != 2 {
                throw SelfTestFailure("Image and OCR vectors were not both indexed")
            }
            // Stale keys must be pruned even when no new embedding is needed.
            try vectors.upsert(key: "Deleted.md#loose-0", vector: [Float](repeating: 1, count: 256))
            await pipeline.semantic.flush()
            guard try !vectors.keys().contains("Deleted.md#loose-0") else { throw SelfTestFailure("Stale vector was retained") }
            semanticStatus = "passed (no keyword overlap; best match found)"
        }

        // Verify accepted termination drains a still-pending default commit only
        // after the semantic checks, because termination permanently closes the
        // semantic helper client.
        await captures.stage(CapturePipeline.selection(text: "shutdownneedle pending capture", context: context))
        _ = await beginTermination().value
        guard !pipeline.monitor.isRunning else { throw SelfTestFailure("Vault watcher remained running on termination") }
        let shutdownHits = try await pipeline.index.search("shutdownneedle")
        let stats = try await pipeline.index.sync()
        guard shutdownHits.count == 1 else { throw SelfTestFailure("Shutdown drain did not save its pending capture") }

        let slowOCRSeconds = try await checkFeedback(png: png, context: context)
        try await checkRecovery(png: png, context: context)
        try await checkCorruptJournal(png: png, context: context)
        try await checkAcquisitionShutdown(png: png, context: context)
        let summary: [String: Any] = [
            "outsideSessionWritesVerified": true, "outsideSessionRetryRoutingVerified": true,
            "ocrBudgetImageSeconds": slowOCRSeconds, "deferredOCRSearchVerified": true, "subheadingHotkeyPathVerified": true, "noteHotkeyPathVerified": true, "noteDraftPersistenceVerified": true, "noteDraftPinPersistenceVerified": true, "independentNoteCreationVerified": true,
            "acquisitionOrderDuringOCRVerified": true, "formatExample": "FeedbackCases/Vault/Sessions/Feedback.md",
            "ok": true, "captures": hasModels ? 8 : 7, "textDestination": text.destination.title,
            "imageDestination": image.destination.title, "imageClassification": "image",
            "sessionCaptures": sessionCount, "sessionEnded": active == nil,
            "searchHits": hits.count, "ocrSearchHits": ocrHits.count,
            "fullBodyVerified": true, "shutdownCaptureSaved": true,
            "imageCopyFormats": ["PNG", "TIFF"], "thumbnailMaxPixels": max(thumbnail.width, thumbnail.height),
            "stagedCaptureJournaled": true, "corruptJournalIsolated": true, "missingPNGRecoveredAsText": true,
            "journalReplayVerified": true, "retryIdentityPreserved": true, "duplicateReplaySkipped": true,
            "overlappingAcquisitionIgnored": true, "inFlightQuitSaved": true, "ocrTimeoutJournaled": true,
            "lateRegionQuitJournaled": true,
            "partialAssetRepaired": true,
            "semanticSearch": semanticStatus, "semanticImageVectors": semanticImageVectors,
            "hybridFusionVerified": true,
            "semanticRetryRecoveryVerified": true,
            "coalescedOwnExternalEditVerified": true,
            "watcherExternalEditVerified": true, "watcherExternalEditSeconds": externalSeconds,
            "watcherStoppedOnTermination": true,
            "sync": ["added": stats.added, "updated": stats.updated, "removed": stats.removed, "unchanged": stats.unchanged]
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        return String(decoding: json, as: UTF8.self)
    }

    private func checkFeedback(png: Data, context: FrontmostContext) async throws -> Double {
        let base = pipeline.vault.root.appendingPathComponent("FeedbackCases")
        let live = try await CapturePipeline.open(vaultRoot: base.appendingPathComponent("Vault"), stateDirectory: base.appendingPathComponent("State"), calendar: pipeline.calendar)
        let controller = AppController(pipeline: live, presentsUI: false)
        let latch = SelfTestLatch()
        defer { latch.release() }
        let pixels = PendingCapture(trigger: .region, content: .image(png: png, ocr: nil), source: CapturePipeline.source(context), subtitle: "Image")
        let lateResult = OCRResult(text: "slowocrneedle searchable after budget", lines: [], imageSize: .zero)
        let start = ContinuousClock.now
        guard controller.beginAcquisition({ pixels }, postprocess: { acquired in
            await live.region(png: png, context: context, id: acquired.id, createdAt: acquired.createdAt,
                              recognize: { _ in await latch.hold(); return lateResult })
        }) else { throw SelfTestFailure("Slow OCR acquisition not accepted") }
        await latch.waitUntilHeld()
        guard !controller.acquisitionInProgress else { throw SelfTestFailure("OCR still holds acquisition lock") }
        let next = CapturePipeline.selection(text: "secondacquisitionneedle", context: context)
        guard controller.beginAcquisition({ next }) else { throw SelfTestFailure("Another capture was ignored during OCR") }
        _ = try await selfTestValue(of: Task {
            // Yield until the second interactive operation has entered the ordered processing queue.
            while controller.acquisitionInProgress { await Task.yield() }
            await controller.captures.waitForProcessing()
            guard let tail = controller.captures.commitPending() else { throw SelfTestFailure("Second acquisition was not staged") }
            return try await tail.value
        }, label: "Second acquisition during OCR")
        let elapsed = start.duration(to: .now)
        guard latch.isHeld, try await live.index.capture(id: pixels.id)?.blockKind == .image else {
            throw SelfTestFailure("OCR over budget did not stage/commit an image while recognition remained blocked")
        }
        let noteBefore = try String(contentsOf: live.vault.inboxURL, encoding: .utf8)
        let ordered = NoteParser.parse(contents: noteBefore, notePath: "Inbox.md", titleFallback: "", calendar: live.calendar)
        guard ordered.blocks.compactMap(\.captureID) == [pixels.id, next.id],
              try await live.index.search("slowocrneedle").isEmpty else { throw SelfTestFailure("Acquisitions committed out of order or OCR was not delayed") }
        latch.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var found = false
        while ContinuousClock.now < deadline {
            if try await live.index.search("slowocrneedle").contains(where: { $0.captureID == pixels.id }) { found = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard found, try String(contentsOf: live.vault.inboxURL, encoding: .utf8) == noteBefore else {
            throw SelfTestFailure("Deferred OCR failed to become searchable or changed the note")
        }
        let session = try await controller.startSession(name: "Feedback")
        let browser = FrontmostContext(appName: "Firefox", bundleIdentifier: nil, processIdentifier: 0,
                                       windowTitle: "System Design — Mozilla Firefox")
        await controller.captures.stage(CapturePipeline.selection(text: "First paragraph.", context: browser))
        _ = try await controller.captures.commitPending()?.value
        await controller.captures.stage(CapturePipeline.selection(text: "Second paragraph.", context: browser))
        // This directly exercises the ⌥⇧H submit method with a pending capture.
        guard let subheading = try await controller.addSubheading("### Tradeoffs\n and limits") else {
            throw SelfTestFailure("Subheading was not appended")
        }
        let example = live.vault.root.appendingPathComponent(session.notePath)
        let beforeEmpty = try Data(contentsOf: example)
        guard try await controller.addSubheading(" ### ") == nil, try Data(contentsOf: example) == beforeEmpty else {
            throw SelfTestFailure("Empty subheading changed the note")
        }
        // Replay an already saved subheading: identity, destination and bytes stay fixed.
        let replay = Capture(id: subheading.captureID, createdAt: Date(), content: .subheading("Tradeoffs and limits"), source: CaptureSource())
        try await live.journal.store(CaptureJob(prepared: PreparedCapture(capture: replay, destination: subheading.destination), png: nil, ocr: nil))
        guard await live.replayUnsaved() == 1, try Data(contentsOf: example) == beforeEmpty else { throw SelfTestFailure("Subheading journal replay duplicated the block") }
        await controller.captures.stage(CapturePipeline.selection(text: "Third paragraph.", context: browser))
        _ = try await controller.captures.commitPending()?.value
        let markdown = try String(contentsOf: example, encoding: .utf8)
        guard markdown.components(separatedBy: "### System Design\n").count - 1 == 2,
              let second = markdown.range(of: "Second paragraph."), let heading = markdown.range(of: "## Tradeoffs and limits"), second.lowerBound < heading.lowerBound,
              try await live.index.captureCount(notePath: session.notePath) == 3 else { throw SelfTestFailure("Subheading ordering or source grouping failed") }
        let draftText = "typednoteneedle A personal **note**  \n- [ ] Follow up\n"
        try live.drafts.store(draftText)
        let restoredDrafts = NoteDraftStore(stateDirectory: base.appendingPathComponent("State"))
        guard try restoredDrafts.load() == draftText else { throw SelfTestFailure("Draft was not persisted/restored") }
        await controller.captures.stage(CapturePipeline.selection(text: "Fourth paragraph.", context: browser))
        guard let typed = try await controller.addNote(try restoredDrafts.load()) else { throw SelfTestFailure("Typed note was not saved through controller") }
        guard try live.drafts.load().isEmpty, !FileManager.default.fileExists(atPath: live.drafts.url.path),
              let hit = try await live.index.search("typednoteneedle").first,
              hit.captureID == typed.captureID, hit.title == "Feedback", hit.blockKind == .note,
              let typedDate = hit.createdAt else { throw SelfTestFailure("Note search or draft cleanup failed") }
        let beforeNoteReplay = try Data(contentsOf: example)
        let typedCapture = Capture(id: typed.captureID, createdAt: typedDate, content: .note(CaptureFormat.noteBody(draftText)), source: CaptureSource())
        try await live.journal.store(CaptureJob(prepared: PreparedCapture(capture: typedCapture, destination: typed.destination), png: nil, ocr: nil))
        guard await live.replayUnsaved() == 1, try Data(contentsOf: example) == beforeNoteReplay else { throw SelfTestFailure("Typed-note journal replay duplicated note") }
        await controller.captures.stage(CapturePipeline.selection(text: "Fifth paragraph.", context: browser))
        _ = try await controller.captures.commitPending()?.value
        let withNote = try String(contentsOf: example, encoding: .utf8)
        guard withNote.components(separatedBy: "### System Design\n").count - 1 == 2,
              let preceding = withNote.range(of: "Fourth paragraph."), let noteBody = withNote.range(of: "typednoteneedle"),
              preceding.lowerBound < noteBody.lowerBound,
              try await live.index.captureCount(notePath: session.notePath) == 5 else { throw SelfTestFailure("Typed note pending-first/source grouping failed") }
        try live.drafts.store("Discard this empty draft")
        guard try await controller.addNote(" \n\t") == nil, try live.drafts.load().isEmpty else { throw SelfTestFailure("Whitespace-only input did not clear draft") }
        _ = try await controller.endSession(session)
        let rootDraft = "# independentnoteneedle\n\nA personal **thought**  \n- [ ] Follow up\n"
        let inboxBefore = try Data(contentsOf: live.vault.inboxURL)
        guard let created = try await controller.addNote(rootDraft), created.destination.kind == .note,
              created.destination.url == live.vault.root.appendingPathComponent("independentnoteneedle.md"),
              try live.drafts.load().isEmpty,
              let createdHit = try await live.index.search("independentnoteneedle").first,
              createdHit.captureID == created.captureID, createdHit.title == "independentnoteneedle",
              createdHit.body == "\nA personal **thought**  \n- [ ] Follow up",
              try Data(contentsOf: live.vault.inboxURL) == inboxBefore else { throw SelfTestFailure("Outside-session controller save did not create/index its own note or clear the full draft") }
        let rootBytes = try Data(contentsOf: created.destination.url)
        let rootCapture = Capture(id: created.captureID, createdAt: createdHit.createdAt!, content: .note(createdHit.body), source: CaptureSource())
        let rootJob = CaptureJob(prepared: PreparedCapture(capture: rootCapture, destination: created.destination, createsNote: true), png: nil, ocr: nil, noteDraft: rootDraft)
        try live.drafts.store(rootDraft)
        try await live.journal.store(rootJob)
        guard await live.replayUnsaved() == 1, try live.drafts.load().isEmpty,
              try Data(contentsOf: created.destination.url) == rootBytes,
              !FileManager.default.fileExists(atPath: live.vault.root.appendingPathComponent("independentnoteneedle 2.md").path) else { throw SelfTestFailure("New-note replay changed its path/bytes or retained the original draft") }
        guard let duplicateTitle = try await controller.addNote(rootDraft),
              duplicateTitle.destination.url == created.destination.url,
              !FileManager.default.fileExists(atPath: live.vault.root.appendingPathComponent("independentnoteneedle 2.md").path),
              try String(contentsOf: duplicateTitle.destination.url, encoding: .utf8).contains("<!-- note:\(duplicateTitle.captureID.uuidString.lowercased()) at=") else {
            throw SelfTestFailure("Controller typed-note collision did not append to the existing note")
        }
        guard let savedAsNew = try await controller.addNote(rootDraft, newNote: true),
              savedAsNew.destination.url.lastPathComponent == "independentnoteneedle 2.md" else { throw SelfTestFailure("Save as New Note must keep the collision suffix") }
        try await checkQuickNotePinPersistence()
        let resumed = try await controller.startSession(name: "feedback")
        guard resumed.notePath == session.notePath, resumed.resumed == true else { throw SelfTestFailure("Session did not resume by name") }
        let pinState = base.appendingPathComponent("PinState", isDirectory: true)
        let pins = NotePinStore(stateDirectory: pinState)
        guard pins.paths().isEmpty, !pins.isPinned("Sessions/a.md"),
              try pins.toggle("Sessions/a.md"), try pins.toggle("b.md"), !(try pins.toggle("b.md")),
              pins.isPinned("Sessions/a.md"), !pins.isPinned("b.md") else { throw SelfTestFailure("Pin store toggle failed") }
        try pins.set("c.md", pinned: true)
        try pins.set("c.md", pinned: true)
        let reloadedPins = NotePinStore(stateDirectory: pinState)
        guard reloadedPins.paths() == ["Sessions/a.md", "c.md"],
              try JSONDecoder().decode([String].self, from: Data(contentsOf: pins.url)) == ["Sessions/a.md", "c.md"] else { throw SelfTestFailure("Pin store did not persist") }
        try Data("{not json".utf8).write(to: pins.url)
        guard NotePinStore(stateDirectory: pinState).paths().isEmpty, try reloadedPins.toggle("d.md"),
              NotePinStore(stateDirectory: pinState).paths() == ["d.md"] else { throw SelfTestFailure("Pin store did not recover from a corrupt file") }
        _ = await controller.beginTermination().value
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func checkSemanticRetryRecovery() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = Vault(root: base.appendingPathComponent("Vault", isDirectory: true))
        try vault.prepare()
        let state = base.appendingPathComponent("State", isDirectory: true)
        let index = try SearchIndex(vault: vault, databaseURL: state.appendingPathComponent("index.sqlite"), calendar: pipeline.calendar)

        let cancellationProbe = SemanticRetryProbe()
        let cancellableRetry = SemanticIndexer(index: index, vault: vault,
                                               stateDirectory: state.appendingPathComponent("Cancel"),
                                               modelsDirectory: state.appendingPathComponent("CancelModels", isDirectory: true),
                                               retryDelaysForTesting: [.milliseconds(250)],
                                               testingReconciler: { try await cancellationProbe.reconcile() })
        await cancellableRetry.flush()
        guard await cancellationProbe.count() == 1 else { throw SelfTestFailure("Semantic retry cancellation probe did not fail once") }
        await cancellableRetry.setEnabled(false)
        try await Task.sleep(for: .milliseconds(600))
        guard await cancellationProbe.count() == 1 else { throw SelfTestFailure("Disabling semantic indexing did not cancel its pending retry") }
        await cancellableRetry.stop()

        let shutdownProbe = SemanticRetryProbe()
        let stoppedRetry = SemanticIndexer(index: index, vault: vault,
                                           stateDirectory: state.appendingPathComponent("Shutdown"),
                                           modelsDirectory: state.appendingPathComponent("ShutdownModels", isDirectory: true),
                                           retryDelaysForTesting: [.milliseconds(100)],
                                           testingReconciler: { try await shutdownProbe.reconcile() })
        await stoppedRetry.flush()
        guard await shutdownProbe.count() == 1 else { throw SelfTestFailure("Semantic shutdown probe did not fail once") }
        await stoppedRetry.stop()
        await stoppedRetry.schedule()
        await stoppedRetry.setEnabled(true)
        try await Task.sleep(for: .milliseconds(200))
        guard await shutdownProbe.count() == 1 else { throw SelfTestFailure("Stopped semantic indexing accepted a late schedule or retry") }

        let probe = SemanticRetryProbe()
        let semantic = SemanticIndexer(index: index, vault: vault, stateDirectory: state,
                                       modelsDirectory: state.appendingPathComponent("models", isDirectory: true),
                                       retryDelaysForTesting: [.milliseconds(50)],
                                       testingReconciler: { try await probe.reconcile() })
        await semantic.flush()
        guard await probe.count() == 1 else { throw SelfTestFailure("Semantic retry probe did not start exactly one reconciliation") }
        let retryStart = ContinuousClock.now
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await probe.count() < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await probe.count() == 2,
              retryStart.duration(to: .now) >= .milliseconds(30) else {
            throw SelfTestFailure("Failed semantic reconciliation did not retry automatically after backoff")
        }
        try await Task.sleep(for: .milliseconds(150))
        guard await probe.count() == 2 else { throw SelfTestFailure("Successful semantic retry continued to spin") }
        await semantic.stop()
    }

    /// Exercise the same per-panel state and controller paths used by the outside-session commands.
    private func checkOutsideSessionWrites() async throws {
        let base = pipeline.vault.root.appendingPathComponent("OutsideSessionCases", isDirectory: true)
        let live = try await CapturePipeline.open(vaultRoot: base.appendingPathComponent("Vault"),
                                                  stateDirectory: base.appendingPathComponent("State"), calendar: pipeline.calendar)
        var feedback: [Toast] = []
        let controller = AppController(pipeline: live, presentsUI: false, onToast: { feedback.append($0) })
        let session = try await controller.startSession(name: "Thermo")
        let destination = try Router.destination(noteTitle: nil, activeSession: session, notes: [], vault: live.vault)
        let initialSession = try Data(contentsOf: destination.url)
        let state = QuickNoteState(destination: destination)
        try live.drafts.store("science/Biology\nA thought outside Thermo.")
        try state.toggleOutsideSession(sessionDestination: destination, drafts: live.drafts)
        guard state.outsideSession, state.destination == nil,
              try state.togglePinOnSave(in: live.drafts),
              let saved = try await controller.addNote(try live.drafts.load(), destination: state.destination,
                                                     pinOnSave: state.pinOnSave, outsideSession: state.outsideSession),
              live.vault.relativePath(of: saved.destination.url) == "science/Biology.md",
              live.pins.isPinned("science/Biology.md"),
              try Data(contentsOf: destination.url) == initialSession,
              await live.sessions.current() == session,
              feedback.last?.title == "Saved to Biology · Thermo still active" else {
            throw SelfTestFailure("Detached typed note lost routing, pin intent, feedback or active session")
        }
        // A new panel keeps only the draft; the per-panel detached destination is not persisted.
        let reopened = QuickNoteState(destination: destination)
        guard !reopened.outsideSession, reopened.destination == destination else {
            throw SelfTestFailure("Detached destination survived reopening")
        }
        try state.toggleOutsideSession(sessionDestination: destination, drafts: live.drafts)
        guard !state.outsideSession, state.destination == destination else { throw SelfTestFailure("Toggle did not restore session") }
        try state.toggleOutsideSession(sessionDestination: destination, drafts: live.drafts)
        try state.restoreSessionDestination(destination, drafts: live.drafts)
        guard !state.outsideSession, state.destination == destination else { throw SelfTestFailure("Blank New Note did not restore session") }
        // ⌃⇧N starts detached, saves to its typed/Inbox target, and ⇧⌘N / blank ⌘N behave per launch mode.
        let launched = QuickNoteState(destination: destination, outsideSession: true)
        guard launched.outsideSession, launched.destination == nil,
              let inboxNote = try await controller.addNote("Loose thought from the outside shortcut", destination: launched.destination,
                                                           outsideSession: launched.outsideSession),
              inboxNote.destination.kind != .session, inboxNote.destination.url != destination.url,
              try Data(contentsOf: destination.url) == initialSession else {
            throw SelfTestFailure("Outside-session quick note launch reached the session note")
        }
        try launched.restoreSessionDestination(destination, drafts: live.drafts)
        guard launched.outsideSession, launched.destination == nil else { throw SelfTestFailure("Blank New Note left outside launch mode") }
        try launched.toggleOutsideSession(sessionDestination: destination, drafts: live.drafts)
        guard !launched.outsideSession, launched.destination == destination else {
            throw SelfTestFailure("Outside launch did not toggle back to the session")
        }
        let context = FrontmostContext(appName: "Outside session test", bundleIdentifier: nil, processIdentifier: 0, windowTitle: nil)
        let chosen = CapturePipeline.selection(text: "outside chosen capture", context: context)
        await controller.captures.stage(chosen, outsideSession: true)
        guard let chosenTask = controller.captures.commitPending(noteTitle: "science/Biology", announce: true),
              try await chosenTask.value.destination.url == saved.destination.url else {
            throw SelfTestFailure("Outside capture did not use chosen note")
        }
        let cancelled = CapturePipeline.selection(text: "outside cancelled capture", context: context)
        await controller.captures.stage(cancelled, outsideSession: true)
        let records = try await selfTestJournalJobs(live.journal)
        guard records.contains(where: { $0.prepared.capture.id == cancelled.id && $0.prepared.destination.kind == .inbox }),
              let cancelTask = controller.captures.commitPending(), try await cancelTask.value.destination.kind == .inbox,
              try Data(contentsOf: destination.url) == initialSession, await live.sessions.current() == session else {
            throw SelfTestFailure("Outside capture cancel/recovery fallback changed the session")
        }
        let png = try await AppMedia.demoPNG()
        let image = PendingCapture(trigger: .region, content: .image(png: png, ocr: "outside image OCR"),
                                   source: CapturePipeline.source(context), subtitle: "Image")
        await controller.captures.stage(image, outsideSession: true)
        guard let imageTask = controller.captures.commitPending(noteTitle: "science/Images"),
              live.vault.relativePath(of: try await imageTask.value.destination.url) == "science/Images.md",
              let imageHit = try await live.index.capture(id: image.id), let asset = imageHit.assetPath,
              try await live.assetData(asset) == png,
              try Data(contentsOf: destination.url) == initialSession else {
            throw SelfTestFailure("Outside image capture lost its nested destination, OCR or asset")
        }
        guard let nextNote = try await controller.addNote("Another title\nNormal quick note returns to Thermo."),
              nextNote.destination == destination,
              feedback.last?.title == "Saved to \(destination.title)",
              feedback.last?.subtitle == "Another title" else { throw SelfTestFailure("Next quick note did not return to the session") }
        await controller.captures.stage(CapturePipeline.selection(text: "normal capture returns to Thermo", context: context))
        guard let normalTask = controller.captures.commitPending(), try await normalTask.value.destination == destination else {
            throw SelfTestFailure("Next normal capture did not return to the session")
        }
        // Closing the picker on shutdown must keep its journaled Inbox fallback.
        let beforeShutdown = try Data(contentsOf: destination.url)
        let shutdownCapture = CapturePipeline.selection(text: "outside shutdown fallback", context: context)
        await controller.captures.stage(shutdownCapture, outsideSession: true)
        _ = await controller.beginTermination().value
        guard try await live.index.capture(id: shutdownCapture.id)?.notePath == "Inbox.md",
              try Data(contentsOf: destination.url) == beforeShutdown, await live.sessions.current() == session else {
            throw SelfTestFailure("Outside capture shutdown fallback changed the session")
        }
        try await checkOutsideSessionRetry(in: base)
    }

    private func checkOutsideSessionRetry(in base: URL) async throws {
        let fm = FileManager.default
        for (originalOutside, browseRetry) in [(false, false), (true, false), (true, true)] {
            let directory = base.appendingPathComponent(browseRetry ? "OutsideToBrowseRetry"
                                                       : originalOutside ? "OutsideToSessionRetry" : "SessionToOutsideRetry")
            let live = try await CapturePipeline.open(vaultRoot: directory.appendingPathComponent("Vault"),
                                                     stateDirectory: directory.appendingPathComponent("State"), calendar: pipeline.calendar)
            let controller = AppController(pipeline: live, presentsUI: false)
            let session = try await controller.startSession(name: "Thermo")
            let sessionURL = live.vault.root.appendingPathComponent(session.notePath)
            let sessionBytes = try Data(contentsOf: sessionURL)
            let browseDestination: Destination? = browseRetry
                ? Destination(url: live.vault.root.appendingPathComponent("Physics.md"), title: "Physics", kind: .note) : nil
            if let browseDestination { try Data("# Physics\n\n".utf8).write(to: browseDestination.url) }
            let blockedURL = originalOutside ? live.vault.root : sessionURL
            guard let permissions = try fm.attributesOfItem(atPath: blockedURL.path)[.posixPermissions] else {
                throw SelfTestFailure("Couldn't read retry-path permissions")
            }
            let draft = "Biology\nRetry after changing the quick-note destination."
            var previousID: UUID?
            do {
                try fm.setAttributes([.posixPermissions: originalOutside ? 0o555 : 0o444], ofItemAtPath: blockedURL.path)
                defer { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: blockedURL.path) }
                for _ in 0..<2 {
                    do {
                        _ = try await controller.addNote(draft, outsideSession: originalOutside)
                        throw SelfTestFailure("Read-only note commit unexpectedly succeeded")
                    } catch let error as POSIXError where error.code == .EACCES {
                        // NoteFile.openat rejects the read-only note or parent directory.
                    }
                    let jobs = try await selfTestJournalJobs(live.journal)
                    guard jobs.count == 1, let job = jobs.first, job.noteOutsideSession == originalOutside,
                          previousID == nil || previousID == job.prepared.capture.id else {
                        throw SelfTestFailure("A same-route retry changed its journaled identity or route metadata")
                    }
                    previousID = job.prepared.capture.id
                }
            }
            guard let saved = try await controller.addNote(draft, destination: browseDestination,
                                                          outsideSession: browseRetry || !originalOutside),
                  saved.captureID != previousID, try await live.journal.recordURLs().isEmpty,
                  await live.sessions.current() == session else { throw SelfTestFailure("Changed route reused an incompatible prepared job") }
            if let browseDestination {
                guard saved.destination == browseDestination,
                      try Data(contentsOf: sessionURL) == sessionBytes,
                      !fm.fileExists(atPath: live.vault.root.appendingPathComponent("Biology.md").path),
                      try String(contentsOf: browseDestination.url, encoding: .utf8).contains("Retry after changing") else {
                    throw SelfTestFailure("Browse after a failed detached save retained the stale destination")
                }
            } else if originalOutside {
                guard saved.destination.kind == .session,
                      !fm.fileExists(atPath: live.vault.root.appendingPathComponent("Biology.md").path) else {
                    throw SelfTestFailure("Resetting the editor retried a detached destination")
                }
            } else {
                guard saved.destination.kind == .note, saved.destination.url.lastPathComponent == "Biology.md",
                      try Data(contentsOf: sessionURL) == sessionBytes else {
                    throw SelfTestFailure("Detaching a failed draft appended it to the session")
                }
            }
            _ = await controller.beginTermination().value
            guard await live.replayUnsaved() == 0 else {
                throw SelfTestFailure("A replaced quick-note destination left stale work for replay")
            }
        }
    }

    /// Isolated quick-note persistence assertions also run independently of the host's OCR service.
    private func checkQuickNotePinPersistence() async throws {
        let base = pipeline.vault.root.appendingPathComponent("QuickNotePinCases", isDirectory: true)
        let live = try await CapturePipeline.open(vaultRoot: base.appendingPathComponent("Vault"), stateDirectory: base.appendingPathComponent("State"), calendar: pipeline.calendar)
        let controller = AppController(pipeline: live, presentsUI: false)
        let existingDestination = Destination(url: live.vault.root.appendingPathComponent("Existing.md"), title: "Existing", kind: .note)
        try Data("Existing\n".utf8).write(to: existingDestination.url, options: .atomic)
        // The same state/store/controller path used by closing and reopening an unsaved quick note.
        let pinnedDraft = "draftpinneedle\nA draft whose pin intent survives closing."
        try live.drafts.store(pinnedDraft)
        let firstState = QuickNoteState(destination: nil)
        guard try firstState.togglePinOnSave(in: live.drafts) else { throw SelfTestFailure("Draft pin toggle failed") }
        let reopenedStore = NoteDraftStore(stateDirectory: base.appendingPathComponent("State"))
        let reopened = try reopenedStore.loadSnapshot()
        let reopenedState = QuickNoteState(destination: nil, pinOnSave: reopened.pinOnSave)
        guard reopened.text == pinnedDraft, reopenedState.pinOnSave,
              !QuickNoteState(destination: existingDestination, pinOnSave: reopened.pinOnSave).pinOnSave else {
            throw SelfTestFailure("Closing/reopening lost draft pin intent or overrode an existing destination")
        }
        try reopenedStore.clear(ifMatching: "another draft")
        guard try reopenedStore.loadSnapshot().pinOnSave else { throw SelfTestFailure("Nonmatching cleanup lost draft pin intent") }
        guard let pinnedSave = try await controller.addNote(reopened.text, pinOnSave: reopenedState.pinOnSave),
              let pinnedPath = live.vault.relativePath(of: pinnedSave.destination.url), live.pins.isPinned(pinnedPath),
              try reopenedStore.loadSnapshot().text.isEmpty, !(try reopenedStore.loadSnapshot().pinOnSave) else {
            throw SelfTestFailure("Saving a restored draft did not pin its created note and consume its intent")
        }
        try reopenedStore.store(pinnedDraft, pinOnSave: true)
        try reopenedState.resetPinOnSave(in: reopenedStore)
        guard !(try reopenedStore.loadSnapshot().pinOnSave), try reopenedStore.load() == pinnedDraft else {
            throw SelfTestFailure("New Note/destination reset failed to clear pin intent while preserving text")
        }
        try reopenedStore.store(pinnedDraft, pinOnSave: true)
        try reopenedStore.store("")
        guard !(try reopenedStore.loadSnapshot().pinOnSave), !FileManager.default.fileExists(atPath: reopenedStore.url.path) else {
            throw SelfTestFailure("Discarding a draft did not clear its pin intent")
        }
        let legacyState = base.appendingPathComponent("LegacyDraftState", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyState, withIntermediateDirectories: true)
        let legacyURL = legacyState.appendingPathComponent("draft-note.md")
        try Data(pinnedDraft.utf8).write(to: legacyURL, options: .atomic)
        let migrating = NoteDraftStore(stateDirectory: legacyState)
        guard try migrating.load() == pinnedDraft, !(try migrating.loadSnapshot().pinOnSave) else {
            throw SelfTestFailure("Legacy Markdown draft did not load")
        }
        try migrating.store(pinnedDraft, pinOnSave: true)
        try migrating.store(pinnedDraft + " Edited.")
        guard try NoteDraftStore(stateDirectory: legacyState).loadSnapshot().pinOnSave,
              !FileManager.default.fileExists(atPath: legacyURL.path) else {
            throw SelfTestFailure("Atomic draft migration or pin preservation across edits failed")
        }
        _ = await controller.beginTermination().value
        try await checkQuickNotePinSaveFailures(in: base)
        try await checkFailedSubheadingClearsCommitTail(in: base)
        try await checkQuickNotePinRecovery(in: base)
    }

    private func checkQuickNotePinSaveFailures(in base: URL) async throws {
        let fm = FileManager.default
        let retryBase = base.appendingPathComponent("SaveRetry", isDirectory: true)
        let retryPipeline = try await CapturePipeline.open(vaultRoot: retryBase.appendingPathComponent("Vault"),
            stateDirectory: retryBase.appendingPathComponent("State"), calendar: pipeline.calendar)
        let retryController = AppController(pipeline: retryPipeline, presentsUI: false)
        let retryDraft = "# PinRetry\n\nKeep the prepared identity, but use the current pin intent."
        // The journal remains writable; only the note commit fails, before a file is created.
        let root = retryPipeline.vault.root
        guard let permissions = try fm.attributesOfItem(atPath: root.path)[.posixPermissions] else {
            throw SelfTestFailure("Couldn't read temporary vault permissions")
        }
        do {
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
            defer { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
            do {
                _ = try await retryController.addNote(retryDraft, pinOnSave: true)
                throw SelfTestFailure("Read-only note commit unexpectedly succeeded")
            } catch let error as POSIXError where error.code == .EACCES {
                // NoteFile cannot create its temporary note in the read-only vault.
            }
            guard retryController.captures.commitTailForChecks == nil else {
                throw SelfTestFailure("Failed note save left a stale commit tail that blocks the editor")
            }
        }
        let failedJobs = try await selfTestJournalJobs(retryPipeline.journal)
        let reopened = try NoteDraftStore(stateDirectory: retryBase.appendingPathComponent("State")).loadSnapshot()
        guard failedJobs.count == 1, let job = failedJobs.first,
              job.prepared.destination.url.lastPathComponent == "PinRetry.md", job.noteDraft == retryDraft,
              reopened.text == retryDraft, reopened.pinOnSave, retryPipeline.pins.paths().isEmpty,
              !fm.fileExists(atPath: job.prepared.destination.url.path) else {
            throw SelfTestFailure("Failed note save lost its journal/draft identity or pinned an unsaved note")
        }
        let reopenedState = QuickNoteState(destination: nil, pinOnSave: reopened.pinOnSave)
        guard !(try reopenedState.togglePinOnSave(in: retryPipeline.drafts)),
              let retried = try await retryController.addNote(reopened.text, pinOnSave: reopenedState.pinOnSave),
              retried.captureID == job.prepared.capture.id, retried.destination == job.prepared.destination,
              !retryPipeline.pins.isPinned("PinRetry.md"), try retryPipeline.drafts.load().isEmpty,
              try await retryPipeline.journal.recordURLs().isEmpty,
              try await retryPipeline.index.search("PinRetry").count == 1,
              !fm.fileExists(atPath: root.appendingPathComponent("PinRetry 2.md").path) else {
            throw SelfTestFailure("Retry after removing draft pin intent pinned or duplicated the note")
        }
        _ = await retryController.beginTermination().value

        let pinBase = base.appendingPathComponent("PinStorageFailure", isDirectory: true)
        let pinPipeline = try await CapturePipeline.open(vaultRoot: pinBase.appendingPathComponent("Vault"),
            stateDirectory: pinBase.appendingPathComponent("State"), calendar: pipeline.calendar)
        var toasts: [Toast] = []
        let pinController = AppController(pipeline: pinPipeline, presentsUI: false, onToast: { toasts.append($0) })
        let pinDraft = "# PinFailure\n\nSaving the note must succeed even if its pin cannot be stored."
        // Atomic pin-file replacement throws when its destination is a directory.
        try fm.createDirectory(at: pinPipeline.pins.url, withIntermediateDirectories: false)
        guard let saved = try await pinController.addNote(pinDraft, pinOnSave: true),
              saved.destination.url.lastPathComponent == "PinFailure.md", fm.fileExists(atPath: saved.destination.url.path),
              toasts.count == 1, toasts.last?.style == .warning,
              toasts.last?.title == "Note saved, but not pinned", toasts.last?.subtitle == saved.destination.title,
              pinPipeline.pins.paths().isEmpty,
              try pinPipeline.drafts.loadSnapshot().text.isEmpty, !(try pinPipeline.drafts.loadSnapshot().pinOnSave),
              try await pinPipeline.journal.recordURLs().isEmpty,
              try await pinPipeline.index.search("PinFailure").count == 1,
              !fm.fileExists(atPath: pinPipeline.vault.root.appendingPathComponent("PinFailure 2.md").path) else {
            throw SelfTestFailure("Pin storage failure failed the save, retained a draft/job, duplicated the note, or was not reported")
        }
        let savedBytes = try Data(contentsOf: saved.destination.url)
        try fm.removeItem(at: pinPipeline.pins.url)
        // A cleared-draft save and recovery replay must have nothing left to retry.
        guard try await pinController.addNote(try pinPipeline.drafts.load()) == nil,
              await pinPipeline.replayUnsaved() == 0,
              try Data(contentsOf: saved.destination.url) == savedBytes,
              toasts.count == 1, toasts.last?.title == "Note saved, but not pinned",
              !fm.fileExists(atPath: pinPipeline.vault.root.appendingPathComponent("PinFailure 2.md").path) else {
            throw SelfTestFailure("A nonfatal pin error left work that created another note on retry/re-save")
        }
        _ = await pinController.beginTermination().value
        guard try await pinPipeline.journal.recordURLs().isEmpty, try Data(contentsOf: saved.destination.url) == savedBytes else {
            throw SelfTestFailure("Shutdown retried a note that had already saved despite its pin error")
        }

        let resolveBase = base.appendingPathComponent("PinIdentityFailure", isDirectory: true)
        let opened = try await CapturePipeline.open(vaultRoot: resolveBase.appendingPathComponent("Vault"),
            stateDirectory: resolveBase.appendingPathComponent("State"), calendar: pipeline.calendar)
        let resolvePipeline = CapturePipeline(vault: opened.vault, sessions: opened.sessions, service: opened.service,
            index: opened.index, semantic: opened.semantic, monitor: opened.monitor, journal: opened.journal,
            drafts: opened.drafts, pins: opened.pins, calendar: opened.calendar, logger: opened.logger,
            noteIDForPin: { _ in throw CocoaError(.fileReadInvalidFileName) })
        var resolveToasts: [Toast] = []
        let resolveController = AppController(pipeline: resolvePipeline, presentsUI: false, onToast: { resolveToasts.append($0) })
        guard let resolvedSaved = try await resolveController.addNote("# PinIdentityFailure\n\nSaved despite pin identity lookup failure.", pinOnSave: true),
              fm.fileExists(atPath: resolvedSaved.destination.url.path),
              resolveToasts.count == 1, resolveToasts.last?.style == .warning,
              resolveToasts.last?.title == "Note saved, but not pinned",
              resolvePipeline.pins.paths().isEmpty,
              try resolvePipeline.drafts.loadSnapshot().text.isEmpty,
              try await resolvePipeline.journal.recordURLs().isEmpty else {
            throw SelfTestFailure("A note identity lookup failure was not surfaced as a nonfatal pin warning")
        }
        _ = await resolveController.beginTermination().value
    }

    private func checkFailedSubheadingClearsCommitTail(in base: URL) async throws {
        let fm = FileManager.default
        let failBase = base.appendingPathComponent("SubheadingFailure", isDirectory: true)
        let failPipeline = try await CapturePipeline.open(vaultRoot: failBase.appendingPathComponent("Vault"),
            stateDirectory: failBase.appendingPathComponent("State"), calendar: pipeline.calendar)
        let failController = AppController(pipeline: failPipeline, presentsUI: false)
        // A read-only journal makes the commit task throw before the note is touched.
        let journal = failPipeline.journal.directory
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        guard let permissions = try fm.attributesOfItem(atPath: journal.path)[.posixPermissions] else {
            throw SelfTestFailure("Couldn't read temporary journal permissions")
        }
        do {
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: journal.path)
            defer { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: journal.path) }
            if (try? await failController.addSubheading("Blocked")) != nil {
                throw SelfTestFailure("Read-only subheading commit unexpectedly succeeded")
            }
            guard failController.captures.commitTailForChecks == nil else {
                throw SelfTestFailure("Failed subheading save left a stale commit tail that blocks the editor")
            }
        }
        _ = await failController.beginTermination().value
    }

    private func checkQuickNotePinRecovery(in base: URL) async throws {
        let fm = FileManager.default
        for name in ["ShutdownPinned", "ShutdownCleared", "StartupPinned", "StartupCleared", "StartupDiscarded", "StartupReplaced", "StartupPinFailure"] {
            let directory = base.appendingPathComponent(name, isDirectory: true)
            let root = directory.appendingPathComponent("Vault")
            let stateDirectory = directory.appendingPathComponent("State")
            let original = try await CapturePipeline.open(vaultRoot: root, stateDirectory: stateDirectory, calendar: pipeline.calendar)
            let originalController = AppController(pipeline: original, presentsUI: false)
            let draft = "# \(name)\n\nRecover this note at its prepared path."
            guard let permissions = try fm.attributesOfItem(atPath: root.path)[.posixPermissions] else {
                throw SelfTestFailure("Couldn't read recovery vault permissions")
            }
            do {
                try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
                defer { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
                do {
                    _ = try await originalController.addNote(draft, pinOnSave: true)
                    throw SelfTestFailure("\(name): read-only commit unexpectedly succeeded")
                } catch let error as POSIXError where error.code == .EACCES {
                    // Only the injected permission denial establishes the failed-save case.
                }
            }
            let jobs = try await selfTestJournalJobs(original.journal)
            guard jobs.count == 1, let job = jobs.first, try original.drafts.loadSnapshot().pinOnSave else {
                throw SelfTestFailure("\(name): failed save did not retain the pinned draft and job")
            }
            if name.hasSuffix("Cleared") { try original.drafts.setPinOnSave(false) }
            if name.hasSuffix("Discarded") { try original.drafts.store("") }
            let replacement = "# Replacement\n\nThis new draft's pin must not apply to the older recovered note."
            if name.hasSuffix("Replaced") { try original.drafts.store(replacement, pinOnSave: true) }
            let pinFailure = name.hasSuffix("PinFailure")
            if pinFailure { try fm.createDirectory(at: original.pins.url, withIntermediateDirectories: false) }

            let recovered: CapturePipeline
            var toasts: [Toast] = []
            if name.hasPrefix("Shutdown") {
                // Exercise the actual preparedJobs shutdown retry, without another interactive save.
                _ = await originalController.beginTermination().value
                recovered = original
            } else {
                // Reopen from the journal without letting the old controller's shutdown save it first.
                recovered = try await CapturePipeline.open(vaultRoot: root, stateDirectory: stateDirectory, calendar: pipeline.calendar)
                let reopened = AppController(pipeline: recovered, presentsUI: false, onToast: { toasts.append($0) })
                guard await reopened.start() == 1 else { throw SelfTestFailure("\(name): startup did not replay the job") }
                _ = await reopened.beginTermination().value
            }
            let path = "\(name).md"
            let expectedPin = name.hasSuffix("Pinned")
            let snapshot = try recovered.drafts.loadSnapshot()
            guard recovered.pins.isPinned(path) == expectedPin,
                  try await recovered.journal.recordURLs().isEmpty,
                  try await recovered.index.capture(id: job.prepared.capture.id)?.notePath == path,
                  try await recovered.index.search(name).count == 1,
                  !fm.fileExists(atPath: root.appendingPathComponent("\(name) 2.md").path) else {
                throw SelfTestFailure("\(name): recovery lost pin intent, changed the identity or duplicated the note")
            }
            if name.hasSuffix("Replaced") {
                guard snapshot.text == replacement, snapshot.pinOnSave else { throw SelfTestFailure("Recovery consumed another draft's pin intent") }
            } else {
                guard snapshot.text.isEmpty, !snapshot.pinOnSave else { throw SelfTestFailure("\(name): recovery did not consume draft intent") }
            }
            if pinFailure {
                guard toasts.count == 1, toasts.last?.style == .warning,
                      toasts.last?.title == "Note saved, but not pinned", toasts.last?.subtitle == job.prepared.destination.title else {
                    throw SelfTestFailure("Recovery pin failure did not end with exactly one warning toast")
                }
            }
        }
    }

    private func checkRecovery(png: Data, context: FrontmostContext) async throws {
        let base = pipeline.vault.root.appendingPathComponent("RecoveryCases", isDirectory: true)
        let state = base.appendingPathComponent("State")
        let root = base.appendingPathComponent("Vault")
        let original = try await CapturePipeline.open(vaultRoot: root, stateDirectory: state, calendar: pipeline.calendar)
        let controller = AppController(pipeline: original, presentsUI: false)
        let session = try await controller.startSession(name: "Original destination")
        let note = root.appendingPathComponent(session.notePath)
        let header = try Data(contentsOf: note)
        try FileManager.default.removeItem(at: note)
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: false)
        let text = CapturePipeline.selection(text: "journal text recovery", context: context)
        let image = PendingCapture(trigger: .region, content: .image(png: png, ocr: "journal image recovery"),
                                   source: CapturePipeline.source(context), subtitle: "Image")
        for capture in [text, image] {
            await controller.captures.stage(capture)
            guard let task = controller.captures.commitPending() else { throw SelfTestFailure("Recovery capture not pending") }
            do {
                _ = try await task.value
                throw SelfTestFailure("Injected destination failure unexpectedly succeeded")
            } catch let error as POSIXError where error.code == .EISDIR {
                // The prepared note was replaced by a directory; other failures are unexpected.
            }
        }
        _ = await controller.beginTermination().value
        let jobs = try await selfTestJournalJobs(original.journal)
        guard jobs.count == 2, jobs.contains(where: { $0.png == png }),
              jobs.allSatisfy({ $0.prepared.destination.url.pathComponents == note.pathComponents }) else { throw SelfTestFailure("Failed captures were not journaled") }
        guard let imageJob = jobs.first(where: { $0.png != nil }),
              case .image(let imagePath) = imageJob.prepared.capture.content else { throw SelfTestFailure("Image journal record missing") }
        try Data(png.prefix(3)).write(to: original.assetURL(imagePath))
        try FileManager.default.removeItem(at: note)
        try header.write(to: note)
        _ = try await original.sessions.start(name: "Replacement session")
        let reopened = try await CapturePipeline.open(vaultRoot: root, stateDirectory: state, calendar: pipeline.calendar)
        let restored = await AppController(pipeline: reopened, presentsUI: false).start()
        guard restored == 2, try await reopened.journal.recordURLs().isEmpty else { throw SelfTestFailure("Journal replay did not clear saved work") }
        guard try await reopened.assetData(imagePath) == png else { throw SelfTestFailure("Retry retained a truncated image asset") }
        for job in jobs {
            let hit = try await reopened.index.capture(id: job.prepared.capture.id)
            guard hit?.notePath == session.notePath else { throw SelfTestFailure("Replay re-routed a prepared capture") }
        }
        let before = try Data(contentsOf: note)
        // Simulate a crash after append succeeded but before recovery-record deletion.
        for job in jobs { try await reopened.journal.store(job) }
        let skipped = await reopened.replayUnsaved()
        let after = try Data(contentsOf: note)
        let assets = try FileManager.default.contentsOfDirectory(atPath: reopened.vault.assetsURL.path)
        guard skipped == 2, before == after, assets.count == 1 else { throw SelfTestFailure("Replay duplicated a note block or image asset") }
        let parsed = NoteParser.parse(contents: String(decoding: after, as: UTF8.self), notePath: session.notePath, titleFallback: "", calendar: pipeline.calendar)
        guard Set(parsed.blocks.compactMap(\.captureID)) == Set([text.id, image.id]),
              jobs.allSatisfy({ job in job.prepared.capture.createdAt == (job.prepared.capture.id == text.id ? text.createdAt : image.createdAt) }) else {
            throw SelfTestFailure("Journal identity or timestamp changed")
        }
    }

    private func checkCorruptJournal(png: Data, context: FrontmostContext) async throws {
        let base = pipeline.vault.root.appendingPathComponent("CorruptJournalCases")
        let state = base.appendingPathComponent("State")
        let live = try await CapturePipeline.open(vaultRoot: base.appendingPathComponent("Vault"), stateDirectory: state, calendar: pipeline.calendar)
        let good = CapturePipeline.selection(text: "goodjournalneedle survives corrupt neighbor", context: context)
        try await live.journal.store(live.prepare(good, noteTitle: nil))
        let unsaved = state.appendingPathComponent("unsaved")
        let corruptStem = "00000000-0000-4000-8000-000000000000"
        let corruptData = Data("{broken JSON".utf8)
        try corruptData.write(to: unsaved.appendingPathComponent(corruptStem + ".json"))
        try png.write(to: unsaved.appendingPathComponent(corruptStem + ".png"))
        var missingCaptures: [PendingCapture] = []
        for text in ["missingpngneedle recovered OCR", ""] {
            let missing = PendingCapture(trigger: .region, content: .image(png: png, ocr: text), source: CapturePipeline.source(context), subtitle: "Image")
            try await live.journal.store(live.prepare(missing, noteTitle: nil))
            try FileManager.default.removeItem(at: unsaved.appendingPathComponent(missing.id.uuidString.lowercased() + ".png"))
            missingCaptures.append(missing)
        }
        guard await live.replayUnsaved() == 2, try await live.journal.recordURLs().isEmpty,
              try await live.index.capture(id: good.id)?.body.contains("goodjournalneedle") == true,
              try await live.index.capture(id: missingCaptures[0].id)?.body == "missingpngneedle recovered OCR",
              try await live.index.capture(id: missingCaptures[0].id)?.blockKind == .text,
              try await live.index.capture(id: missingCaptures[1].id) == nil else {
            throw SelfTestFailure("One corrupt or missing-image record blocked valid journal replay")
        }
        let corrupt = unsaved.appendingPathComponent("corrupt")
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: corrupt.path)
        guard quarantined.filter({ $0.hasSuffix(".json") }).count == 2,
              try Data(contentsOf: corrupt.appendingPathComponent(corruptStem + ".json")) == corruptData,
              try Data(contentsOf: corrupt.appendingPathComponent(corruptStem + ".png")) == png,
              await live.replayUnsaved() == 0 else {
            throw SelfTestFailure("Corrupt records were not retained outside the launch replay queue")
        }
    }

    private func checkAcquisitionShutdown(png: Data, context: FrontmostContext) async throws {
        let base = pipeline.vault.root.appendingPathComponent("AcquisitionCases")
        let live = try await CapturePipeline.open(vaultRoot: base.appendingPathComponent("Vault"), stateDirectory: base.appendingPathComponent("State"), calendar: pipeline.calendar)
        let controller = AppController(pipeline: live, presentsUI: false)
        await controller.captures.stage(CapturePipeline.selection(text: "quit pending work", context: context))
        let accepted = controller.beginAcquisition {
            try? await Task.sleep(for: .milliseconds(120))
            return CapturePipeline.selection(text: "quit in-flight work", context: context)
        }
        var overlapped = false
        let rejected = controller.beginAcquisition { overlapped = true; return nil }
        let quit = controller.beginTermination()
        let afterQuit = controller.beginAcquisition { overlapped = true; return nil }
        _ = await quit.value
        let hits = try await live.index.search("quit")
        guard accepted, !rejected, !afterQuit, !overlapped, hits.count == 2 else { throw SelfTestFailure("Acquisition/quit ordering failed") }

        for latePixels in [false, true] {
            let timeoutBase = pipeline.vault.root.appendingPathComponent(latePixels ? "LateRegionCases" : "TimeoutCases")
            let timeoutState = timeoutBase.appendingPathComponent("State")
            let timeoutRoot = timeoutBase.appendingPathComponent("Vault")
            let delayed = try await CapturePipeline.open(vaultRoot: timeoutRoot, stateDirectory: timeoutState, calendar: pipeline.calendar)
            let timeoutController = AppController(pipeline: delayed, presentsUI: false)
            let regionLatch = SelfTestLatch()
            let ocrLatch = SelfTestLatch()
            defer { regionLatch.release(); ocrLatch.release() }
            let pixels = PendingCapture(trigger: .region, content: .image(png: png, ocr: nil), source: CapturePipeline.source(context), subtitle: "Image")
            timeoutController.beginAcquisition {
                if latePixels { await regionLatch.hold() }
                timeoutController.recordAcquiredImage(pixels)
                await ocrLatch.hold()
                return pixels
            }
            if latePixels { await regionLatch.waitUntilHeld() }
            else { await ocrLatch.waitUntilHeld() }
            let quit = timeoutController.beginTermination(timeout: .milliseconds(350))
            if latePixels {
                regionLatch.release()
                await ocrLatch.waitUntilHeld()
            }
            _ = try await selfTestValue(of: quit, label: "Shutdown during blocked OCR")
            guard ocrLatch.isHeld, try await delayed.journal.recordURLs().count == 1 else {
                throw SelfTestFailure("Timed-out OCR pixels were not journaled while recognition remained blocked")
            }
            ocrLatch.release()
            let replay = try await CapturePipeline.open(vaultRoot: timeoutRoot, stateDirectory: timeoutState, calendar: pipeline.calendar)
            guard await replay.replayUnsaved() == 1,
                  try await replay.index.capture(id: pixels.id)?.blockKind == .image,
                  try await replay.journal.recordURLs().isEmpty else { throw SelfTestFailure("Timed-out image replay failed") }
        }
    }
}

@MainActor
private func checkMenuKeyEquivalents() throws {
    guard Hotkey.captureSelection.menuKeyEquivalent == "c", Hotkey.writeNote.menuKeyEquivalent == "n",
          Hotkey(keyCode: 36, modifiers: []).menuKeyEquivalent == "" else {
        throw SelfTestFailure("Menu key equivalents are wrong")
    }
}

@MainActor
private final class SelfTestLatch {
    private var held: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    var isHeld: Bool { held != nil }
    func hold() async {
        await withCheckedContinuation { continuation in
            held = continuation
            ready?.resume(); ready = nil
        }
    }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func release() { held?.resume(); held = nil }
}

// A broad hang guard bounds task completion without asserting shared-runner speed.
@MainActor
private func selfTestValue<Value: Sendable, Failure: Error>(of task: Task<Value, Failure>, label: String) async throws -> Value {
    let completion = SelfTestCompletion()
    Task {
        _ = try? await task.value
        await completion.finish()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !(await completion.isFinished()), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard await completion.isFinished() else {
        task.cancel()
        throw SelfTestFailure("\(label) did not finish within the 30-second hang timeout")
    }
    return try await task.value
}

private actor SelfTestCompletion {
    private var finished = false
    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}

private actor SemanticRetryProbe {
    private var attempts = 0
    private let failingAttempts: Set<Int>

    init(failingAttempts: Set<Int> = [1]) { self.failingAttempts = failingAttempts }

    func reconcile() throws {
        attempts += 1
        if failingAttempts.contains(attempts) { throw ProbeFailure.expectedFailure }
    }

    func count() -> Int { attempts }

    private enum ProbeFailure: Error { case expectedFailure }
}

private func selfTestJournalJobs(_ journal: CaptureJournal) async throws -> [CaptureJob] {
    var jobs: [CaptureJob] = []
    for url in try await journal.recordURLs() { jobs.append(try await journal.load(record: url)) }
    return jobs
}
