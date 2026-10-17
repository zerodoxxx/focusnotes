import Darwin
import Foundation

public enum ExternalNoteRegistryError: Error, LocalizedError, Sendable, Equatable {
    case malformedRegistry
    case unsupportedVersion(Int)
    case unreadableRegistry

    public var errorDescription: String? {
        switch self {
        case .malformedRegistry:
            return "The external note registry is malformed and was left unchanged."
        case .unsupportedVersion(let version):
            return "The external note registry uses unsupported version \(version) and was left unchanged."
        case .unreadableRegistry:
            return "The external note registry could not be read safely and was left unchanged."
        }
    }
}

/// Persists only HOME-relative notes explicitly selected by the user.
/// It intentionally does not discover or scan arbitrary files under HOME.
final class ExternalNoteRegistry: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        let generation: UInt64
        let paths: [String]
    }

    struct WatchDescriptors: Sendable {
        /// The safe registry file descriptor, or nil if it is missing or unsafe.
        let file: Int32?
        /// The registry's immediate parent directory descriptor.
        let parent: Int32
    }

    struct Fingerprint: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private struct Store: Codable {
        var version = 1
        var paths: [String] = []
    }

    private let anchor: VaultDirectoryAnchor
    private let name: String
    private let lockName: String
    private let cacheLock = NSLock()
    private var cachedSnapshot: Snapshot?
    private var cacheIsValid = false
    private var cacheRevision: UInt64 = 0

    init(url: URL) {
        let standardized = url.standardizedFileURL
        anchor = VaultDirectoryAnchor(url: standardized.deletingLastPathComponent())
        name = standardized.lastPathComponent
        lockName = ".\(standardized.lastPathComponent).lock"
    }

    func paths() throws -> [String] {
        try snapshot().paths
    }

    /// Returns a validated in-memory path set. Watchers can compare generations
    /// and invalidate after an event from another process without rereading on
    /// every filesystem event.
    func snapshot() throws -> Snapshot {
        while true {
            cacheLock.lock()
            if cacheIsValid, let cachedSnapshot {
                cacheLock.unlock()
                return cachedSnapshot
            }
            let observedRevision = cacheRevision
            let previous = cachedSnapshot
            cacheLock.unlock()

            let paths: [String]
            do {
                paths = try withLockedDirectory(createIfMissing: true) { root in
                    try readStore(in: root).paths
                }
            } catch let error as ExternalNoteRegistryError {
                throw error
            } catch {
                throw ExternalNoteRegistryError.unreadableRegistry
            }

            cacheLock.lock()
            if cacheIsValid, let cachedSnapshot {
                cacheLock.unlock()
                return cachedSnapshot
            }
            guard cacheRevision == observedRevision else {
                cacheLock.unlock()
                continue
            }
            let generation = generation(afterLoading: paths, comparedTo: previous)
            let loaded = Snapshot(generation: generation, paths: paths)
            cachedSnapshot = loaded
            cacheIsValid = true
            cacheLock.unlock()
            return loaded
        }
    }

    /// Marks the snapshot stale after an external registry-file or parent event.
    func invalidateCache() {
        cacheLock.lock()
        cacheIsValid = false
        cacheRevision &+= 1
        cacheLock.unlock()
    }

    /// Opens only the registry vnode and its immediate parent through the
    /// retained directory anchor. The caller owns and must close both handles.
    func openWatchDescriptors() throws -> WatchDescriptors? {
        guard Self.isSafeFileName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let root: Int32
        do {
            root = try anchor.duplicateRoot(createIfMissing: false)
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
        let file = openat(root, name, O_EVTONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file < 0, errno == ENOENT || errno == ELOOP {
            return WatchDescriptors(file: nil, parent: root)
        }
        if file < 0 {
            let savedError = Self.posixError()
            close(root)
            throw savedError
        }
        if file >= 0 {
            do {
                _ = try Self.validateRegularFile(file)
            } catch let error as POSIXError where error.code == .EPERM {
                close(file)
                return WatchDescriptors(file: nil, parent: root)
            } catch {
                close(file)
                close(root)
                throw error
            }
        }
        return WatchDescriptors(file: file >= 0 ? file : nil, parent: root)
    }

    /// Reads the exact registry entry's metadata without following a symlink.
    /// Parent vnode watchers can use it to ignore unrelated writes before
    /// invalidating the cached JSON snapshot.
    func currentFingerprint() throws -> Fingerprint? {
        guard Self.isSafeFileName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let root: Int32
        do {
            root = try anchor.duplicateRoot(createIfMissing: false)
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
        defer { close(root) }

        var attributes = stat()
        guard fstatat(root, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.posixError()
        }
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == getuid(), attributes.st_nlink == 1 else {
            throw POSIXError(.EPERM)
        }
        return Fingerprint(
            device: UInt64(attributes.st_dev),
            inode: UInt64(attributes.st_ino),
            size: Int64(attributes.st_size),
            modifiedSeconds: Int64(attributes.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(attributes.st_mtimespec.tv_nsec),
            changedSeconds: Int64(attributes.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(attributes.st_ctimespec.tv_nsec)
        )
    }

    /// Idempotently records a validated HOME-relative Markdown path.
    func register(_ path: String) throws {
        guard Self.isSafeRelativeMarkdownPath(path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        do {
            try withLockedDirectory(createIfMissing: true) { root in
                var store = try readStore(in: root)
                let addedPath = !store.paths.contains(path)
                if addedPath {
                    store.paths.append(path)
                    store.paths.sort()
                    try writeStore(store, in: root)
                }
                updateCache(paths: store.paths, addedPath: addedPath)
            }
        } catch let error as ExternalNoteRegistryError {
            throw error
        } catch {
            throw ExternalNoteRegistryError.unreadableRegistry
        }
    }

    private func withLockedDirectory<T>(createIfMissing: Bool, _ body: (Int32) throws -> T) throws -> T {
        guard Self.isSafeFileName(name), Self.isSafeFileName(lockName) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let root = try anchor.duplicateRoot(createIfMissing: createIfMissing)
        defer { close(root) }

        let lockDescriptor = openat(root, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockDescriptor >= 0 else { throw Self.posixError() }
        defer { close(lockDescriptor) }
        _ = try Self.validateRegularFile(lockDescriptor)
        guard flock(lockDescriptor, LOCK_EX) == 0 else { throw Self.posixError() }
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        return try body(root)
    }

    private func readStore(in root: Int32) throws -> Store {
        let descriptor = openat(root, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return Store() }
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { close(descriptor) }

        let initial = try Self.validateRegularFile(descriptor)
        guard initial.st_size <= 8 * 1024 * 1024 else { throw POSIXError(.EFBIG) }
        var bytes = Data()
        bytes.reserveCapacity(Int(initial.st_size))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.posixError()
            }
            if count == 0 { break }
            bytes.append(contentsOf: chunk.prefix(count))
            guard bytes.count <= 8 * 1024 * 1024 else { throw POSIXError(.EFBIG) }
        }
        let final = try Self.validateRegularFile(descriptor)
        guard initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
              try Self.isCurrent(name, descriptor: descriptor, in: root) else {
            throw POSIXError(.EAGAIN)
        }

        do {
            let decoded = try JSONDecoder().decode(Store.self, from: bytes)
            guard decoded.version == 1 else { throw ExternalNoteRegistryError.unsupportedVersion(decoded.version) }
            return Store(version: 1, paths: Array(Set(decoded.paths.filter(Self.isSafeRelativeMarkdownPath))).sorted())
        } catch is DecodingError {
            throw ExternalNoteRegistryError.malformedRegistry
        }
    }

    private func updateCache(paths: [String], addedPath: Bool) {
        cacheLock.lock()
        let changed = cachedSnapshot.map { $0.paths != paths } ?? false
        let generation = cachedSnapshot.map { $0.generation &+ (changed ? 1 : 0) } ?? (addedPath ? 1 : 0)
        cachedSnapshot = Snapshot(generation: generation, paths: paths)
        cacheIsValid = true
        cacheLock.unlock()
    }

    private func generation(afterLoading paths: [String], comparedTo previous: Snapshot?) -> UInt64 {
        guard let previous else { return 0 }
        return previous.generation &+ (previous.paths == paths ? 0 : 1)
    }

    private func writeStore(_ store: Store, in root: Int32) throws {
        let data = try JSONEncoder().encode(store)
        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let descriptor = openat(root, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer {
            close(descriptor)
            _ = unlinkat(root, temporaryName, 0)
        }
        _ = try Self.validateRegularFile(descriptor)
        try Self.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw Self.posixError() }
        guard renameat(root, temporaryName, root, name) == 0 else { throw Self.posixError() }
        _ = fsync(root)
    }

    private static func validateRegularFile(_ descriptor: Int32) throws -> stat {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw posixError() }
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == getuid(), attributes.st_nlink == 1 else {
            throw POSIXError(.EPERM)
        }
        return attributes
    }

    private static func isCurrent(_ name: String, descriptor: Int32, in root: Int32) throws -> Bool {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw posixError() }
        var current = stat()
        guard fstatat(root, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw posixError()
        }
        return current.st_mode & S_IFMT == S_IFREG && current.st_uid == getuid() && current.st_nlink == 1 &&
            current.st_dev == opened.st_dev && current.st_ino == opened.st_ino
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }

    private static func isSafeRelativeMarkdownPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\0"),
              URL(fileURLWithPath: path).pathExtension.lowercased() == "md" else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." &&
                !component.contains("\\") && !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
