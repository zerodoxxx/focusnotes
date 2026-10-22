import Darwin
import Foundation

/// Resolves the selected root through the OS once, then keeps a directory
/// descriptor as the trust anchor for all vault-relative operations.
final class VaultDirectoryAnchor: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32]
    private var rootDescriptor: Int32?
    private let pendingComponents: [String]
    private let initialError: Int32?

    init(url: URL) {
        var candidate = url.standardizedFileURL.path
        var missing: [String] = []
        var openedAncestor: Int32?
        var openedRoot: Int32?
        var errorCode: Int32?

        while true {
            let descriptor = candidate.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            if descriptor >= 0 {
                openedAncestor = descriptor
                if missing.isEmpty { openedRoot = descriptor }
                break
            }
            let failure = errno
            if failure != ENOENT && failure != ENOTDIR {
                errorCode = failure
                break
            }
            let current = URL(fileURLWithPath: candidate, isDirectory: true).standardizedFileURL
            let parent = current.deletingLastPathComponent()
            guard parent.path != candidate, current.lastPathComponent != "/" else {
                errorCode = failure
                break
            }
            missing.append(current.lastPathComponent)
            candidate = parent.path
        }

        descriptors = openedAncestor.map { [$0] } ?? []
        rootDescriptor = openedRoot
        pendingComponents = Array(missing.reversed())
        initialError = errorCode
    }

    deinit {
        for descriptor in descriptors.reversed() { close(descriptor) }
    }

    func prepareRoot() throws {
        let descriptor = try duplicateRoot(createIfMissing: true)
        close(descriptor)
    }

    func duplicateRoot(createIfMissing: Bool) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if let initialError { throw POSIXError(POSIXErrorCode(rawValue: initialError) ?? .EIO) }
        if let rootDescriptor {
            let duplicate = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return duplicate
        }
        guard var parent = descriptors.last else { throw POSIXError(.ENOENT) }

        var created: [Int32] = []
        do {
            for component in pendingComponents {
                var child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT {
                    guard createIfMissing else { throw POSIXError(.ENOENT) }
                    if mkdirat(parent, component, 0o700) != 0, errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var componentAttributes = stat()
                guard fstat(child, &componentAttributes) == 0 else {
                    close(child)
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard componentAttributes.st_mode & S_IFMT == S_IFDIR,
                      componentAttributes.st_uid == getuid() else {
                    close(child)
                    throw POSIXError(.EPERM)
                }
                created.append(child)
                parent = child
            }

            var attributes = stat()
            guard fstat(parent, &attributes) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_uid == getuid() else { throw POSIXError(.EPERM) }
            let duplicate = fcntl(parent, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            descriptors.append(contentsOf: created)
            rootDescriptor = parent
            return duplicate
        } catch {
            for descriptor in created.reversed() { close(descriptor) }
            throw error
        }
    }
}

public struct VaultFileSnapshot: Sendable {
    public let contents: Data?
    public let size: Int64
    public let device: UInt64
    public let inode: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public var modifiedAt: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
    }

    public var changedAt: Date {
        Date(timeIntervalSince1970: Double(changedSeconds) + Double(changedNanoseconds) / 1_000_000_000)
    }

    init(contents: Data?, attributes: stat) {
        self.contents = contents
        size = Int64(attributes.st_size)
        device = UInt64(truncatingIfNeeded: attributes.st_dev)
        inode = UInt64(truncatingIfNeeded: attributes.st_ino)
        modifiedSeconds = Int64(attributes.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(attributes.st_mtimespec.tv_nsec)
        changedSeconds = Int64(attributes.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(attributes.st_ctimespec.tv_nsec)
    }
}

public enum NoteKind: Codable, Sendable, Equatable {
    case inbox
    case session
    case note
}

public struct NoteRef: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var kind: NoteKind

    public init(url: URL, title: String, kind: NoteKind) {
        self.url = url
        self.title = title
        self.kind = kind
    }
}

/// Note identity for internal scans that need the managed path but not a title read.
struct VaultNoteFile: Sendable {
    let id: String
    let url: URL
    let kind: NoteKind
    let snapshot: VaultFileSnapshot?
}

public struct VaultNoteLocation: Sendable, Equatable {
    public let scope: NotePathScope
    /// Canonical path relative to the selected root, with no leading slash.
    public let relativePath: String
    public let url: URL
    /// Vault paths retain their historic relative-path identity. Home paths use
    /// their canonical absolute URL so they cannot collide with vault paths.
    public let id: String

    init(scope: NotePathScope, relativePath: String, url: URL) {
        self.scope = scope
        self.relativePath = relativePath
        self.url = url
        self.id = scope == .vault ? relativePath : url.standardizedFileURL.absoluteString
    }
}

struct VaultManagedLocation: Sendable {
    let note: VaultNoteLocation
    let anchor: VaultDirectoryAnchor

    var relativePath: String { note.relativePath }
    var scope: NotePathScope { note.scope }
    var url: URL { note.url }
}

/// The selected vault root contains notes, `Sessions/` and `assets/`.
/// Explicitly registered HOME notes are listed separately.
public struct Vault: Sendable {
    public static let inboxFileName = "Inbox.md"
    public static let inboxTitle = "Inbox"
    public static let sessionsDirectoryName = "Sessions"
    public static let assetsDirectoryName = "assets"

    public let root: URL
    let rootAnchor: VaultDirectoryAnchor
    let homeRoot: URL
    let homeAnchor: VaultDirectoryAnchor
    private let externalNoteRegistry: ExternalNoteRegistry?

    public init(root: URL, externalNoteRegistryURL: URL? = nil, homeDirectoryURL: URL? = nil) {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = resolved
        rootAnchor = VaultDirectoryAnchor(url: root)
        let resolvedHome = (homeDirectoryURL ?? FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL.resolvingSymlinksInPath()
        homeRoot = resolvedHome
        homeAnchor = VaultDirectoryAnchor(url: resolvedHome)
        externalNoteRegistry = externalNoteRegistryURL.map(ExternalNoteRegistry.init(url:))
    }

    public var inboxURL: URL {
        root.appendingPathComponent(Self.inboxFileName)
    }

    public var sessionsURL: URL {
        root.appendingPathComponent(Self.sessionsDirectoryName, isDirectory: true)
    }

    public var assetsURL: URL {
        root.appendingPathComponent(Self.assetsDirectoryName, isDirectory: true)
    }

    private func withExternalRegistryErrorMapping<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as ExternalNoteRegistryError {
            throw error
        } catch {
            throw ExternalNoteRegistryError.unreadableRegistry
        }
    }

    /// Creates the folder layout and `Inbox.md` if missing. Never overwrites existing files.
    public func prepare() throws {
        try rootAnchor.prepareRoot()
        try NoteFile.prepareManagedDirectory(Self.sessionsDirectoryName, in: rootAnchor)
        try NoteFile.prepareManagedDirectory(Self.assetsDirectoryName, in: rootAnchor)
        try NoteFile.prepareInbox(Data(CaptureFormat.noteHeader(title: Self.inboxTitle).utf8), in: rootAnchor)
    }

    /// Validates the optional external-note registry at startup so a damaged or
    /// newer-version registry can be surfaced before external notes are used.
    public func validateExternalNoteRegistry() throws {
        externalNoteRegistry?.invalidateCache()
        try withExternalRegistryErrorMapping {
            _ = try externalNoteRegistry?.snapshot()
        }
    }

    /// Lists Markdown notes recursively under the vault, except files inside `assets/`.
    /// Hidden files and directories are skipped.
    public func listNotes() throws -> [NoteRef] {
        try listNotes(externalRegistrySnapshot: externalRegistrySnapshot())
    }

    /// Lists notes using the registry snapshot already validated by the caller.
    /// Capture routing uses one snapshot for both its fail-closed check and list.
    func listNotes(externalRegistrySnapshot: ExternalNoteRegistry.Snapshot?) throws -> [NoteRef] {
        var refs: [NoteRef] = []
        for note in try markdownFilePaths() {
            guard let prefix = try? NoteFile.readManagedPrefix(4096, in: rootAnchor, relativePath: note.id) else { continue }
            refs.append(NoteRef(url: note.url, title: title(of: note.url, prefix: prefix), kind: note.kind))
        }
        for location in try externalNoteLocations(snapshot: externalRegistrySnapshot) {
            guard let prefix = try? NoteFile.readManagedPrefix(4096, in: homeAnchor, relativePath: location.relativePath) else { continue }
            refs.append(NoteRef(url: location.url, title: title(of: location.url, prefix: prefix), kind: .note))
        }
        return refs
    }

    /// Lists Markdown paths with no-follow metadata snapshots. Sync reuses these
    /// snapshots for unchanged files, opening a note only when its fingerprint changed.
    func listNoteFiles() throws -> [VaultNoteFile] {
        let vaultFiles = try markdownFilePaths(includeNoteMetadata: true).filter { $0.snapshot != nil }
        var externalFiles: [VaultNoteFile] = []
        for location in try externalNoteLocations() {
            do {
                guard let snapshot = try fileSnapshot(noteID: location.id, includingContents: false) else { continue }
                externalFiles.append(VaultNoteFile(id: location.id, url: location.url, kind: .note, snapshot: snapshot))
            } catch let error as POSIXError where
                error.code == .EACCES || error.code == .ELOOP || error.code == .ENOENT ||
                error.code == .ENOTDIR || error.code == .EPERM {
                continue
            }
        }
        return vaultFiles + externalFiles
    }

    /// `Stem.md`, then `Stem 2.md`, `Stem 3.md`, ... in the root, whichever is free first.
    public func uniqueNoteURL(forTitle title: String, excluding reserved: Set<URL> = []) -> URL {
        let stem = NoteTitle.fileStem(for: title)
        let fm = FileManager.default
        var candidate = root.appendingPathComponent("\(stem).md")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) || reserved.contains(candidate) {
            candidate = root.appendingPathComponent("\(stem) \(suffix).md")
            suffix += 1
        }
        return candidate
    }

    /// Resolves a note name to its canonical target. Relative names are rooted
    /// in the vault; names beginning with `/` are rooted in the user's home.
    /// Existing directory and file spellings are reused case-insensitively.
    public func resolveNoteName(_ rawName: String) throws -> VaultNoteLocation {
        try resolveNoteName(NoteTitle.pathName(for: rawName))
    }

    public func resolveNoteName(_ pathName: NotePathName) throws -> VaultNoteLocation {
        do {
            return try canonicalNoteLocation(for: pathName)
        } catch let error as POSIXError where Self.isUnavailableForResolution(error.code) {
            // Preserve validated intent for journaling when the selected root or
            // one of its existing parents cannot currently be enumerated. The
            // eventual write still uses the descriptor anchor and O_NOFOLLOW.
            return try deferredNoteLocation(for: pathName)
        }
    }

    /// Constructs a validated destination without inspecting the filesystem.
    /// This keeps capture journaling available when the selected volume is not
    /// mounted; the managed write remains responsible for creating parents.
    public func deferredNoteLocation(for pathName: NotePathName) throws -> VaultNoteLocation {
        try validate(pathName)
        let root = pathName.scope == .vault ? self.root : homeRoot
        let noteRelativePath = "\(pathName.relativePath).md"
        let url = append(relativePath: noteRelativePath, to: root)
        if pathName.scope == .home,
           let vaultRelativePath = relativePath(url, under: self.root) {
            try validateNoteLocation(scope: .vault, relativePath: vaultRelativePath)
            return VaultNoteLocation(
                scope: .vault,
                relativePath: vaultRelativePath,
                url: append(relativePath: vaultRelativePath, to: self.root)
            )
        }
        try validateNoteLocation(scope: pathName.scope, relativePath: noteRelativePath)
        return VaultNoteLocation(scope: pathName.scope, relativePath: noteRelativePath, url: url)
    }

    private func canonicalNoteLocation(for pathName: NotePathName) throws -> VaultNoteLocation {
        try validate(pathName)
        let root = pathName.scope == .vault ? self.root : homeRoot
        let anchor = pathName.scope == .vault ? rootAnchor : homeAnchor
        var components = pathName.components

        var parent: [String] = []
        for index in components.indices.dropLast() {
            let requested = components[index]
            guard let existing = try matchingName(requested, in: parent, anchor: anchor) else {
                // No deeper component can exist until this directory is created.
                parent.append(contentsOf: components[index..<(components.count - 1)])
                break
            }
            let candidate = (parent + [existing]).joined(separator: "/")
            do {
                _ = try NoteFile.listManagedDirectoryNames(in: anchor, relativePath: candidate)
            } catch let error as POSIXError where
                error.code == .ENOTDIR || error.code == .ELOOP || error.code == .EPERM {
                // Refuse a file or symlink in a parent position instead of
                // choosing a different case variant or following it.
                throw CocoaError(.fileWriteInvalidFileName)
            }
            parent.append(existing)
            components[index] = existing
        }

        let requestedFileName = "\(pathName.leafName).md"
        let existingFileName = try matchingName(requestedFileName, in: parent, anchor: anchor)
        let leafFileName = existingFileName ?? requestedFileName
        let canonicalRelativePath = (parent + [leafFileName]).joined(separator: "/")
        let candidateURL = append(relativePath: canonicalRelativePath, to: root)

        // A home-relative target inside the selected vault keeps the vault's
        // historic path identity and is secured by its more specific anchor.
        if pathName.scope == .home,
           let vaultRelativePath = relativePath(candidateURL, under: self.root) {
            try validateNoteLocation(scope: .vault, relativePath: vaultRelativePath)
            return VaultNoteLocation(
                scope: .vault,
                relativePath: vaultRelativePath,
                url: append(relativePath: vaultRelativePath, to: self.root)
            )
        }

        try validateNoteLocation(scope: pathName.scope, relativePath: canonicalRelativePath)
        return VaultNoteLocation(
            scope: pathName.scope,
            relativePath: canonicalRelativePath,
            url: candidateURL
        )
    }

    private func validate(_ pathName: NotePathName) throws {
        guard !pathName.components.isEmpty else { throw NotePathNameError.emptyPath }
        guard pathName.components.count <= NotePathName.maximumPathDepth else { throw NotePathNameError.tooDeep }
        guard pathName.relativePath.utf8.count <= NotePathName.maximumRelativePathBytes else {
            throw NotePathNameError.tooLong
        }
        guard pathName.components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
        }) else {
            throw NotePathNameError.invalidComponent
        }
    }

    private static func isUnavailableForResolution(_ code: POSIXErrorCode) -> Bool {
        code == .EACCES || code == .EAGAIN || code == .EIO || code == .ENOENT || code == .ENXIO
    }

    /// Resolves an already-selected note URL to the descriptor anchor and
    /// relative path used by all managed reads and writes.
    func managedLocation(of url: URL) throws -> VaultManagedLocation {
        guard url.isFileURL, (url.host == nil || url.host?.isEmpty == true),
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, !url.path.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let pathComponents = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard pathComponents.first == "",
              pathComponents.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let standardized = url.standardizedFileURL
        if let path = relativePath(standardized, under: root) {
            try validateNoteLocation(scope: .vault, relativePath: path)
            let note = VaultNoteLocation(scope: .vault, relativePath: path, url: append(relativePath: path, to: root))
            return VaultManagedLocation(note: note, anchor: rootAnchor)
        }
        if let path = relativePath(standardized, under: homeRoot) {
            try validateNoteLocation(scope: .home, relativePath: path)
            let note = VaultNoteLocation(scope: .home, relativePath: path, url: append(relativePath: path, to: homeRoot))
            return VaultManagedLocation(note: note, anchor: homeAnchor)
        }
        throw CocoaError(.fileWriteInvalidFileName)
    }

    /// Stable identifier for a managed note URL, scoped to the vault or HOME root.
    public func noteID(for url: URL) throws -> String {
        try managedLocation(of: url).note.id
    }

    private func matchingName(_ requested: String, in parent: [String], anchor: VaultDirectoryAnchor) throws -> String? {
        let parentPath = parent.joined(separator: "/")
        let names: [String]
        do {
            names = try NoteFile.listManagedDirectoryNames(in: anchor, relativePath: parentPath)
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
        let matches = names.filter { $0.caseInsensitiveCompare(requested) == .orderedSame }
        return matches.first(where: { $0 == requested }) ?? matches.sorted().first
    }

    private func relativePath(_ url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    private func validateManagedPath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private func validateNoteLocation(scope: NotePathScope, relativePath: String) throws {
        try validateManagedPath(relativePath)
        let components = relativePath.split(separator: "/")
        guard let leaf = components.last, !leaf.hasPrefix("~$") else {
            throw NotePathNameError.invalidComponent
        }
        if scope == .vault,
           let first = components.first,
           first.caseInsensitiveCompare(Self.assetsDirectoryName) == .orderedSame {
            throw NotePathNameError.invalidComponent
        }
    }

    private func append(relativePath: String, to root: URL) -> URL {
        relativePath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Resolves a vault-relative, slash-separated path such as `Sessions/2026-10-13 Foo.md`.
    public func url(forRelativePath path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Builds a vault URL from a validated relative path. Use this for persisted
    /// paths such as the active session destination; user and search IDs must use
    /// `resolveNoteName` and `noteLocation(forID:)` respectively.
    public func managedURL(forRelativePath path: String) throws -> URL {
        try validateManagedPath(path)
        let url = append(relativePath: path, to: root)
        let managed = try managedLocation(of: url)
        guard managed.scope == .vault, managed.relativePath == path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return managed.url
    }

    /// Vault-relative path of a URL inside the vault, or nil when it is outside.
    public func relativePath(of url: URL) -> String? {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Reads one vault-relative regular file from a single validated descriptor.
    /// Unsafe links, hardlinks, special files, and paths outside the vault fail.
    public func fileSnapshot(relativePath: String, includingContents: Bool = true) throws -> VaultFileSnapshot? {
        try NoteFile.readManagedSnapshot(in: rootAnchor, relativePath: relativePath,
                                         includingContents: includingContents)
    }

    /// Lexical path for a managed write. Symlinks are checked later through
    /// openat/O_NOFOLLOW; resolving them here would erase the path to validate.
    func writePath(of url: URL) throws -> String {
        guard url.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { throw CocoaError(.fileWriteInvalidFileName) }
        let relative = String(path.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relative.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
        return relative
    }

    func relativeDirectory(forWritePath path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Vault-relative folder of a note: `""` for root notes, `"Sessions"` for session notes.
    func relativeDirectory(of note: URL) -> String {
        let path = relativePath(of: note) ?? note.lastPathComponent
        return path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Returns explicitly registered HOME-relative notes. This is a bounded
    /// list: the app never scans HOME to discover external notes.
    func externalRegistrySnapshot() throws -> ExternalNoteRegistry.Snapshot? {
        try withExternalRegistryErrorMapping {
            return try externalNoteRegistry?.snapshot()
        }
    }

    func invalidateExternalRegistryCache() {
        externalNoteRegistry?.invalidateCache()
    }

    func openExternalRegistryWatchDescriptors() throws -> ExternalNoteRegistry.WatchDescriptors? {
        try externalNoteRegistry?.openWatchDescriptors()
    }

    func externalRegistryFingerprint() throws -> ExternalNoteRegistry.Fingerprint? {
        try withExternalRegistryErrorMapping {
            return try externalNoteRegistry?.currentFingerprint()
        }
    }

    func externalNoteLocations(snapshot: ExternalNoteRegistry.Snapshot? = nil) throws -> [VaultNoteLocation] {
        guard let externalNoteRegistry else { return [] }
        let registeredPaths = try withExternalRegistryErrorMapping {
            try (snapshot ?? externalNoteRegistry.snapshot()).paths
        }
        var locations: [VaultNoteLocation] = []
        for path in registeredPaths {
            let url = homeRoot.appendingPathComponent(path)
            guard let managed = try? managedLocation(of: url), managed.scope == .home else { continue }
            locations.append(managed.note)
        }
        return locations.sorted { $0.id < $1.id }
    }

    /// Opens a registered external note's immediate parent directory through
    /// the retained HOME anchor, rejecting symlinks at every path component.
    /// The returned descriptor is owned by the caller and suitable for vnode
    /// events without granting read access to the directory contents.
    func openExternalWatchDirectory(relativePath: String) -> Int32? {
        let components: [String]
        if relativePath.isEmpty {
            components = []
        } else {
            let values = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard values.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
                return nil
            }
            components = values
        }

        guard var current = try? homeAnchor.duplicateRoot(createIfMissing: false) else { return nil }
        for component in components {
            let next = component.withCString {
                openat(current, $0, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                close(current)
                return nil
            }
            var opened = stat()
            var named = stat()
            let isSafe = fstat(next, &opened) == 0 &&
                fstatat(current, component, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
                opened.st_mode & S_IFMT == S_IFDIR && opened.st_uid == getuid() &&
                opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
            close(current)
            guard isSafe else {
                close(next)
                return nil
            }
            current = next
        }

        // The anchor is opened read-only for descriptor-relative operations.
        // Reopen `.` as an event-only descriptor, including for a direct child
        // of HOME, so each vnode source has the narrowest practical access.
        let eventDescriptor = openat(current, ".", O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        close(current)
        return eventDescriptor >= 0 ? eventDescriptor : nil
    }

    /// Opens one registered external note without following symlinks. The
    /// caller owns the returned descriptor and closes it in the source's cancel
    /// handler.
    func openExternalWatchFile(_ location: VaultNoteLocation) -> Int32? {
        guard location.scope == .home else { return nil }
        let components = location.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = components.last,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            return nil
        }
        let parentPath = components.dropLast().joined(separator: "/")
        guard let parent = openExternalWatchDirectory(relativePath: parentPath) else { return nil }
        defer { close(parent) }

        let descriptor = name.withCString {
            openat(parent, $0, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        var opened = stat()
        var named = stat()
        let isSafe = fstat(descriptor, &opened) == 0 &&
            fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
            opened.st_mode & S_IFMT == S_IFREG && opened.st_uid == getuid() && opened.st_nlink == 1 &&
            opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
        guard isSafe else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Records an explicitly used external note before its append. Retrying a
    /// journaled save safely repeats this upsert.
    func registerExternalNote(_ location: VaultNoteLocation) throws {
        guard location.scope == .home else { return }
        guard let externalNoteRegistry else { throw POSIXError(.EPERM) }
        let managed = try managedLocation(of: location.url)
        guard managed.scope == .home,
              managed.relativePath == location.relativePath,
              managed.note.id == location.id else { throw POSIXError(.EPERM) }
        try externalNoteRegistry.register(managed.relativePath)
    }

    /// Resolves a search, pin, or browse identity. External IDs are accepted
    /// only when their exact HOME-relative path is in the explicit registry.
    public func noteLocation(forID id: String) throws -> VaultNoteLocation {
        let managed = try managedLocation(forNoteID: id)
        guard try NoteFile.readManagedSnapshot(in: managed.anchor, relativePath: managed.relativePath,
                                               includingContents: false) != nil else {
            throw POSIXError(.EPERM)
        }
        return managed.note
    }

    private func managedLocation(forNoteID id: String) throws -> VaultManagedLocation {
        if id.hasPrefix("file://") {
            guard let url = URL(string: id), url.isFileURL,
                  (url.host == nil || url.host?.isEmpty == true),
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.absoluteString == id else {
                throw POSIXError(.EPERM)
            }
            let managed = try managedLocation(of: url)
            guard managed.scope == .home,
                  try externalNoteRegistry?.paths().contains(managed.relativePath) == true else {
                throw POSIXError(.EPERM)
            }
            guard managed.note.id == id,
                  URL(fileURLWithPath: managed.relativePath).pathExtension.lowercased() == "md" else {
                throw POSIXError(.EPERM)
            }
            return managed
        }

        guard !id.isEmpty, !id.hasPrefix("/"), !id.contains("\0") else { throw POSIXError(.EPERM) }
        let url = root.appendingPathComponent(id)
        let managed = try managedLocation(of: url)
        guard managed.scope == .vault, managed.relativePath == id,
              managed.note.id == id,
              URL(fileURLWithPath: managed.relativePath).pathExtension.lowercased() == "md" else {
            throw POSIXError(.EPERM)
        }
        return managed
    }

    /// Reads a note identity through its scope's descriptor anchor. This is the
    /// common safe path for external-index refreshes and search consumers.
    func fileSnapshot(noteID: String, includingContents: Bool = true) throws -> VaultFileSnapshot? {
        let managed = try managedLocation(forNoteID: noteID)
        return try NoteFile.readManagedSnapshot(in: managed.anchor, relativePath: managed.relativePath,
                                               includingContents: includingContents)
    }

    private func noteKind(for relativePath: String) -> NoteKind {
        if relativePath == Self.inboxFileName { return .inbox }
        if relativePath.hasPrefix("\(Self.sessionsDirectoryName)/") { return .session }
        return .note
    }

    private func markdownFilePaths(in relativeDirectory: String = "",
                                   includeNoteMetadata: Bool = false) throws -> [VaultNoteFile] {
        let entries: [NoteFile.ManagedDirectoryEntry]
        do {
            entries = try NoteFile.listManagedDirectoryEntries(in: rootAnchor, relativePath: relativeDirectory,
                                                               includeNoteMetadata: includeNoteMetadata)
        } catch let error as POSIXError where error.code == .ENOENT {
            return []
        }
        return try markdownFilePaths(in: relativeDirectory, entries: entries, includeNoteMetadata: includeNoteMetadata)
    }

    private func markdownFilePaths(in relativeDirectory: String,
                                   entries: [NoteFile.ManagedDirectoryEntry],
                                   includeNoteMetadata: Bool) throws -> [VaultNoteFile] {
        var notes: [VaultNoteFile] = []
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            let name = entry.name
            guard !name.hasPrefix(".") else { continue }
            if relativeDirectory.isEmpty &&
                name.caseInsensitiveCompare(Self.assetsDirectoryName) == .orderedSame { continue }

            let path = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
            if entry.isDirectory {
                let children: [NoteFile.ManagedDirectoryEntry]
                do {
                    children = try NoteFile.listManagedDirectoryEntries(in: rootAnchor, relativePath: path,
                                                                       includeNoteMetadata: includeNoteMetadata)
                } catch let error as POSIXError where
                    error.code == .ENOTDIR || error.code == .ELOOP || error.code == .EPERM ||
                    error.code == .EACCES || error.code == .ENOENT {
                    continue
                }
                notes.append(contentsOf: try markdownFilePaths(in: path, entries: children,
                                                               includeNoteMetadata: includeNoteMetadata))
            } else if isMarkdownNoteName(name) {
                // Only the optional no-follow stat can authorize reuse of
                // metadata; full contents still require a descriptor read.
                let snapshot = includeNoteMetadata ? entry.noteSnapshot : nil
                notes.append(VaultNoteFile(id: path, url: root.appendingPathComponent(path),
                                           kind: noteKind(for: path), snapshot: snapshot))
            }
        }
        return notes.sorted { $0.id < $1.id }
    }

    private func isMarkdownNoteName(_ name: String) -> Bool {
        !name.hasPrefix("~$") && URL(fileURLWithPath: name).pathExtension.lowercased() == "md"
    }

    /// Title from a leading `# ` line within the first 4 KB, else the file stem.
    private func title(of url: URL, prefix: Data) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let lineData = prefix.prefix { $0 != 0x0A }
        var firstLine = String(decoding: lineData, as: UTF8.self)
        if firstLine.hasPrefix("\u{FEFF}") {
            firstLine.removeFirst()
        }
        guard firstLine.hasPrefix("# ") else { return stem }
        let title = NoteTitle.cleanTitle(String(firstLine.dropFirst(2)))
        return title.isEmpty ? stem : title
    }
}
