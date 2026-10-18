import CoreServices
import Darwin
import Foundation
import OSLog

public struct VaultChange: Sendable, Equatable {
    public let notesChanged: Set<String>
    public let assetsChanged: Set<String>
    public let needsFullSync: Bool
    public let externalRegistryError: ExternalNoteRegistryError?
    public let externalRegistryRecovered: Bool

    public init(
        notesChanged: Set<String>,
        assetsChanged: Set<String>,
        needsFullSync: Bool,
        externalRegistryError: ExternalNoteRegistryError? = nil,
        externalRegistryRecovered: Bool = false
    ) {
        self.notesChanged = notesChanged
        self.assetsChanged = assetsChanged
        self.needsFullSync = needsFullSync
        self.externalRegistryError = externalRegistryError
        self.externalRegistryRecovered = externalRegistryRecovered
    }
}

/// Watches the vault recursively and exact registered HOME notes with bounded
/// vnode sources. External directories are never added to the recursive stream.
public final class VaultWatcher: @unchecked Sendable {
    private static let defaultMaximumVnodeDescriptors = 128
    private static let defaultMaximumParentVnodeDescriptors = 64
    private static let defaultFallbackInterval: TimeInterval = 15

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FocusNotes", category: "VaultWatcher")

    private struct VnodeWatch {
        let token: UUID
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    private struct ParentWatch {
        let vnode: VnodeWatch
        var noteIDs: Set<String>
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct FileFingerprint: Equatable {
        let identity: FileIdentity
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ snapshot: VaultFileSnapshot) {
            identity = FileIdentity(device: snapshot.device, inode: snapshot.inode)
            size = snapshot.size
            modifiedSeconds = snapshot.modifiedSeconds
            modifiedNanoseconds = snapshot.modifiedNanoseconds
            changedSeconds = snapshot.changedSeconds
            changedNanoseconds = snapshot.changedNanoseconds
        }
    }

    private struct StableRegistryFailure: Error {
        let registryError: ExternalNoteRegistryError
        let fingerprint: ExternalNoteRegistry.Fingerprint?
    }

    private enum ExternalFileState: Equatable {
        case missing
        case present(FileFingerprint)
    }

    private let vault: Vault
    private let latency: TimeInterval
    private let onChange: @Sendable (VaultChange) -> Void
    private let queue = DispatchQueue(label: "vault-watcher")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var maximumVnodeDescriptors = VaultWatcher.defaultMaximumVnodeDescriptors
    private var maximumParentVnodeDescriptors = VaultWatcher.defaultMaximumParentVnodeDescriptors
    private var fallbackInterval = VaultWatcher.defaultFallbackInterval
    // Includes descriptors whose dispatch sources have been cancelled but whose
    // cancel handlers have not closed them yet.
    private var retainedVnodeDescriptorCount = 0
    private var reportedWatchIssues = Set<String>()

    // FSEvents is intentionally limited to the vault root.
    private var stream: FSEventStreamRef?
    private var streamGeneration = 0
    private var fallbackTimer: DispatchSourceTimer?
    private var pollingFallbackIDs = Set<String>()
    private var lastFallbackReconcile = Date.distantPast
    private var descriptorReconcileScheduled = false

    // All external maps and dispatch sources are confined to `queue`.
    private var registryGeneration: UInt64?
    private var externalLocationsByID: [String: VaultNoteLocation] = [:]
    private var externalFingerprints: [String: ExternalFileState] = [:]
    private var externalSnapshotFailures = Set<String>()
    private var fileWatches: [String: VnodeWatch] = [:]
    private var parentWatches: [String: ParentWatch] = [:]
    private var parentPathByID: [String: String] = [:]

    // Registry parent events are common because app state also contains the
    // index and session state. A cheap exact-entry stat filters those events.
    private var registryParentWatch: VnodeWatch?
    private var registryFileWatch: VnodeWatch?
    private var registryFingerprint: ExternalNoteRegistry.Fingerprint?
    private var lastRegistryError: (fingerprint: ExternalNoteRegistry.Fingerprint?, error: ExternalNoteRegistryError)?

    private var pendingExternalIDs = Set<String>()
    private var pendingExternalParents = Set<String>()
    private var pendingFileRearmIDs = Set<String>()
    private var pendingParentRearmPaths = Set<String>()
    private var pendingRegistryCheck = false
    private var pendingRegistryParentRearm = false
    private var pendingExternalRecovery = false
    private var externalFlushScheduled = false

