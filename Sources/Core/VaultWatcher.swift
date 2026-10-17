import CoreServices
import Darwin
import Foundation

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

    // FSEvents is intentionally limited to the vault root.
    private var stream: FSEventStreamRef?
    private var streamGeneration = 0

    // All external maps and dispatch sources are confined to `queue`.
    private var registryGeneration: UInt64?
    private var externalLocationsByID: [String: VaultNoteLocation] = [:]
    private var externalFingerprints: [String: ExternalFileState] = [:]
    private var fileWatches: [String: VnodeWatch] = [:]
    private var parentWatches: [String: ParentWatch] = [:]
    private var parentPathByID: [String: String] = [:]

    // Registry parent events are common because app state also contains the
    // index and session state. A cheap exact-entry stat filters those events.
    private var registryParentWatch: VnodeWatch?
    private var registryFileWatch: VnodeWatch?
    private var registryFingerprint: ExternalNoteRegistry.Fingerprint?
    private var lastRegistryError: (fingerprint: ExternalNoteRegistry.Fingerprint?, error: ExternalNoteRegistryError)?
    private var lastReportedRegistryError: (fingerprint: ExternalNoteRegistry.Fingerprint?, error: ExternalNoteRegistryError)?

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
        guard let stream = createStartedVaultStream() else { return }
        self.stream = stream
        streamGeneration += 1

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
        parentPathByID.removeAll()
        registryGeneration = nil
        registryFingerprint = nil
        lastRegistryError = nil
        lastReportedRegistryError = nil
        pendingExternalIDs.removeAll()
        pendingExternalParents.removeAll()
        pendingFileRearmIDs.removeAll()
        pendingParentRearmPaths.removeAll()
        pendingRegistryCheck = false
        pendingRegistryParentRearm = false
        pendingExternalRecovery = false
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
            let error = failure.registryError
            let fingerprint = failure.fingerprint
            let shouldReport = failClosedRegistry(error, fingerprint: fingerprint, notify: true)
            if shouldReport {
                onChange(VaultChange(notesChanged: [], assetsChanged: [], needsFullSync: true,
                                     externalRegistryError: error))
            }
            replaceRegistryFileWatchAfterChange()
            return
        } catch let error as ExternalNoteRegistryError {
            let fingerprint = try? vault.externalRegistryFingerprint()
            let value = fingerprint ?? nil
            let shouldReport = failClosedRegistry(error, fingerprint: value, notify: true)
            if shouldReport {
                onChange(VaultChange(notesChanged: [], assetsChanged: [], needsFullSync: true,
                                     externalRegistryError: error))
            }
            replaceRegistryFileWatchAfterChange()
            return
        } catch {
            let fingerprint = try? vault.externalRegistryFingerprint()
            let typedError = ExternalNoteRegistryError.unreadableRegistry
            let value = fingerprint ?? nil
            let shouldReport = failClosedRegistry(typedError, fingerprint: value, notify: true)
            if shouldReport {
                onChange(VaultChange(notesChanged: [], assetsChanged: [], needsFullSync: true,
                                     externalRegistryError: typedError))
            }
            replaceRegistryFileWatchAfterChange()
            return
        }

        let generation = snapshot?.generation ?? 0
        let registryWasInvalid = lastRegistryError != nil
        guard registryGeneration != generation || registryWasInvalid else { return }
        guard let locations = try? vault.externalNoteLocations(snapshot: snapshot) else { return }

        registryGeneration = generation
        externalLocationsByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })
        externalFingerprints = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, .missing) })
        reconcileExternalWatches()
        if registryWasInvalid {
            lastRegistryError = nil
            lastReportedRegistryError = nil
            if reconcileOnChange {
                onChange(VaultChange(notesChanged: [], assetsChanged: [], needsFullSync: true,
                                     externalRegistryRecovered: true))
            }
        } else if reconcileOnChange {
            onChange(VaultChange(notesChanged: [], assetsChanged: [], needsFullSync: true))
        }
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

    private func reconcileExternalWatches() {
        let desiredParentPaths = parentPathsByNoteID()
        parentPathByID = desiredParentPaths

        var idsByParent: [String: Set<String>] = [:]
        for (id, path) in desiredParentPaths {
            idsByParent[path, default: []].insert(id)
        }

        for path in Array(parentWatches.keys) where idsByParent[path] == nil {
            if let watch = parentWatches.removeValue(forKey: path) { cancel(watch.vnode) }
        }

        for (path, ids) in idsByParent {
            if var current = parentWatches[path] {
                current.noteIDs = ids
                parentWatches[path] = current
            } else if let watch = makeParentWatch(path: path) {
                parentWatches[path] = ParentWatch(vnode: watch, noteIDs: ids)
            }
        }

        for id in externalLocationsByID.keys {
            refreshExternalFileWatch(id: id)
        }
        for id in Array(fileWatches.keys) where externalLocationsByID[id] == nil {
            if let watch = fileWatches.removeValue(forKey: id) { cancel(watch) }
        }
    }

    private func clearExternalWatchesOnQueue() {
        fileWatches.values.forEach(cancel)
        fileWatches.removeAll()
        parentWatches.values.forEach { cancel($0.vnode) }
        parentWatches.removeAll()
        externalLocationsByID.removeAll()
        externalFingerprints.removeAll()
        parentPathByID.removeAll()
        pendingExternalIDs.removeAll()
        pendingExternalParents.removeAll()
    }

    /// Select the immediate parent where it exists. If a registered path's
    /// parent was removed, watch its closest existing ancestor nonrecursively so
    /// the next directory creation can install the precise parent source.
    private func parentPathsByNoteID() -> [String: String] {
        var paths: [String: String] = [:]
        for (id, location) in externalLocationsByID {
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
        guard let descriptor = vault.openExternalWatchDirectory(relativePath: path) else { return nil }
        let token = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.handleExternalParentEvent(path: path, token: token) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return VnodeWatch(token: token, descriptor: descriptor, source: source)
    }

    private func refreshExternalFileWatch(id: String, forceRearm: Bool = false) {
        guard let location = externalLocationsByID[id] else { return }
        let snapshot: VaultFileSnapshot?
        do { snapshot = try vault.fileSnapshot(noteID: id, includingContents: false) }
        catch { snapshot = nil }
        let fingerprint = snapshot.map(FileFingerprint.init)
        externalFingerprints[id] = fingerprint.map(ExternalFileState.present) ?? .missing

        if !forceRearm,
           let existing = fileWatches[id],
           let fingerprint,
           fileIdentity(of: existing.descriptor) == fingerprint.identity {
            return
        }
        if let existing = fileWatches.removeValue(forKey: id) { cancel(existing) }

        guard fingerprint != nil,
              let descriptor = vault.openExternalWatchFile(location) else { return }
        let token = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.handleExternalFileEvent(id: id, token: token) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileWatches[id] = VnodeWatch(token: token, descriptor: descriptor, source: source)
    }

    private func fileIdentity(of descriptor: Int32) -> FileIdentity? {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { return nil }
        return FileIdentity(device: UInt64(attributes.st_dev), inode: UInt64(attributes.st_ino))
    }

    @discardableResult
    private func installRegistryWatchIfNeeded() -> Bool {
        guard registryParentWatch == nil,
              let descriptors = try? vault.openExternalRegistryWatchDescriptors() else { return false }

        let parentToken = UUID()
        let parentSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptors.parent,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        parentSource.setEventHandler { [weak self] in self?.handleRegistryEvent(token: parentToken, isFile: false) }
        parentSource.setCancelHandler { close(descriptors.parent) }
        parentSource.resume()
        registryParentWatch = VnodeWatch(token: parentToken, descriptor: descriptors.parent, source: parentSource)

        installRegistryFileWatch(descriptors.file)
        registryFingerprint = try? vault.externalRegistryFingerprint()
        return true
    }

    private func installRegistryFileWatch(_ descriptor: Int32?) {
        guard let descriptor else { return }
        let token = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.handleRegistryEvent(token: token, isFile: true) }
        source.setCancelHandler { close(descriptor) }
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
        fingerprint: ExternalNoteRegistry.Fingerprint?,
        notify: Bool
    ) -> Bool {
        registryFingerprint = fingerprint
        vault.invalidateExternalRegistryCache()
        clearExternalWatchesOnQueue()
        lastRegistryError = (fingerprint, error)
        guard notify,
              lastReportedRegistryError?.fingerprint != fingerprint || lastReportedRegistryError?.error != error else {
            return false
        }
        lastReportedRegistryError = (fingerprint, error)
        return true
    }

    private func enqueueExternalFlush(_ update: () -> Void) {
        update()
        scheduleExternalFlush()
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
            do { current = try vault.fileSnapshot(noteID: id, includingContents: false) }
            catch { current = nil }
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
                reconcileParentWatches(updatedParents, forceRearm: parentRearmPaths)
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
            handleUnreadableRegistry(registryError, needsFullSync: &needsFullSync, error: &reportedError)
            replaceRegistryFileWatchAfterChange()
            return
        } catch {
            handleUnreadableRegistry(.unreadableRegistry, needsFullSync: &needsFullSync, error: &reportedError)
            replaceRegistryFileWatchAfterChange()
            return
        }
        guard currentFingerprint != registryFingerprint || lastRegistryError != nil else { return }
        registryFingerprint = currentFingerprint
        vault.invalidateExternalRegistryCache()

        do {
            let snapshot = try loadStableRegistrySnapshot(forceReload: false)
            let generation = snapshot?.generation ?? 0
            let registryWasInvalid = lastRegistryError != nil
            if generation != registryGeneration || registryWasInvalid {
                guard let locations = try? vault.externalNoteLocations(snapshot: snapshot) else { return }
                registryGeneration = generation
                externalLocationsByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })
                externalFingerprints = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, .missing) })
                reconcileExternalWatches()
                needsFullSync = true
            }
            if registryWasInvalid {
                reportedError = nil
                pendingExternalRecovery = true
            }
            lastRegistryError = nil
            lastReportedRegistryError = nil
            replaceRegistryFileWatchAfterChange()
        } catch let failure as StableRegistryFailure {
            let registryError = failure.registryError
            if failClosedRegistry(registryError, fingerprint: failure.fingerprint, notify: true) {
                reportedError = registryError
                needsFullSync = true
            }
            replaceRegistryFileWatchAfterChange()
        } catch let registryError as ExternalNoteRegistryError {
            handleUnreadableRegistry(registryError, needsFullSync: &needsFullSync, error: &reportedError)
            replaceRegistryFileWatchAfterChange()
        } catch {
            handleUnreadableRegistry(.unreadableRegistry, needsFullSync: &needsFullSync, error: &reportedError)
            replaceRegistryFileWatchAfterChange()
        }
    }

    private func handleUnreadableRegistry(
        _ registryError: ExternalNoteRegistryError,
        needsFullSync: inout Bool,
        error: inout ExternalNoteRegistryError?
    ) {
        let fingerprint: ExternalNoteRegistry.Fingerprint? = nil
        if failClosedRegistry(registryError, fingerprint: fingerprint, notify: true) {
            error = registryError
            needsFullSync = true
        }
    }

    private func replaceRegistryFileWatchAfterChange() {
        if let old = registryFileWatch {
            registryFileWatch = nil
            cancel(old)
        }
        guard let descriptors = try? vault.openExternalRegistryWatchDescriptors() else { return }
        close(descriptors.parent)
        installRegistryFileWatch(descriptors.file)
    }

    private func reconcileParentWatches(_ desiredParentPaths: [String: String], forceRearm: Set<String> = []) {
        var idsByParent: [String: Set<String>] = [:]
        for (id, path) in desiredParentPaths { idsByParent[path, default: []].insert(id) }

        for path in Array(parentWatches.keys) where idsByParent[path] == nil {
            if let watch = parentWatches.removeValue(forKey: path) { cancel(watch.vnode) }
        }
        for (path, ids) in idsByParent {
            if forceRearm.contains(path), let old = parentWatches.removeValue(forKey: path) {
                cancel(old.vnode)
            }
            if var current = parentWatches[path] {
                current.noteIDs = ids
                parentWatches[path] = current
            } else if let vnode = makeParentWatch(path: path) {
                parentWatches[path] = ParentWatch(vnode: vnode, noteIDs: ids)
            }
        }
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
