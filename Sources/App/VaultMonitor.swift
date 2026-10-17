import Core
import Foundation

struct VaultRefreshRequest: Sendable {
    let notes: Bool
    let assets: Bool
    /// `nil` requests a full digest check; a set checks only those paths for
    /// same-size/same-mtime replacements. An empty set performs metadata checks.
    let recheckingAssetPaths: Set<String>?
}

/// Event-driven index and OCR work run on the utility actor task; no idle polling.
final class VaultMonitor: @unchecked Sendable {
    private let watcher: VaultWatcher
    private let refresh: VaultRefresh
    private let lock = NSLock()
    private var stopped = false

    init(vault: Vault, operation: @escaping @Sendable (VaultRefreshRequest) async -> Void) {
        let refresh = VaultRefresh(operation: operation)
        self.refresh = refresh
        watcher = VaultWatcher(vault: vault) { [weak refresh] change in
            Task.detached(priority: .utility) { await refresh?.changed(change) }
        }
    }

    /// Compatibility for small watcher checks that only need the two work flags.
    convenience init(vault: Vault, operation: @escaping @Sendable (Bool, Bool) async -> Void) {
        self.init(vault: vault) { request in await operation(request.notes, request.assets) }
    }

    var isRunning: Bool { lock.withLock { !stopped && watcher.isRunning } }

    func start() {
        lock.withLock {
            guard !stopped else { return }
            watcher.start()
        }
    }

    /// Permanent for this pipeline, so a late launch sync cannot restart a terminating app.
    func stop() {
        lock.withLock {
            stopped = true
            watcher.stop()
        }
        Task.detached(priority: .utility) { [refresh] in await refresh.stop() }
    }

    func sync() async { await refresh.run(notes: true, assets: false) }
    func backfill() async { await refresh.run(notes: false, assets: true, fullAssetValidation: true) }

    func setExternalRegistryErrorHandler(
        _ handler: @escaping @Sendable (ExternalNoteRegistryError) -> Void
    ) async {
        await refresh.setExternalRegistryErrorHandler(handler)
    }

    func setExternalRegistryRecoveryHandler(_ handler: @escaping @Sendable () -> Void) async {
        await refresh.setExternalRegistryRecoveryHandler(handler)
    }

    func refreshExternalRoots() {
        lock.withLock {
            guard !stopped else { return }
            watcher.refreshExternalRoots()
        }
    }
}

private actor VaultRefresh {
    private let operation: @Sendable (VaultRefreshRequest) async -> Void
    private var externalRegistryErrorHandler: (@Sendable (ExternalNoteRegistryError) -> Void)?
    private var externalRegistryRecoveryHandler: (@Sendable () -> Void)?
    private var worker: Task<Void, Never>?
    private var notesDirty = false
    private var assetsDirty = false
    private var fullAssetValidation = false
    private var changedAssetPaths = Set<String>()
    private var stopped = false

    init(operation: @escaping @Sendable (VaultRefreshRequest) async -> Void) { self.operation = operation }

    func setExternalRegistryErrorHandler(
        _ handler: @escaping @Sendable (ExternalNoteRegistryError) -> Void
    ) {
        externalRegistryErrorHandler = handler
    }

    func setExternalRegistryRecoveryHandler(_ handler: @escaping @Sendable () -> Void) {
        externalRegistryRecoveryHandler = handler
    }

    func changed(_ change: VaultChange) {
        if let error = change.externalRegistryError {
            externalRegistryErrorHandler?(error)
        }
        if change.externalRegistryRecovered {
            externalRegistryRecoveryHandler?()
        }
        let notes = change.needsFullSync || !change.notesChanged.isEmpty
        let pathsAreKnownAssets = change.assetsChanged.allSatisfy(Self.isKnownAssetPath)
        let fullAssetValidation = change.needsFullSync || (!change.assetsChanged.isEmpty && !pathsAreKnownAssets)
        // A new/edited note can introduce an image reference that also needs OCR.
        enqueue(notes: notes,
                assets: change.needsFullSync || notes || !change.assetsChanged.isEmpty,
                fullAssetValidation: fullAssetValidation,
                changedAssetPaths: change.assetsChanged)
    }

    private static func isKnownAssetPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && components.count >= 2 && components[0] == Vault.assetsDirectoryName
            && !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    }

    func run(notes: Bool, assets: Bool, fullAssetValidation: Bool = false) async {
        enqueue(notes: notes, assets: assets, fullAssetValidation: fullAssetValidation, changedAssetPaths: [])
        await worker?.value
    }

    private func enqueue(notes: Bool, assets: Bool, fullAssetValidation: Bool, changedAssetPaths: Set<String>) {
        guard !stopped else { return }
        notesDirty = notesDirty || notes
        assetsDirty = assetsDirty || assets
        if assets {
            self.fullAssetValidation = self.fullAssetValidation || fullAssetValidation
            if !self.fullAssetValidation { self.changedAssetPaths.formUnion(changedAssetPaths) }
        }
        guard worker == nil else { return }
        worker = Task.detached(priority: .utility) { [self] in await drain() }
    }

    private func drain() async {
        while !stopped, !Task.isCancelled, notesDirty || assetsDirty {
            let notes = notesDirty, assets = assetsDirty
            notesDirty = false; assetsDirty = false
            let paths = fullAssetValidation ? nil : changedAssetPaths
            fullAssetValidation = false; changedAssetPaths.removeAll(keepingCapacity: true)
            await operation(VaultRefreshRequest(notes: notes, assets: assets, recheckingAssetPaths: paths))
            // Changes received during the await merge into one additional pass.
        }
        worker = nil
    }

    func stop() {
        stopped = true
        notesDirty = false; assetsDirty = false
        fullAssetValidation = false; changedAssetPaths.removeAll()
        worker?.cancel()
    }
}