    public init(
        vault: Vault,
        latency: TimeInterval = 1.0,
        onChange: @escaping @Sendable (VaultChange) -> Void
    ) {
        self.vault = vault
        self.latency = max(0, latency)
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    @_spi(Checks)
    public func configureWatchFallbackForChecks(
        maximumVnodeDescriptors: Int,
        maximumParentVnodeDescriptors: Int,
        interval: TimeInterval
    ) {
        performOnQueue {
            precondition(self.stream == nil, "watch fallback limits must be set before start()")
            self.maximumVnodeDescriptors = max(0, maximumVnodeDescriptors)
            self.maximumParentVnodeDescriptors = max(0, maximumParentVnodeDescriptors)
            self.fallbackInterval = max(0.01, interval)
        }
    }

    @_spi(Checks)
    public var vnodeDescriptorCountForChecks: Int {
        var count = 0
        performOnQueue { count = self.retainedVnodeDescriptorCount }
        return count
    }

    @_spi(Checks)
    public var pollingFallbackCountForChecks: Int {
        var count = 0
        performOnQueue { count = self.pollingFallbackIDs.count }
        return count
    }

    deinit {
        stop()
    }

    /// A failed stream creation/start leaves this false, allowing callers to fall back to sync.
    public var isRunning: Bool {
        var running = false
        performOnQueue { running = self.stream != nil }
        return running
    }

    @_spi(Checks)
    public var streamGenerationForChecks: Int {
        var generation = 0
        performOnQueue { generation = self.streamGeneration }
        return generation
    }

    public func start() {
        performOnQueue { self.startOnQueue() }
    }

    public func stop() {
        performOnQueue { self.stopOnQueue() }
    }

    /// Reloads the cached exact-path snapshot after a local registration. The
    /// registry cache generation avoids rescanning paths on ordinary commits.
    public func refreshExternalRoots() {
        performOnQueue {
            guard self.stream != nil else { return }
            let watchesWereInstalled = self.installRegistryWatchIfNeeded()
            self.refreshRegistrySnapshotOnQueue(
                reconcileOnChange: true,
                forceReload: watchesWereInstalled
            )
        }
    }

    private func startOnQueue() {
        guard stream == nil else { return }
        guard let stream = createStartedVaultStream() else {
            reportWatchIssue(
                key: "vault-stream-unavailable",
                message: "Could not start the vault FSEvents stream; requesting a full sync."
            )
            return
        }
        clearWatchIssue("vault-stream-unavailable")
        self.stream = stream
        streamGeneration += 1

        startFallbackTimerOnQueue()
        _ = installRegistryWatchIfNeeded()
        refreshRegistrySnapshotOnQueue(reconcileOnChange: false, forceReload: true)
    }

    private func createStartedVaultStream() -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [vault.root.path] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            vaultWatcherCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        ) else {
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        return stream
    }

    private func stopOnQueue() {
        if let fallbackTimer {
            self.fallbackTimer = nil
            fallbackTimer.setEventHandler {}
            fallbackTimer.cancel()
        }
        if let stream {
            self.stream = nil
            stop(stream)
        }

        fileWatches.values.forEach(cancel)
        fileWatches.removeAll()
        parentWatches.values.forEach { cancel($0.vnode) }
        parentWatches.removeAll()
        if let registryFileWatch { cancel(registryFileWatch) }
        if let registryParentWatch { cancel(registryParentWatch) }
        registryFileWatch = nil
        registryParentWatch = nil

        externalLocationsByID.removeAll()
        externalFingerprints.removeAll()
        externalSnapshotFailures.removeAll()
        parentPathByID.removeAll()
        pollingFallbackIDs.removeAll()
        registryGeneration = nil
        registryFingerprint = nil
        lastRegistryError = nil
        pendingExternalIDs.removeAll()
        pendingExternalParents.removeAll()
        pendingFileRearmIDs.removeAll()
        pendingParentRearmPaths.removeAll()
        pendingRegistryCheck = false
        pendingRegistryParentRearm = false
        pendingExternalRecovery = false
        lastFallbackReconcile = .distantPast
        reportedWatchIssues.removeAll()
    }

