import Core
import EmbedKit
import Foundation
import IOKit.ps
import os

struct SemanticHits: Sendable {
    var text: [SearchHit] = []
    var images: [SearchHit] = []
}

/// Coordinates disposable vectors. Models and runtime stay in EmbedHelper.
actor SemanticIndexer {
    private static let defaultRetryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(60), .seconds(300), .seconds(900)]
    private static let embeddingModelFiles = ModelManifest.current.modelFiles.map(\.path).filter { $0.hasPrefix("onnx/") }

    nonisolated let modelsDirectory: URL
    private let index: SearchIndex
    private let vault: Vault
    private let databaseURL: URL
    private let helperExecutable: URL
    private let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "semantic")
    private let retryDelays: [Duration]
    private let testingReconciler: (@Sendable () async throws -> Void)?
    private var enabled: Bool
    private var store: VectorStore?
    private var client: EmbedClient?
    private var debounce: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var rerun = false
    private var retryAttempt = 0
    private var stopped = false

    init(index: SearchIndex, vault: Vault, stateDirectory: URL, modelsDirectory: URL,
         retryDelaysForTesting: [Duration]? = nil,
         testingReconciler: (@Sendable () async throws -> Void)? = nil) {
        self.index = index; self.vault = vault; self.modelsDirectory = modelsDirectory
        self.databaseURL = stateDirectory.appendingPathComponent("vectors.sqlite")
        if let retryDelaysForTesting, !retryDelaysForTesting.isEmpty {
            self.retryDelays = retryDelaysForTesting
        } else {
            self.retryDelays = Self.defaultRetryDelays
        }
        self.testingReconciler = testingReconciler
        // Bundle lookup in production; sibling product permits SwiftPM self-tests.
        self.helperExecutable = Bundle.main.url(forAuxiliaryExecutable: "EmbedHelper")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("EmbedHelper")
        self.enabled = testingReconciler != nil || Self.modelsInstalled(in: modelsDirectory)
    }

    nonisolated static func modelsInstalled(in directory: URL) -> Bool {
        ModelManifest.current.requiredFiles.allSatisfy {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    func setEnabled(_ value: Bool) {
        guard !stopped else { return }
        guard enabled != value else { return }
        enabled = value
        if value { schedule() }
        else {
            debounce?.cancel(); debounce = nil
            retryTask?.cancel(); retryTask = nil
            job?.cancel(); rerun = false
            retryAttempt = 0
            // Release the embedding helper while disabled; resources() recreates it on re-enable.
            let idle = client
            client = nil
            if let idle { Task { await idle.shutdown() } }
        }
    }

    /// Replaces pending timers without cancelling an inference already warming the helper.
    func schedule() {
        guard enabled, !stopped else { return }
        // A real vault change should get an earlier attempt than a pending backoff.
        retryTask?.cancel(); retryTask = nil
        debounce?.cancel()
        debounce = Task.detached(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.startJob()
        }
    }

    private func startJob() {
        debounce = nil
        guard enabled, !stopped else { return }
        retryTask?.cancel(); retryTask = nil
        guard job == nil else { rerun = true; return }
        let testingReconciler = testingReconciler
        job = Task.detached(priority: .utility) { [self] in
            var failed = false
            do {
                if let testingReconciler { try await testingReconciler() }
                else { try await reconcile() }
            }
            catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    logger.error("Embedding deferred (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
                    failed = true
                }
            }
            await finishedJob(failed: failed)
        }
    }

    private func finishedJob(failed: Bool) {
        job = nil
        guard !stopped else { rerun = false; return }
        // Changed-event reruns must not turn a persistent helper failure into a tight loop.
        if failed {
            rerun = false
            scheduleRetry()
            return
        }
        // A successful pass, including one followed by a queued rerun, starts a
        // fresh retry budget if that rerun encounters a new failure.
        retryAttempt = 0
        if rerun { rerun = false; startJob() }
    }

    private func scheduleRetry() {
        guard enabled, !stopped else { return }
        retryTask?.cancel()
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        retryTask = Task.detached(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.retryFired()
        }
    }

    private func retryFired() {
        retryTask = nil
        guard enabled, !stopped else { return }
        startJob()
    }

    /// Permanently stops retries and in-flight work when the owning app accepts termination.
    func stop() async {
        guard !stopped else { await client?.close(); return }
        stopped = true
        enabled = false
        debounce?.cancel(); debounce = nil
        retryTask?.cancel(); retryTask = nil
        rerun = false
        let active = job
        active?.cancel()
        // Warmup and search may have obtained the client before `stopped` was
        // set. Close first so it interrupts their on-wire polls and rejects late
        // sends; ordinary task cancellation alone must drain transport framing.
        await client?.close()
        await active?.value
        job = nil
    }

    /// Used by the permission-free self-test; production never waits for backfill.
    func flush() async {
        debounce?.cancel(); debounce = nil
        while let active = job { await active.value }
        startJob()
        while let active = job { await active.value }
    }

    private func resources() throws -> (EmbedClient, VectorStore) {
        if client == nil { client = try EmbedClient(helperExecutable: helperExecutable, modelsDirectory: modelsDirectory) }
        if store == nil {
            let modelFiles = Self.embeddingModelFiles.map { modelsDirectory.appendingPathComponent($0) }
            store = try VectorStore(url: databaseURL, modelFiles: modelFiles)
        }
        return (client!, store!)
    }

    private func activeResources() throws -> (EmbedClient, VectorStore)? {
        guard enabled, !Task.isCancelled else { return nil }
        return try resources()
    }

    private func isEnabled() -> Bool { enabled && !stopped }

    // Snapshot/SQLite/file work runs on the detached job, outside this actor.
    // Only resource ownership and scheduling need the coordinator's isolation.
    nonisolated private func reconcile() async throws {
        guard await isEnabled() else { return }
        let blocks = try await index.embeddableBlocks()
        guard let (client, store) = try await activeResources() else { return }
        let existing = Set(try store.keys())
        let fingerprints = try store.fingerprints()
        var expected = Set(blocks.map(\.key))
        for block in blocks where block.kind == .image && !block.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            expected.insert(block.key + "#ocr")
        }
        try store.remove(keys: Array(existing.subtracting(expected)))
        // Each request has one title, so batch within a note (at most 16).
        var batch: [(key: String, body: String, title: String, fingerprint: String)] = []
        for block in blocks {
            try Task.checkCancellation()
            guard await isEnabled() else { return }
            if block.kind == .image {
                guard Self.imagesAllowed else { continue }
                if !block.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   fingerprints[block.key + "#ocr"] != EmbeddingFingerprint.document(block.ocrText, title: block.noteTitle) {
                    if batch.first?.title != block.noteTitle || batch.count == 16 {
                        try await embedBatch(batch, client: client, store: store); batch.removeAll()
                    }
                    batch.append((block.key + "#ocr", block.ocrText, block.noteTitle,
                                  EmbeddingFingerprint.document(block.ocrText, title: block.noteTitle)))
                }
            } else if fingerprints[block.key] != EmbeddingFingerprint.document(block.body, title: block.noteTitle) {
                if batch.first?.title != block.noteTitle || batch.count == 16 {
                    try await embedBatch(batch, client: client, store: store); batch.removeAll()
                }
                batch.append((block.key, block.body, block.noteTitle,
                              EmbeddingFingerprint.document(block.body, title: block.noteTitle)))
            }
        }
        try await embedBatch(batch, client: client, store: store)
        var deferredImageError: Error?
        for block in blocks where block.kind == .image {
            try Task.checkCancellation()
            guard await isEnabled(), Self.imagesAllowed else { return }
            guard let path = block.assetPath else { continue }
            do {
                guard let metadata = try vault.fileSnapshot(relativePath: path, includingContents: false) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                let assetURL = vault.url(forRelativePath: path).standardizedFileURL
                let fingerprint = EmbeddingFingerprint.image(path: assetURL.path, size: metadata.size, modifiedAt: metadata.modifiedAt)
                guard fingerprints[block.key] != fingerprint else { continue }
                guard let snapshot = try vault.fileSnapshot(relativePath: path), let png = snapshot.contents else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                let snapshotFingerprint = EmbeddingFingerprint.image(path: assetURL.path, size: snapshot.size, modifiedAt: snapshot.modifiedAt)
                guard fingerprints[block.key] != snapshotFingerprint else { continue }
                let vector = try await client.embedImage(png)
                try Task.checkCancellation()
                try store.upsert(key: block.key, vector: vector, fingerprint: snapshotFingerprint)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                logger.error("Image embedding deferred for \(block.key, privacy: .private) (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
                if deferredImageError == nil { deferredImageError = error }
            }
        }
        if let deferredImageError { throw deferredImageError }
    }

    nonisolated private func embedBatch(_ batch: [(key: String, body: String, title: String, fingerprint: String)], client: EmbedClient, store: VectorStore) async throws {
        guard !batch.isEmpty else { return }
        try Task.checkCancellation()
        let vectors = try await client.embedDocuments(batch.map(\.body), title: batch[0].title)
        try Task.checkCancellation()
        for (block, vector) in zip(batch, vectors) {
            try store.upsert(key: block.key, vector: vector, fingerprint: block.fingerprint)
        }
    }

    nonisolated static var imagesAllowed: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        guard (thermal == .nominal || thermal == .fair), !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return source as String == kIOPSACPowerValue
    }

    func warm() async {
        guard enabled, !stopped else { return }
        do { _ = try await resources().0.ping() }
        catch { logger.error("Helper warmup failed (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)") }
    }

    nonisolated func search(_ query: String, timeout: Duration = .milliseconds(350)) async -> SemanticHits {
        await SemanticDeadline.run(timeout: timeout, fallback: SemanticHits()) { [self] in
            await searchWork(query)
        }
    }

    nonisolated private func searchWork(_ query: String) async -> SemanticHits {
        do {
            guard let (client, store) = try await activeResources() else { return SemanticHits() }
            try Task.checkCancellation()
            let vector = try await client.embedLatestQuery(query)
            try Task.checkCancellation()
            let nearest = try store.nearest(to: vector, limit: 40)
            try Task.checkCancellation()
            var scores: [String: Float] = [:]
            for (key, score) in nearest {
                let block = key.hasSuffix("#ocr") ? String(key.dropLast(4)) : key
                scores[block] = max(scores[block] ?? -.infinity, score)
            }
            let ranked = scores.keys.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0]! > scores[$1]! }
            let hits = try await index.hits(forEmbeddingKeys: ranked)
            try Task.checkCancellation()
            var result = SemanticHits()
            for key in ranked {
                guard let hit = hits[key] else { continue }
                if hit.blockKind == .image { result.images.append(hit) }
                else { result.text.append(hit) }
            }
            return result
        } catch is CancellationError {
            return SemanticHits()
        } catch {
            logger.error("Semantic query skipped (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
            return SemanticHits()
        }
    }

    nonisolated static func fuse(keyword: [SearchHit], semantic: SemanticHits, limit: Int = 40) -> [SearchHit] {
        var scores: [String: Double] = [:]
        var hits: [String: SearchHit] = [:]
        var order: [String: Int] = [:]
        for list in [keyword, semantic.text, semantic.images] {
            var seen: Set<String> = []
            for (rank, hit) in list.enumerated() where seen.insert(hit.embeddingKey).inserted {
                let key = hit.embeddingKey
                scores[key, default: 0] += 1 / Double(60 + rank + 1)
                if hits[key] == nil { hits[key] = hit; order[key] = order.count }
            }
        }
        return scores.keys.sorted {
            scores[$0] == scores[$1] ? order[$0]! < order[$1]! : scores[$0]! > scores[$1]!
        }.prefix(max(0, limit)).compactMap { hits[$0] }
    }
}