    private func stop(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func performOnQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private func refreshRegistrySnapshotOnQueue(reconcileOnChange: Bool, forceReload: Bool = false) {
        let snapshot: ExternalNoteRegistry.Snapshot?
        do {
            snapshot = try loadStableRegistrySnapshot(forceReload: forceReload || lastRegistryError != nil)
        } catch let failure as StableRegistryFailure {
            reportRegistryFailure(failure.registryError, fingerprint: failure.fingerprint,
                                  context: "loading the external note registry", notify: true)
            replaceRegistryFileWatchAfterChange()
            return
        } catch let error as ExternalNoteRegistryError {
            let fingerprint = try? vault.externalRegistryFingerprint()
            reportRegistryFailure(error, fingerprint: fingerprint,
                                  context: "loading the external note registry", notify: true)
            replaceRegistryFileWatchAfterChange()
            return
        } catch {
            let fingerprint = try? vault.externalRegistryFingerprint()
            let typedError = ExternalNoteRegistryError.unreadableRegistry
            Self.logger.error("Unexpected error loading the external note registry: \(String(describing: error), privacy: .public)")
            reportRegistryFailure(typedError, fingerprint: fingerprint,
                                  context: "loading the external note registry", notify: true)
            replaceRegistryFileWatchAfterChange()
            return
        }

        let update = applyRegistrySnapshot(snapshot, requestSyncWhenApplied: reconcileOnChange)
        if update.needsFullSync || update.error != nil || update.recovered {
            onChange(VaultChange(notesChanged: [], assetsChanged: [], needsFullSync: update.needsFullSync,
                                 externalRegistryError: update.error,
                                 externalRegistryRecovered: update.recovered))
        }
    }

    private func applyRegistrySnapshot(
        _ snapshot: ExternalNoteRegistry.Snapshot?,
        requestSyncWhenApplied: Bool
    ) -> (needsFullSync: Bool, error: ExternalNoteRegistryError?, recovered: Bool) {
        let generation = snapshot?.generation ?? 0
        let registryWasInvalid = lastRegistryError != nil
        guard registryGeneration != generation || registryWasInvalid else { return (false, nil, false) }

        let locations: [VaultNoteLocation]
        do {
            locations = try vault.externalNoteLocations(snapshot: snapshot)
        } catch let error as ExternalNoteRegistryError {
            let fingerprint = try? vault.externalRegistryFingerprint()
            _ = reportRegistryFailure(error, fingerprint: fingerprint,
                                      context: "building the registered external-note snapshot", notify: false)
            return (true, error, false)
        } catch {
            Self.logger.error("Unexpected error building the external-note snapshot: \(String(describing: error), privacy: .public)")
            let fingerprint = try? vault.externalRegistryFingerprint()
            _ = reportRegistryFailure(.unreadableRegistry, fingerprint: fingerprint,
                                      context: "building the registered external-note snapshot", notify: false)
            return (true, .unreadableRegistry, false)
        }

        registryGeneration = generation
        externalLocationsByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })
        externalFingerprints = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, .missing) })
        externalSnapshotFailures.removeAll()
        reconcileExternalWatches()
        if registryWasInvalid {
            lastRegistryError = nil
            clearWatchIssue("registry-snapshot")
            return (true, nil, true)
        }
        return (requestSyncWhenApplied, nil, false)
    }

    /// Brackets each uncached registry read with the exact file fingerprint.
    /// Vnode sources are attached before the startup call, and the second stat
    /// closes the remaining read/subscribe window if another process replaces
    /// the file while it is being loaded.
    private func loadStableRegistrySnapshot(forceReload: Bool) throws -> ExternalNoteRegistry.Snapshot? {
        var shouldReload = forceReload
        for _ in 0..<3 {
            let before = try vault.externalRegistryFingerprint()
            if shouldReload || before != registryFingerprint {
                vault.invalidateExternalRegistryCache()
                shouldReload = true
            }
            do {
                let snapshot = try vault.externalRegistrySnapshot()
                let after = try vault.externalRegistryFingerprint()
                if before == after {
                    registryFingerprint = after
                    return snapshot
                }
                shouldReload = true
            } catch let registryError as ExternalNoteRegistryError {
                let after = try? vault.externalRegistryFingerprint()
                if before == after {
                    registryFingerprint = after ?? nil
                    throw StableRegistryFailure(registryError: registryError, fingerprint: after ?? nil)
                }
                shouldReload = true
            } catch {
                let after = try? vault.externalRegistryFingerprint()
                if before == after { throw error }
                shouldReload = true
            }
        }
        throw POSIXError(.EAGAIN)
    }

    private func reconcileExternalWatches(forceParentRearm: Set<String> = []) {
        let desiredParentPaths = parentPathsByNoteID()
        reconcileParentWatches(desiredParentPaths, forceRearm: forceParentRearm)

        let maximumParents = min(maximumParentVnodeDescriptors, maximumVnodeDescriptors)
        let maximumFiles = max(0, maximumVnodeDescriptors - 2 - maximumParents)
        var selectedFiles = Set(fileWatches.keys.filter { externalLocationsByID[$0] != nil })
        for id in externalLocationsByID.keys.sorted() where selectedFiles.count < maximumFiles {
            selectedFiles.insert(id)
        }
        for id in externalLocationsByID.keys.sorted() {
            refreshExternalFileWatch(id: id, allowWatch: selectedFiles.contains(id))
        }
        for id in Array(fileWatches.keys) where externalLocationsByID[id] == nil {
            if let watch = fileWatches.removeValue(forKey: id) { cancel(watch) }
        }

        updatePollingFallbackIDs()
        let validNoteIDs = Set(externalLocationsByID.keys)
        let validParentPaths = Set(desiredParentPaths.values)
        reportedWatchIssues = Set(reportedWatchIssues.filter { key in
            if key.hasPrefix("file-open:") || key.hasPrefix("snapshot:") {
                return validNoteIDs.contains(String(key.dropFirst(key.hasPrefix("file-open:") ? "file-open:".count : "snapshot:".count)))
            }
            if key.hasPrefix("parent-open:") {
                return validParentPaths.contains(String(key.dropFirst("parent-open:".count)))
            }
            return true
        })

        if Set(desiredParentPaths.values).count > maximumParents {
            reportWatchIssue(
                key: "parent-watch-cap",
                message: "External notes exceed the parent vnode limit; \(pollingFallbackIDs.count) registered notes are covered by polling."
            )
        } else {
            clearWatchIssue("parent-watch-cap")
        }
        if externalLocationsByID.count > maximumFiles {
            reportWatchIssue(
                key: "file-watch-cap",
                message: "External notes exceed the file vnode limit; \(pollingFallbackIDs.count) registered notes are covered by polling."
            )
        } else {
            clearWatchIssue("file-watch-cap")
        }
        if !pollingFallbackIDs.isEmpty {
            reportWatchIssue(
                key: "external-watch-fallback",
                message: "Some registered external notes do not have both vnode sources; exact-path polling is active for \(pollingFallbackIDs.count) notes."
            )
        } else {
            clearWatchIssue("external-watch-fallback")
        }
    }

    private func clearExternalWatchesOnQueue() {
        fileWatches.values.forEach(cancel)
        fileWatches.removeAll()
        parentWatches.values.forEach { cancel($0.vnode) }
        parentWatches.removeAll()
        externalLocationsByID.removeAll()
        externalFingerprints.removeAll()
        externalSnapshotFailures.removeAll()
        parentPathByID.removeAll()
        pendingExternalIDs.removeAll()
        pendingExternalParents.removeAll()
        pollingFallbackIDs.removeAll()
    }

    private func updatePollingFallbackIDs() {
        pollingFallbackIDs = Set(externalLocationsByID.keys.filter { id in
            let parentCovered = parentPathByID[id].map { parentWatches[$0] != nil } ?? false
            let fileCovered = fileWatches[id] != nil ||
                (externalFingerprints[id] == .missing && !externalSnapshotFailures.contains(id))
            return !parentCovered || !fileCovered || externalSnapshotFailures.contains(id)
        })
    }

    /// Select the immediate parent or closest existing ancestor. A HOME vnode
    /// is nonrecursive and is used only when no narrower existing directory is
    /// available, so it can re-arm a missing nested tree one level at a time.
    private func parentPathsByNoteID() -> [String: String] {
        var paths: [String: String] = [:]
        for (id, location) in externalLocationsByID.sorted(by: { $0.key < $1.key }) {
            let components = location.relativePath.split(separator: "/").map(String.init)
            var candidate = components.dropLast().joined(separator: "/")
            while true {
                if let descriptor = vault.openExternalWatchDirectory(relativePath: candidate) {
                    close(descriptor)
                    paths[id] = candidate
                    break
                }
                guard !candidate.isEmpty else { break }
                candidate = candidate.split(separator: "/").dropLast().joined(separator: "/")
            }
        }
        return paths
    }

    private func makeParentWatch(path: String) -> VnodeWatch? {
        guard reserveVnodeDescriptor() else { return nil }
        guard let descriptor = vault.openExternalWatchDirectory(relativePath: path) else {
            releaseVnodeDescriptor()
            reportWatchIssue(key: "parent-open:\(path)", message: "Could not open an external note parent vnode; registered notes below it will be polled.")
            return nil
        }
        let token = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.handleExternalParentEvent(path: path, token: token) }
        source.setCancelHandler { [weak self] in
            close(descriptor)
            self?.vnodeDescriptorDidClose()
        }
        source.resume()
        clearWatchIssue("parent-open:\(path)")
        return VnodeWatch(token: token, descriptor: descriptor, source: source)
    }

    private func refreshExternalFileWatch(id: String, forceRearm: Bool = false, allowWatch: Bool = true) {
        guard let location = externalLocationsByID[id] else { return }
        let snapshot: VaultFileSnapshot?
        do {
            snapshot = try externalNoteSnapshot(id: id)
            externalSnapshotFailures.remove(id)
            clearWatchIssue("snapshot:\(id)")
        } catch {
            externalSnapshotFailures.insert(id)
            reportWatchIssue(
                key: "snapshot:\(id)",
                message: "Could not snapshot a registered external note; requesting a full sync and keeping it on the polling fallback."
            )
            return
        }
        let fingerprint = snapshot.map(FileFingerprint.init)
        externalFingerprints[id] = fingerprint.map(ExternalFileState.present) ?? .missing

        if !forceRearm,
           let existing = fileWatches[id],
           let fingerprint,
           fileIdentity(of: existing.descriptor) == fingerprint.identity {
            return
        }
        if let existing = fileWatches.removeValue(forKey: id) { cancel(existing) }

        guard fingerprint != nil else {
            clearWatchIssue("file-open:\(id)")
            return
        }
        guard allowWatch else { return }
        guard reserveVnodeDescriptor() else {
            reportWatchIssue(key: "file-watch-cap", message: "External file vnode descriptor limit reached; exact-path polling is active.")
            return
        }
        guard let descriptor = vault.openExternalWatchFile(location) else {
            releaseVnodeDescriptor()
            reportWatchIssue(key: "file-open:\(id)", message: "Could not open a registered external note vnode; exact-path polling is active for that note.")
            return
        }
        let token = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.handleExternalFileEvent(id: id, token: token) }
        source.setCancelHandler { [weak self] in
            close(descriptor)
            self?.vnodeDescriptorDidClose()
        }
        source.resume()
        fileWatches[id] = VnodeWatch(token: token, descriptor: descriptor, source: source)
        clearWatchIssue("file-open:\(id)")
    }

    private func externalNoteSnapshot(id: String) throws -> VaultFileSnapshot? {
        do {
            return try vault.fileSnapshot(noteID: id, includingContents: false)
        } catch let error as POSIXError where error.code == .ENOENT {
            // A missing ancestor is reported as ENOENT by the anchored walk,
            // while a missing leaf returns nil. Both mean the registered note
            // is currently absent and must be reconciled as such.
            return nil
        }
    }

    private func reserveVnodeDescriptor() -> Bool {
        reserveVnodeDescriptors(1)
    }

    private func reserveVnodeDescriptors(_ count: Int) -> Bool {
        guard count >= 0, retainedVnodeDescriptorCount + count <= maximumVnodeDescriptors else { return false }
        retainedVnodeDescriptorCount += count
        return true
    }

    private func releaseVnodeDescriptor() {
        releaseVnodeDescriptors(1)
    }

    private func releaseVnodeDescriptors(_ count: Int) {
        retainedVnodeDescriptorCount = max(0, retainedVnodeDescriptorCount - count)
    }

    private func vnodeDescriptorDidClose() {
        releaseVnodeDescriptor()
        guard stream != nil, !descriptorReconcileScheduled else { return }
        descriptorReconcileScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            self.descriptorReconcileScheduled = false
            guard self.stream != nil else { return }
            if self.registryParentWatch == nil {
                _ = self.installRegistryWatchIfNeeded()
            } else if self.registryFileWatch == nil {
                self.replaceRegistryFileWatchAfterChange()
            }
            if !self.pollingFallbackIDs.isEmpty {
                self.reconcileExternalWatches()
            }
        }
    }

    private func fileIdentity(of descriptor: Int32) -> FileIdentity? {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { return nil }
        return FileIdentity(device: UInt64(attributes.st_dev), inode: UInt64(attributes.st_ino))
    }

    @discardableResult
    private func installRegistryWatchIfNeeded() -> Bool {
        guard registryParentWatch == nil else { return false }
        guard reserveVnodeDescriptors(2) else {
            reportWatchIssue(
                key: "registry-watch",
                message: "The watcher descriptor limit prevented registry vnode setup; registry fingerprint polling is active."
            )
            return false
        }

        let descriptors: ExternalNoteRegistry.WatchDescriptors?
        do {
            descriptors = try vault.openExternalRegistryWatchDescriptors()
        } catch {
            releaseVnodeDescriptors(2)
            reportWatchIssue(
                key: "registry-watch",
                message: "Could not open external registry vnode descriptors (\(String(describing: error))); registry fingerprint polling is active."
            )
            return false
        }
        guard let descriptors else {
            releaseVnodeDescriptors(2)
            do {
                guard try vault.externalRegistrySnapshot() != nil else { return false }
            } catch let registryError as ExternalNoteRegistryError {
                reportRegistryFailure(registryError, fingerprint: try? vault.externalRegistryFingerprint(),
                                      context: "checking registry watch availability", notify: true)
                return false
            } catch {
                Self.logger.error("Unexpected error checking registry watch availability: \(String(describing: error), privacy: .private)")
                reportRegistryFailure(.unreadableRegistry, fingerprint: nil,
                                      context: "checking registry watch availability", notify: true)
                return false
            }
            reportWatchIssue(
                key: "registry-watch",
                message: "External registry vnode descriptors are unavailable; registry fingerprint polling is active."
            )
            return false
        }

        let parentToken = UUID()
        let parentSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptors.parent,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        parentSource.setEventHandler { [weak self] in self?.handleRegistryEvent(token: parentToken, isFile: false) }
        parentSource.setCancelHandler { [weak self] in
            close(descriptors.parent)
            self?.vnodeDescriptorDidClose()
        }
        parentSource.resume()
        registryParentWatch = VnodeWatch(token: parentToken, descriptor: descriptors.parent, source: parentSource)

        installRegistryFileWatch(descriptors.file)
        clearWatchIssue("registry-watch")
        return true
    }

    private func installRegistryFileWatch(_ descriptor: Int32?) {
        guard let descriptor else {
            releaseVnodeDescriptor()
            return
        }
        let token = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.handleRegistryEvent(token: token, isFile: true) }
        source.setCancelHandler { [weak self] in
            close(descriptor)
            self?.vnodeDescriptorDidClose()
        }
        source.resume()
        registryFileWatch = VnodeWatch(token: token, descriptor: descriptor, source: source)
    }

    private func handleRegistryEvent(token: UUID, isFile: Bool) {
        guard stream != nil else { return }
        let flags: DispatchSource.FileSystemEvent
        if isFile {
            guard let watch = registryFileWatch, watch.token == token else { return }
            flags = watch.source.data
        } else {
            guard let watch = registryParentWatch, watch.token == token else { return }
            flags = watch.source.data
        }
        enqueueExternalFlush {
            self.pendingRegistryCheck = true
            if !isFile && (flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke)) {
                self.pendingRegistryParentRearm = true
            }
        }
    }

    private func handleExternalFileEvent(id: String, token: UUID) {
        guard stream != nil, fileWatches[id]?.token == token else { return }
        let flags = fileWatches[id]?.source.data ?? []
        enqueueExternalFlush { self.pendingExternalIDs.insert(id) }
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            pendingFileRearmIDs.insert(id)
        }
    }

    private func handleExternalParentEvent(path: String, token: UUID) {
        guard stream != nil,
              let watch = parentWatches[path], watch.vnode.token == token else { return }
        let flags = watch.vnode.source.data
        enqueueExternalFlush {
            self.pendingExternalParents.insert(path)
            self.pendingExternalIDs.formUnion(watch.noteIDs)
        }
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            pendingParentRearmPaths.insert(path)
        }
    }

    private func failClosedRegistry(
        _ error: ExternalNoteRegistryError,
        fingerprint: ExternalNoteRegistry.Fingerprint?
    ) -> Bool {
        let didChange = lastRegistryError?.fingerprint != fingerprint || lastRegistryError?.error != error
        registryFingerprint = fingerprint
        guard didChange else { return false }
        vault.invalidateExternalRegistryCache()
        clearExternalWatchesOnQueue()
        lastRegistryError = (fingerprint, error)
        return true
    }

    @discardableResult
    private func reportRegistryFailure(
        _ error: ExternalNoteRegistryError,
        fingerprint: ExternalNoteRegistry.Fingerprint?,
        context: String,
        notify: Bool
    ) -> Bool {
        guard failClosedRegistry(error, fingerprint: fingerprint) else { return false }
        Self.logger.error("External note registry failure while \(context): \(error.localizedDescription, privacy: .public)")
        if notify {
            onChange(VaultChange(notesChanged: [], assetsChanged: [], needsFullSync: true,
                                 externalRegistryError: error))
        }
        return true
    }

    private func reportWatchIssue(key: String, message: String) {
        guard reportedWatchIssues.insert(key).inserted else { return }
        let needsFullSync = reportedWatchIssues.count == 1
        Self.logger.warning("\(message, privacy: .public)")
        if needsFullSync {
            onChange(VaultChange(notesChanged: [], assetsChanged: [], needsFullSync: true))
        }
    }

    private func clearWatchIssue(_ key: String) {
        reportedWatchIssues.remove(key)
    }

    private func enqueueExternalFlush(_ update: () -> Void) {
        update()
        scheduleExternalFlush()
    }

    private func startFallbackTimerOnQueue() {
        guard fallbackTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + fallbackInterval, repeating: fallbackInterval)
        timer.setEventHandler { [weak self] in self?.pollFallbacksOnQueue() }
        timer.resume()
        fallbackTimer = timer
    }

    private func pollFallbacksOnQueue() {
        guard stream != nil else { return }

        if registryParentWatch == nil {
            _ = installRegistryWatchIfNeeded()
        }

        var needsFullSync = false
        var registryError: ExternalNoteRegistryError?
        var recovered = false
        processRegistryChange(&needsFullSync, error: &registryError)
        if pendingExternalRecovery {
            pendingExternalRecovery = false
            recovered = true
        }

        var changedIDs = Set<String>()
        for id in pollingFallbackIDs.sorted() {
            guard externalLocationsByID[id] != nil else { continue }
            let current: VaultFileSnapshot?
            do {
                current = try externalNoteSnapshot(id: id)
                externalSnapshotFailures.remove(id)
                clearWatchIssue("snapshot:\(id)")
            } catch {
                externalSnapshotFailures.insert(id)
                reportWatchIssue(
                    key: "snapshot:\(id)",
                    message: "Could not poll a registered external note; requesting a full sync and retaining its polling fallback."
                )
                continue
            }
            let state = current.map(FileFingerprint.init).map(ExternalFileState.present) ?? .missing
            if externalFingerprints[id] != state {
                externalFingerprints[id] = state
                changedIDs.insert(id)
            }
        }
        if !changedIDs.isEmpty {
            reconcileExternalWatches()
        }

        let retryInterval = max(30, fallbackInterval * 4)
        if !pollingFallbackIDs.isEmpty, Date().timeIntervalSince(lastFallbackReconcile) >= retryInterval {
            lastFallbackReconcile = Date()
            reconcileExternalWatches()
        }
        if registryParentWatch != nil, registryFileWatch == nil {
            replaceRegistryFileWatchAfterChange()
        }

        guard needsFullSync || !changedIDs.isEmpty || registryError != nil || recovered else { return }
        onChange(VaultChange(
            notesChanged: changedIDs,
            assetsChanged: [],
            needsFullSync: needsFullSync,
            externalRegistryError: registryError,
            externalRegistryRecovered: recovered
        ))
    }

    private func scheduleExternalFlush() {
        guard !externalFlushScheduled else { return }
        externalFlushScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
            self?.flushExternalEvents()
        }
    }

    private func flushExternalEvents() {
        externalFlushScheduled = false
        guard stream != nil else { return }

        var needsFullSync = false
        var error: ExternalNoteRegistryError? = nil
        var recovered = pendingExternalRecovery
        pendingExternalRecovery = false

        if pendingRegistryCheck {
            pendingRegistryCheck = false
            processRegistryChange(&needsFullSync, error: &error)
            if pendingExternalRecovery {
                pendingExternalRecovery = false
                recovered = true
            }
        }
        if pendingRegistryParentRearm {
            pendingRegistryParentRearm = false
            if let parent = registryParentWatch {
                registryParentWatch = nil
                cancel(parent)
            }
            if let file = registryFileWatch {
                registryFileWatch = nil
                cancel(file)
            }
            installRegistryWatchIfNeeded()
        }

        let changedParentPaths = pendingExternalParents
        pendingExternalParents.removeAll()
        let fileRearmIDs = pendingFileRearmIDs
        pendingFileRearmIDs.removeAll()
        let parentRearmPaths = pendingParentRearmPaths
        pendingParentRearmPaths.removeAll()
        var idsToCheck = pendingExternalIDs
        pendingExternalIDs.removeAll()
        for parentPath in changedParentPaths {
            idsToCheck.formUnion(parentWatches[parentPath]?.noteIDs ?? [])
        }

        var changedIDs = Set<String>()
        for id in idsToCheck where externalLocationsByID[id] != nil {
            let current: VaultFileSnapshot?
            do {
                current = try externalNoteSnapshot(id: id)
                externalSnapshotFailures.remove(id)
                clearWatchIssue("snapshot:\(id)")
            } catch {
                externalSnapshotFailures.insert(id)
                reportWatchIssue(
                    key: "snapshot:\(id)",
                    message: "Could not snapshot a changed external note; requesting a full sync and keeping it on the polling fallback."
                )
                continue
            }
            let fingerprint = current.map(FileFingerprint.init)
            let state = fingerprint.map(ExternalFileState.present) ?? .missing
            if externalFingerprints[id] != state {
                changedIDs.insert(id)
                externalFingerprints[id] = state
            }
            refreshExternalFileWatch(id: id, forceRearm: fileRearmIDs.contains(id))
        }

        if !changedParentPaths.isEmpty {
            let oldParents = parentPathByID
            let updatedParents = parentPathsByNoteID()
            if oldParents != updatedParents || !parentRearmPaths.isEmpty {
                parentPathByID = updatedParents
                reconcileExternalWatches(forceParentRearm: parentRearmPaths)
            }
        }

        guard needsFullSync || !changedIDs.isEmpty || error != nil || recovered else { return }
        onChange(VaultChange(
            notesChanged: changedIDs,
            assetsChanged: [],
            needsFullSync: needsFullSync,
            externalRegistryError: error,
            externalRegistryRecovered: recovered
        ))
    }

    private func processRegistryChange(
        _ needsFullSync: inout Bool,
        error reportedError: inout ExternalNoteRegistryError?
    ) {
        let currentFingerprint: ExternalNoteRegistry.Fingerprint?
        do {
            currentFingerprint = try vault.externalRegistryFingerprint()
        } catch let registryError as ExternalNoteRegistryError {
            let fingerprint = try? vault.externalRegistryFingerprint()
            if reportRegistryFailure(registryError, fingerprint: fingerprint,
                                     context: "checking its fingerprint", notify: false) {
                reportedError = registryError
                needsFullSync = true
            }
            replaceRegistryFileWatchAfterChange()
            return
        } catch {
            Self.logger.error("Unexpected error checking the external registry fingerprint: \(String(describing: error), privacy: .public)")
            if reportRegistryFailure(.unreadableRegistry, fingerprint: nil,
                                     context: "checking its fingerprint", notify: false) {
                reportedError = .unreadableRegistry
                needsFullSync = true
            }
            replaceRegistryFileWatchAfterChange()
            return
        }
        guard currentFingerprint != registryFingerprint || lastRegistryError != nil else { return }
        registryFingerprint = currentFingerprint
        vault.invalidateExternalRegistryCache()

        do {
            let snapshot = try loadStableRegistrySnapshot(forceReload: false)
            let update = applyRegistrySnapshot(snapshot, requestSyncWhenApplied: true)
            needsFullSync = needsFullSync || update.needsFullSync
            if update.error != nil { reportedError = update.error }
            if update.recovered { pendingExternalRecovery = true }
            replaceRegistryFileWatchAfterChange()
        } catch let failure as StableRegistryFailure {
            if reportRegistryFailure(failure.registryError, fingerprint: failure.fingerprint,
                                     context: "reloading after a registry change", notify: false) {
                reportedError = failure.registryError
                needsFullSync = true
            }
            replaceRegistryFileWatchAfterChange()
        } catch let registryError as ExternalNoteRegistryError {
            let fingerprint = try? vault.externalRegistryFingerprint()
            if reportRegistryFailure(registryError, fingerprint: fingerprint,
                                     context: "reloading after a registry change", notify: false) {
                reportedError = registryError
                needsFullSync = true
            }
            replaceRegistryFileWatchAfterChange()
        } catch {
            Self.logger.error("Unexpected error reloading the external registry: \(String(describing: error), privacy: .public)")
            let fingerprint = try? vault.externalRegistryFingerprint()
            if reportRegistryFailure(.unreadableRegistry, fingerprint: fingerprint,
                                     context: "reloading after a registry change", notify: false) {
                reportedError = .unreadableRegistry
                needsFullSync = true
            }
            replaceRegistryFileWatchAfterChange()
        }
    }

    private func replaceRegistryFileWatchAfterChange() {
        if let old = registryFileWatch {
            registryFileWatch = nil
            cancel(old)
        }
        guard reserveVnodeDescriptor() else {
            reportWatchIssue(
                key: "registry-watch",
                message: "The watcher descriptor limit prevented registry file vnode rearming; registry fingerprint polling is active."
            )
            return
        }
        let descriptors: ExternalNoteRegistry.WatchDescriptors?
        do {
            descriptors = try vault.openExternalRegistryWatchDescriptors()
        } catch {
            releaseVnodeDescriptor()
            reportWatchIssue(
                key: "registry-watch",
                message: "Could not rearm the external registry file vnode (\(String(describing: error))); registry fingerprint polling is active."
            )
            return
        }
        guard let descriptors else {
            releaseVnodeDescriptor()
            reportWatchIssue(
                key: "registry-watch",
                message: "External registry file vnode is unavailable after a change; registry fingerprint polling is active."
            )
            return
        }
        close(descriptors.parent)
        installRegistryFileWatch(descriptors.file)
        clearWatchIssue("registry-watch")
    }

    private func reconcileParentWatches(_ desiredParentPaths: [String: String], forceRearm: Set<String> = []) {
        var idsByParent: [String: Set<String>] = [:]
        for (id, path) in desiredParentPaths { idsByParent[path, default: []].insert(id) }

        for path in Array(parentWatches.keys) where idsByParent[path] == nil || forceRearm.contains(path) {
            if let watch = parentWatches.removeValue(forKey: path) { cancel(watch.vnode) }
        }

        let maximumParents = min(maximumParentVnodeDescriptors, maximumVnodeDescriptors)
        var selectedPaths = Set(parentWatches.keys.filter { idsByParent[$0] != nil })
        for path in idsByParent.keys.sorted() where selectedPaths.count < maximumParents {
            selectedPaths.insert(path)
        }
        for path in selectedPaths.sorted() {
            guard let ids = idsByParent[path] else { continue }
            if var current = parentWatches[path] {
                current.noteIDs = ids
                parentWatches[path] = current
            } else if let vnode = makeParentWatch(path: path) {
                parentWatches[path] = ParentWatch(vnode: vnode, noteIDs: ids)
            }
        }
        parentPathByID = desiredParentPaths
        updatePollingFallbackIDs()
    }

    private func cancel(_ watch: VnodeWatch) {
        watch.source.cancel()
    }

    fileprivate func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        guard stream != nil else { return }

        var notesChanged = Set<String>()
        var assetsChanged = Set<String>()
        var needsFullSync = false
        for event in events {
            let flags = event.flags
            if hasFlag(flags, kFSEventStreamEventFlagMustScanSubDirs)
                || hasFlag(flags, kFSEventStreamEventFlagRootChanged)
                || hasFlag(flags, kFSEventStreamEventFlagUserDropped)
                || hasFlag(flags, kFSEventStreamEventFlagKernelDropped) {
                needsFullSync = true
            }

            let eventURL = URL(fileURLWithPath: event.path).standardizedFileURL
            guard let relativePath = vault.relativePath(of: eventURL) else { continue }
            let components = relativePath.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }

            if isDirectory(flags),
               hasFlag(flags, kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved) {
                needsFullSync = true
            }

            guard isReportablePath(components) else { continue }
            if components[0].caseInsensitiveCompare(Vault.assetsDirectoryName) == .orderedSame {
                assetsChanged.insert(relativePath)
            } else if isMarkdown(name), !isDirectory(flags) {
                notesChanged.insert(relativePath)
            }
        }

        guard needsFullSync || !notesChanged.isEmpty || !assetsChanged.isEmpty else { return }
        onChange(VaultChange(
            notesChanged: notesChanged,
            assetsChanged: assetsChanged,
            needsFullSync: needsFullSync
        ))
    }

    private func isReportablePath(_ components: [String]) -> Bool {
        guard !components.isEmpty,
              !components.contains(where: { $0.hasPrefix(".") }),
              let name = components.last,
              !name.hasPrefix(".~"),
              !name.hasPrefix("~$"),
              name != ".DS_Store",
              !name.lowercased().hasSuffix(".swp"),
              !name.lowercased().hasSuffix(".icloud") else {
            return false
        }

        if components[0].caseInsensitiveCompare(Vault.assetsDirectoryName) == .orderedSame {
            return components.count >= 2
        }
        return isMarkdown(name)
    }

    private func isMarkdown(_ name: String) -> Bool {
        URL(fileURLWithPath: name).pathExtension.lowercased() == "md"
    }

    private func isDirectory(_ flags: FSEventStreamEventFlags) -> Bool {
        hasFlag(flags, kFSEventStreamEventFlagItemIsDir)
    }

    private func hasFlag(_ flags: FSEventStreamEventFlags, _ flag: Int) -> Bool {
        flags & FSEventStreamEventFlags(flag) != 0
    }
}

private let vaultWatcherCallback: FSEventStreamCallback = { _, clientInfo, eventCount, eventPaths, eventFlags, _ in
    guard let clientInfo else { return }
    let watcher = Unmanaged<VaultWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    var events: [(path: String, flags: FSEventStreamEventFlags)] = []
    events.reserveCapacity(eventCount)
    for index in 0..<eventCount {
        guard let path = paths[index] else { continue }
        events.append((String(cString: path), eventFlags[index]))
    }
    watcher.handle(events)
}
