import Darwin
import Foundation
import os

/// O_APPEND protects capture writes. Session renames replace a complete snapshot atomically.
enum NoteFile {
    private static let attempts = 4
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev", category: "NoteFile")

    struct ManagedDirectoryEntry: Sendable {
        let name: String
        let isDirectory: Bool
        let noteSnapshot: VaultFileSnapshot?
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
        }
    }

    /// Keeps every directory descriptor in the path open so writes stay anchored
    /// even if a path component is replaced while the operation is in progress.
    private final class DirectoryChain {
        let descriptors: [Int32]
        let names: [String?]
        let identities: [FileIdentity]

        init(descriptors: [Int32], names: [String?], identities: [FileIdentity]) {
            self.descriptors = descriptors
            self.names = names
            self.identities = identities
        }

        deinit {
            for descriptor in descriptors.reversed() { close(descriptor) }
        }

        var descriptor: Int32 { descriptors[descriptors.count - 1] }
    }

    private struct FileLocation {
        let directories: DirectoryChain
        let name: String

        var parentDescriptor: Int32 { directories.descriptor }
    }

    /// Creates the app-managed folders through directory descriptors. The
    /// root anchor follows any selected-root symlink when it opens the root;
    /// links beneath that root are rejected.
    static func prepareManagedDirectory(_ relativePath: String, in root: VaultDirectoryAnchor) throws {
        _ = try openDirectory(root: root, components: pathComponents(relativePath), create: true)
    }

    static func listManagedDirectoryNames(in root: VaultDirectoryAnchor, relativePath: String) throws -> [String] {
        let components = relativePath.isEmpty ? [] : try pathComponents(relativePath)
        let directories = try openDirectory(root: root, components: components, create: false)
        // openat(".") creates an independent open-file description, so readdir
        // does not advance the retained root or directory descriptor offsets.
        let descriptor = openat(directories.descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            throw posixError()
        }
        defer { closedir(stream) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError() }
                break
            }
            var value = entry.pointee
            let capacity = MemoryLayout.size(ofValue: value.d_name)
            let name = withUnsafePointer(to: &value.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        guard try isCurrent(directories) else { throw POSIXError(.EAGAIN) }
        return names
    }

    /// Lists names and classifies directories from the same validated descriptor.
    /// Known `d_type` values avoid opening every regular note as a candidate
    /// directory; unknown values fall back to descriptor-relative `fstatat`.
    /// When requested, eligible Markdown leaves also carry a no-follow metadata
    /// snapshot so callers can skip reopening unchanged files one at a time.
    static func listManagedDirectoryEntries(in root: VaultDirectoryAnchor,
                                            relativePath: String,
                                            includeNoteMetadata: Bool = false) throws -> [ManagedDirectoryEntry] {
        let components = relativePath.isEmpty ? [] : try pathComponents(relativePath)
        let directories = try openDirectory(root: root, components: components, create: false)
        let descriptor = openat(directories.descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            throw posixError()
        }
        defer { closedir(stream) }

        var entries: [ManagedDirectoryEntry] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError() }
                break
            }
            var value = entry.pointee
            let capacity = MemoryLayout.size(ofValue: value.d_name)
            let name = withUnsafePointer(to: &value.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }

            let isDirectory: Bool
            if value.d_type == DT_DIR {
                isDirectory = true
            } else if value.d_type == DT_UNKNOWN {
                var attributes = stat()
                guard fstatat(directories.descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    throw posixError()
                }
                isDirectory = attributes.st_mode & S_IFMT == S_IFDIR
            } else {
                isDirectory = false
            }

            var noteSnapshot: VaultFileSnapshot? = nil
            if includeNoteMetadata, !isDirectory, !name.hasPrefix("."),
               !name.hasPrefix("~$"), URL(fileURLWithPath: name).pathExtension.lowercased() == "md" {
                noteSnapshot = try managedNoteMetadata(in: directories.descriptor, name: name)
            }
            entries.append(ManagedDirectoryEntry(name: name, isDirectory: isDirectory, noteSnapshot: noteSnapshot))
        }
        guard try isCurrent(directories) else { throw POSIXError(.EAGAIN) }
        return entries
    }

    private static func managedNoteMetadata(in parent: Int32, name: String) throws -> VaultFileSnapshot? {
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == EACCES || errno == ELOOP || errno == ENOENT || errno == ENOTDIR || errno == EPERM {
                return nil
            }
            throw posixError()
        }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw posixError() }
        guard opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == getuid(), opened.st_nlink == 1 else { return nil }

        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == EACCES || errno == ELOOP || errno == ENOENT || errno == ENOTDIR || errno == EPERM {
                return nil
            }
            throw posixError()
        }
        guard current.st_mode & S_IFMT == S_IFREG,
              current.st_uid == getuid(), current.st_nlink == 1,
              FileIdentity(opened) == FileIdentity(current) else {
            throw POSIXError(.EAGAIN)
        }
        guard opened.st_size == current.st_size,
              opened.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec,
              opened.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec,
              opened.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec,
              opened.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec else {
            throw POSIXError(.EAGAIN)
        }
        return VaultFileSnapshot(contents: nil, attributes: opened)
    }

    /// Reads only a bounded prefix from a regular, app-owned, single-link note.
    /// O_NONBLOCK makes an attacker-created FIFO fail the type check without
    /// hanging note enumeration.
    static func readManagedPrefix(_ count: Int, in root: VaultDirectoryAnchor, relativePath: String) throws -> Data? {
        let location = try openLocation(root: root, relativePath: relativePath)
        guard try isCurrent(location.directories) else { return nil }
        let descriptor = openat(location.parentDescriptor, location.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        defer { close(descriptor) }
        _ = try validateManagedFile(descriptor)
        guard try isCurrent(descriptor, at: location) else { return nil }
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try reader.read(upToCount: count) ?? Data()
        guard try isCurrent(descriptor, at: location) else { return nil }
        _ = try validateManagedFile(descriptor)
        return data
    }

    static func readManagedSnapshot(in root: VaultDirectoryAnchor, relativePath: String,
                                    includingContents: Bool) throws -> VaultFileSnapshot? {
        let location = try openLocation(root: root, relativePath: relativePath)
        guard try isCurrent(location.directories) else { return nil }
        let descriptor = openat(location.parentDescriptor, location.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        defer { close(descriptor) }
        let initialAttributes = try validateManagedFile(descriptor)
        guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
        let initial = try fingerprint(descriptor)
        let contents = includingContents ? try readAll(descriptor) : nil
        let finalAttributes = try validateManagedFile(descriptor)
        guard try isCurrent(descriptor, at: location), try fingerprint(descriptor) == initial,
              FileIdentity(initialAttributes) == FileIdentity(finalAttributes) else { throw POSIXError(.EAGAIN) }
        return VaultFileSnapshot(contents: contents, attributes: finalAttributes)
    }

    private static func pathComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw POSIXError(.EPERM)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw POSIXError(.EPERM)
        }
        return components
    }

    private static func openDirectory(root: VaultDirectoryAnchor, components: [String], create: Bool) throws -> DirectoryChain {
        var descriptors = [try root.duplicateRoot(createIfMissing: create)]
        var names: [String?] = [nil]
        var identities: [FileIdentity] = []
        var rootAttributes = stat()
        guard fstat(descriptors[0], &rootAttributes) == 0 else { close(descriptors[0]); throw posixError() }
        guard rootAttributes.st_mode & S_IFMT == S_IFDIR, rootAttributes.st_uid == getuid() else {
            close(descriptors[0])
            throw POSIXError(.EPERM)
        }
        identities.append(FileIdentity(rootAttributes))
        do {
            for component in components {
                var next = openat(descriptors[descriptors.count - 1], component,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    if mkdirat(descriptors[descriptors.count - 1], component, 0o700) != 0, errno != EEXIST {
                        throw posixError()
                    }
                    next = openat(descriptors[descriptors.count - 1], component,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    throw posixError()
                }
                var attributes = stat()
                guard fstat(next, &attributes) == 0 else { close(next); throw posixError() }
                guard attributes.st_mode & S_IFMT == S_IFDIR else { close(next); throw POSIXError(.ENOTDIR) }
                descriptors.append(next)
                names.append(component)
                identities.append(FileIdentity(attributes))
            }

            for descriptor in descriptors.dropFirst() {
                var attributes = stat()
                guard fstat(descriptor, &attributes) == 0 else { throw posixError() }
                guard attributes.st_uid == getuid() else { throw POSIXError(.EPERM) }
            }
            let chain = DirectoryChain(descriptors: descriptors, names: names, identities: identities)
            descriptors.removeAll()
            guard try isCurrent(chain) else { throw POSIXError(.EAGAIN) }
            return chain
        } catch {
            for descriptor in descriptors.reversed() { close(descriptor) }
            throw error
        }
    }

    private static func openLocation(root: VaultDirectoryAnchor, relativePath: String, createDirectories: Bool = false) throws -> FileLocation {
        let components = try pathComponents(relativePath)
        let directoryComponents = Array(components.dropLast())
        let directories = try openDirectory(root: root, components: directoryComponents, create: createDirectories)
        return FileLocation(directories: directories, name: components[components.count - 1])
    }

    private static func isCurrent(_ directories: DirectoryChain) throws -> Bool {
        guard directories.descriptors.count == directories.names.count,
              directories.descriptors.count == directories.identities.count else { return false }
        for index in directories.descriptors.indices {
            var opened = stat()
            guard fstat(directories.descriptors[index], &opened) == 0 else { throw posixError() }
            guard FileIdentity(opened) == directories.identities[index] else { return false }
            if index == 0 { continue }
            guard let name = directories.names[index] else { return false }
            var current = stat()
            guard fstatat(directories.descriptors[index - 1], name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return false }
                throw posixError()
            }
            guard current.st_mode & S_IFMT == S_IFDIR, FileIdentity(current) == directories.identities[index] else { return false }
        }
        return true
    }

    private static func isCurrent(_ descriptor: Int32, at location: FileLocation) throws -> Bool {
        guard try isCurrent(location.directories) else { return false }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw posixError() }
        var current = stat()
        guard fstatat(location.parentDescriptor, location.name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw posixError()
        }
        return current.st_mode & S_IFMT == S_IFREG && FileIdentity(opened) == FileIdentity(current)
    }

    private static func validateManagedFile(_ descriptor: Int32) throws -> stat {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw posixError() }
        guard attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_nlink == 1 else { throw POSIXError(.EPERM) }
        return attributes
    }

    /// Inbox is app-managed: migrate legacy broad modes without following a
    /// symlink or changing a hard-linked file outside the vault.
    static func prepareInbox(_ data: Data, in root: VaultDirectoryAnchor) throws {
        let location = try openLocation(root: root, relativePath: Vault.inboxFileName)
        guard try isCurrent(location.directories) else { throw POSIXError(.EAGAIN) }
        var created = true
        var descriptor = openat(location.parentDescriptor, location.name,
                                O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor < 0, errno == EEXIST {
            created = false
            descriptor = openat(location.parentDescriptor, location.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError() }
        try withLockedDescriptor(descriptor) {
            let attributes = try validateManagedFile(descriptor)
            guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
            let privateMode = attributes.st_mode & 0o700
            if attributes.st_mode & 0o7777 != privateMode {
                guard fchmod(descriptor, privateMode) == 0 else { throw posixError() }
            }
            if created {
                _ = try validateManagedFile(descriptor)
                guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
                try writeAll(data, to: descriptor)
            }
            // The directory descriptor anchors both open operations. A rename or
            // replacement during preparation must not be reported as success.
            _ = try validateManagedFile(descriptor)
            guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
        }
    }

    /// Advisory state owned by the serial NoteWriter actor, never shared between
    /// writers. Every lookup still occurs under the inode's append lock.
    struct AppendCache {
        private var entries: [String: AppendState] = [:]
        private var order: [String] = []
        private(set) var fullScans = 0
        static let fileLimit = 8
        static let markerLimit = 50_000
        static let sourceByteLimit = 65_536

        var fileCount: Int { entries.count }

        mutating func take(_ path: String, matching fingerprint: Fingerprint) -> AppendState? {
            order.removeAll { $0 == path }
            guard let state = entries.removeValue(forKey: path), state.fingerprint == fingerprint else { return nil }
            return state
        }

        mutating func recordScan() { fullScans += 1 }

        mutating func store(_ state: AppendState, at path: String) {
            guard state.markerCount <= Self.markerLimit,
                  state.source.retainedByteCount <= Self.sourceByteLimit else { return }
            while order.count >= Self.fileLimit { entries.removeValue(forKey: order.removeFirst()) }
            while entries.values.reduce(state.markerCount, { $0 + $1.markerCount }) > Self.markerLimit,
                  !order.isEmpty { entries.removeValue(forKey: order.removeFirst()) }
            entries[path] = state
            order.append(path)
        }
    }

    struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: timespec
        let changed: timespec

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size &&
                lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
                lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    struct AppendState {
        var fingerprint: Fingerprint
        var markers: [String: [UInt64]] = [:]
        var markerCount = 0
        var source = NoteParser.SourceHeadingState()

        mutating func consume(_ data: Data, at offset: UInt64, calendar: Calendar) {
            // UUID prefixes also locate legacy markers and interrupted metadata.
            // A candidate is only accepted after its entire requested block is read.
            for prefix in ["<!-- capture:", "<!-- note:", "<!-- subheading:"] {
                let needle = Data(prefix.utf8)
                var start = data.startIndex
                while start < data.endIndex,
                      let range = data.range(of: needle, in: start..<data.endIndex) {
                    let end = range.upperBound + 36
                    if end <= data.endIndex {
                        let identity = String(decoding: data[range.lowerBound..<end], as: UTF8.self)
                        if UUID(uuidString: String(identity.suffix(36))) != nil {
                            markers[identity, default: []].append(offset + UInt64(range.lowerBound))
                            markerCount += 1
                            if markerCount > AppendCache.markerLimit { break }
                        }
                    }
                    start = range.upperBound
                }
            }
            source.consume(String(decoding: data, as: UTF8.self), calendar: calendar)
        }
    }

    static func create(_ data: Data, in root: VaultDirectoryAnchor, relativePath: String, requireNew: Bool = false) throws {
        let location = try openLocation(root: root, relativePath: relativePath)
        guard try isCurrent(location.directories) else { throw POSIXError(.EAGAIN) }
        var descriptor = openat(location.parentDescriptor, location.name,
                                O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor < 0, errno == EEXIST, !requireNew {
            descriptor = openat(location.parentDescriptor, location.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw posixError() }
            try withLockedDescriptor(descriptor) {
                _ = try validateManagedFile(descriptor)
                guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
            }
            return
        }
        guard descriptor >= 0 else { throw posixError() }
        try withLockedDescriptor(descriptor) {
            let attributes = try validateManagedFile(descriptor)
            guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
            if attributes.st_size == 0 {
                _ = try validateManagedFile(descriptor)
                guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
                try writeAll(data, to: descriptor)
            }
            _ = try validateManagedFile(descriptor)
            guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
        }
    }

    /// Rewrites a session heading without truncating the original inode, then
    /// moves it within its existing directory without replacing another name.
    /// Keep the old inode at the temporary name until the exclusive move succeeds
    /// so a collision can restore the original bytes atomically.
    static func renameSession(in root: VaultDirectoryAnchor, relativePath: String,
                              newName: String, title: String,
                              beforeInstall: @Sendable (SessionRenameStage) throws -> Void,
                              afterSwap: (@Sendable () throws -> Void)? = nil) throws {
        let location = try openLocation(root: root, relativePath: relativePath)
        guard !newName.isEmpty, !newName.contains("/"), !newName.contains("\\"),
              !newName.contains("\0"), newName != ".", newName != ".." else { throw POSIXError(.EPERM) }
        guard try isCurrent(location.directories) else { throw POSIXError(.EAGAIN) }
        // Cooperating renames serialize their folded-name checks as well as the
        // kernel's exclusive destination check (also needed on case-sensitive volumes).
        guard flock(location.parentDescriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(location.parentDescriptor, LOCK_UN) }
        let descriptor = openat(location.parentDescriptor, location.name,
                                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        try withLockedDescriptor(descriptor) {
            _ = try validateManagedFile(descriptor)
            guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
            let initial = try fingerprint(descriptor)
            let contents = try readAll(descriptor)
            let rewritten = try sessionHeading(title, replacing: contents)
            let directory = (relativePath as NSString).deletingLastPathComponent
            if newName != location.name, newName.caseInsensitiveCompare(location.name) == .orderedSame {
                throw SessionStoreError.caseOnlyRename
            }
            func collides(_ names: [String]) -> Bool {
                names.contains { $0 != location.name && $0.caseInsensitiveCompare(newName) == .orderedSame }
            }
            guard !collides(try listManagedDirectoryNames(in: root, relativePath: directory)) else { throw POSIXError(.EEXIST) }
            let temporaryName = ".session-\(UUID().uuidString).pending"
            let temporary = FileLocation(directories: location.directories, name: temporaryName)
            let temporaryDescriptor = openat(location.parentDescriptor, temporaryName,
                                             O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard temporaryDescriptor >= 0 else { throw posixError() }
            var retainTemporary = false
            defer { if !retainTemporary { _ = unlinkat(location.parentDescriptor, temporaryName, 0) } }
            try withLockedDescriptor(temporaryDescriptor) {
                _ = try validateManagedFile(temporaryDescriptor)
                try writeAll(rewritten, to: temporaryDescriptor)
                guard fsync(temporaryDescriptor) == 0 else { throw posixError() }
                let staged = try validateManagedFile(temporaryDescriptor)
                try beforeInstall(SessionRenameStage(
                    original: ManagedFileIdentity(device: UInt64(truncatingIfNeeded: initial.device), inode: UInt64(truncatingIfNeeded: initial.inode)),
                    installed: ManagedFileIdentity(device: UInt64(truncatingIfNeeded: staged.st_dev), inode: UInt64(truncatingIfNeeded: staged.st_ino)),
                    temporaryName: temporaryName))
                let finalNames = try listManagedDirectoryNames(in: root, relativePath: directory)
                guard !collides(finalNames) else {
                    throw POSIXError(.EEXIST)
                }
                _ = try validateManagedFile(descriptor)
                _ = try validateManagedFile(temporaryDescriptor)
                guard try isCurrent(descriptor, at: location), try fingerprint(descriptor) == initial,
                      try isCurrent(temporaryDescriptor, at: temporary) else { throw POSIXError(.EAGAIN) }
                guard renameatx_np(location.parentDescriptor, temporaryName,
                                   location.parentDescriptor, location.name, UInt32(RENAME_SWAP)) == 0 else { throw posixError() }
                // The rewritten descriptor is now the visible note; the original
                // remains locked at the temporary name until the transaction ends.
                do {
                    try afterSwap?()
                    guard try isCurrent(temporaryDescriptor, at: location),
                          try isCurrent(descriptor, at: temporary) else { throw POSIXError(.EAGAIN) }
                    _ = try validateManagedFile(temporaryDescriptor)
                    if newName != location.name {
                        guard renameatx_np(location.parentDescriptor, location.name,
                                           location.parentDescriptor, newName, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
                    }
                    let installed = FileLocation(directories: location.directories, name: newName)
                    _ = try validateManagedFile(temporaryDescriptor)
                    guard try isCurrent(temporaryDescriptor, at: installed), try isCurrent(location.directories) else {
                        throw POSIXError(.EAGAIN)
                    }
                } catch {
                    if error is SessionRenameInterruption { retainTemporary = true; throw error }
                    // Never overwrite a replacement made by a non-cooperating editor.
                    if (try? isCurrent(temporaryDescriptor, at: location)) == true,
                       (try? isCurrent(descriptor, at: temporary)) == true {
                        guard renameatx_np(location.parentDescriptor, temporaryName,
                                           location.parentDescriptor, location.name, UInt32(RENAME_SWAP)) == 0 else { throw posixError() }
                    } else { retainTemporary = true }
                    throw error
                }
                _ = fsync(location.parentDescriptor)
            }
        }
    }

    static func removeSessionTemporary(in root: VaultDirectoryAnchor, relativePath: String,
                                       identities: [ManagedFileIdentity]) throws {
        let location = try openLocation(root: root, relativePath: relativePath)
        guard location.name.hasPrefix(".session-"), location.name.hasSuffix(".pending"),
              UUID(uuidString: String(location.name.dropFirst(9).dropLast(8))) != nil else { throw POSIXError(.EPERM) }
        let descriptor = openat(location.parentDescriptor, location.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else { throw posixError() }
        try withLockedDescriptor(descriptor) {
            let value = try validateManagedFile(descriptor)
            let identity = ManagedFileIdentity(device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(truncatingIfNeeded: value.st_ino))
            guard identities.contains(identity) else { return }
            guard try isCurrent(descriptor, at: location) else { throw POSIXError(.EAGAIN) }
            guard unlinkat(location.parentDescriptor, location.name, 0) == 0 else { throw posixError() }
        }
    }

    private static func sessionHeading(_ title: String, replacing contents: Data) throws -> Data {
        // Work in bytes: Swift treats CRLF as one Character, and converting the
        // body through String could change invalid UTF-8 or newline bytes.
        let bomCount = contents.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let body = contents.dropFirst(bomCount)
        var rewritten = Data(contents.prefix(bomCount))
        rewritten.append(Data("# \(title)".utf8))
        if body.starts(with: [0x23, 0x20]) {
            let end = body.firstIndex(of: 0x0A) ?? contents.endIndex
            if end > body.startIndex, contents[end - 1] == 0x0D { rewritten.append(0x0D) }
            rewritten.append(contents[end...])
        } else {
            let newline = contents.range(of: Data([0x0D, 0x0A])) == nil ? Data([0x0A]) : Data([0x0D, 0x0A])
            rewritten.append(newline)
            rewritten.append(newline)
            rewritten.append(body)
        }
        return rewritten
    }

    static func append(block: String, header: String, root: VaultDirectoryAnchor, relativePath: String, to url: URL, cache: inout AppendCache, identityPrefix: String,
                       unlessMarkerExists marker: String? = nil,
                       savedNoteMarker: String? = nil, sourceHeading: String? = nil, equivalentBlocks: [String] = [], calendar: Calendar = .current,
                       beforeWrite: (@Sendable (URL) -> Void)? = nil,
                       afterWrite: (@Sendable (URL) -> Void)? = nil) throws {
        if savedNoteMarker != nil { try createCompleteNote(Data((header + block).utf8), root: root, relativePath: relativePath) }
        let blockData = Data(block.utf8)
        for attempt in 0..<attempts {
            let location = try openLocation(root: root, relativePath: relativePath)
            guard try isCurrent(location.directories) else { throw POSIXError(.EAGAIN) }
            var descriptor = openat(location.parentDescriptor, location.name,
                                    O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor < 0, errno == EEXIST {
                descriptor = openat(location.parentDescriptor, location.name,
                                    O_RDWR | O_APPEND | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
            if descriptor < 0, errno == ENOENT { continue }
            guard descriptor >= 0 else { throw posixError() }
            let current = try withLockedDescriptor(descriptor) {
                // Inspect the locked inode, rather than a path an editor may have replaced.
                let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                _ = try validateManagedFile(descriptor)
                let initial = try fingerprint(descriptor)
                let end = UInt64(initial.size)
                var state = cache.take(url.path, matching: initial)
                var contents: Data?
                var emittedBlock = block
                if marker != nil || sourceHeading != nil || attempt > 0 {
                    if state == nil {
                        try reader.seek(toOffset: 0)
                        let data = try reader.readToEnd() ?? Data()
                        contents = data
                        cache.recordScan()
                        var scanned = AppendState(fingerprint: initial)
                        scanned.consume(data, at: 0, calendar: calendar)
                        if scanned.markerCount <= AppendCache.markerLimit,
                           scanned.source.retainedByteCount <= AppendCache.sourceByteLimit { state = scanned }
                    }
                    let alreadySaved: Bool
                    if let state {
                        alreadySaved = try matches(state: state, identity: identityPrefix, savedNoteMarker: savedNoteMarker,
                                                   blocks: [blockData] + equivalentBlocks.map { Data($0.utf8) }, descriptor: descriptor)
                    } else {
                        let contents = contents ?? Data()
                        alreadySaved = (savedNoteMarker.map { contents.range(of: Data($0.utf8)) != nil } ?? false) ||
                            contents.range(of: blockData) != nil || equivalentBlocks.contains { contents.range(of: Data($0.utf8)) != nil }
                    }
                    // An independently created note keeps its identity even when
                    // the user has subsequently edited its body in another app.
                    // A marker alone can be left by a failed write; that path truncates its bytes back.
                    // A crash, kill or power loss mid-write can still leave a marker without its body.
                    if alreadySaved {
                        let current = try isCurrent(descriptor, at: location)
                        guard current, try fingerprint(descriptor) == initial else { return false }
                        if let state { cache.store(state, at: url.path) }
                        return true
                    }
                    if let sourceHeading {
                        let needsHeading = state?.source.needsHeading(sourceHeading, calendar: calendar) ??
                            NoteParser.needsSourceHeading(sourceHeading, contents: String(decoding: contents ?? Data(), as: UTF8.self), calendar: calendar)
                        if needsHeading { emittedBlock = "### \(sourceHeading)\n" + block }
                    }
                }
                let prefix: String
                if end == 0 { prefix = header }
                else {
                    try reader.seek(toOffset: end - min(2, end))
                    let tail = try reader.read(upToCount: 2) ?? Data()
                    prefix = tail.suffix(2) == Data([10, 10]) ? "" : (tail.last == 10 ? "\n" : "\n\n")
                }
                let appended = Data((prefix + emittedBlock).utf8)
                // Non-cooperating external editors can change the inode despite
                // flock. Recompute both replay and source decisions on mutation.
                beforeWrite?(url)
                guard try isCurrent(descriptor, at: location), try fingerprint(descriptor) == initial else { return false }
                _ = try validateManagedFile(descriptor)
                do {
                    try writeAll(appended, to: descriptor)
                } catch {
                    // A failed append can leave a valid note marker followed by
                    // only part of its body. Retries intentionally accept that
                    // marker after a successful save, including after the body
                    // is edited elsewhere, so remove this attempt's bytes before
                    // allowing the error to trigger a journal replay.
                    // If rollback fails, still surface the original write error.
                    if ftruncate(descriptor, off_t(end)) != 0 {
                        let code = errno
                        logger.error("Append rollback failed (errno \(code, privacy: .public)); partial bytes may remain")
                    }
                    throw error
                }
                let written = try fingerprint(descriptor)
                afterWrite?(url)
                let current = try isCurrent(descriptor, at: location)
                if current, var state, written.size == initial.size + off_t(appended.count),
                   try fingerprint(descriptor) == written {
                    state.consume(appended, at: end, calendar: calendar)
                    state.fingerprint = written
                    cache.store(state, at: url.path)
                }
                return current
            }
            if current { return }
            // A replacement or detected in-place edit invalidated our view. Retry
            // from current bytes, including editors that copied our append forward.
        }
        throw POSIXError(.EAGAIN)
    }

    /// Installs a new asset without following or replacing an existing entry.
    /// Returns false when the generated name was already occupied.
    static func createAsset(_ data: Data, in root: VaultDirectoryAnchor, relativePath: String) throws -> Bool {
        let location = try openLocation(root: root, relativePath: relativePath, createDirectories: true)
        return try installAsset(data, at: location, replacing: nil, expected: nil)
    }

    /// Replays a journaled image. Existing files are read through a validated
    /// descriptor and incomplete content is replaced atomically in the same dir.
    static func ensureAsset(_ data: Data, in root: VaultDirectoryAnchor, relativePath: String) throws {
        for _ in 0..<attempts {
            let location = try openLocation(root: root, relativePath: relativePath, createDirectories: true)
            guard try isCurrent(location.directories) else { continue }
            let descriptor = openat(location.parentDescriptor, location.name,
                                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0, errno == ENOENT {
                if try installAsset(data, at: location, replacing: nil, expected: nil) { return }
                continue
            }
            guard descriptor >= 0 else { throw posixError() }
            do {
                try withLockedDescriptor(descriptor) {
                    _ = try validateManagedFile(descriptor)
                    let initial = try fingerprint(descriptor)
                    let currentData = try readAll(descriptor)
                    guard try isCurrent(descriptor, at: location), try fingerprint(descriptor) == initial else {
                        throw POSIXError(.EAGAIN)
                    }
                    if currentData == data { return }
                    _ = try installAsset(data, at: location, replacing: descriptor, expected: initial)
                }
                return
            } catch let error as POSIXError where error.code == .EAGAIN {
                continue
            }
        }
        throw POSIXError(.EAGAIN)
    }

    private static func installAsset(_ data: Data, at location: FileLocation, replacing existing: Int32?, expected: Fingerprint?) throws -> Bool {
        guard try isCurrent(location.directories) else { throw POSIXError(.EAGAIN) }
        let temporaryName = ".asset-\(UUID().uuidString).pending"
        let temporaryLocation = FileLocation(directories: location.directories, name: temporaryName)
        let descriptor = openat(location.parentDescriptor, temporaryName,
                                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var removeTemporary = true
        defer {
            if removeTemporary { _ = unlinkat(location.parentDescriptor, temporaryName, 0) }
        }
        return try withLockedDescriptor(descriptor) {
            _ = try validateManagedFile(descriptor)
            guard try isCurrent(location.directories), try isCurrent(descriptor, at: temporaryLocation) else {
                throw POSIXError(.EAGAIN)
            }
            try writeAll(data, to: descriptor)
            let temporaryAttributes = try validateManagedFile(descriptor)
            let temporaryIdentity = FileIdentity(temporaryAttributes)
            guard try isCurrent(descriptor, at: temporaryLocation), try isCurrent(location.directories) else {
                throw POSIXError(.EAGAIN)
            }

            if let existing {
                guard let expected, try isCurrent(existing, at: location), try fingerprint(existing) == expected else {
                    throw POSIXError(.EAGAIN)
                }
                _ = try validateManagedFile(existing)
                guard renameat(location.parentDescriptor, temporaryName, location.parentDescriptor, location.name) == 0 else {
                    throw posixError()
                }
                removeTemporary = false
            } else {
                guard linkat(location.parentDescriptor, temporaryName, location.parentDescriptor, location.name, 0) == 0 else {
                    if errno == EEXIST { return false }
                    throw posixError()
                }
                guard unlinkat(location.parentDescriptor, temporaryName, 0) == 0 else { throw posixError() }
                removeTemporary = false
            }

            let installed = openat(location.parentDescriptor, location.name,
                                   O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard installed >= 0 else { throw posixError() }
            defer { close(installed) }
            let installedAttributes = try validateManagedFile(installed)
            guard FileIdentity(installedAttributes) == temporaryIdentity,
                  try isCurrent(installed, at: location), try isCurrent(location.directories) else {
                throw POSIXError(.EAGAIN)
            }
            return true
        }
    }

    private static func readAll(_ descriptor: Int32) throws -> Data {
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try reader.seek(toOffset: 0)
        return try reader.readToEnd() ?? Data()
    }

    private static func fingerprint(_ descriptor: Int32) throws -> Fingerprint {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw posixError() }
        return Fingerprint(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                           modified: value.st_mtimespec, changed: value.st_ctimespec)
    }

    private static func matches(state: AppendState, identity: String, savedNoteMarker: String?, blocks: [Data], descriptor: Int32) throws -> Bool {
        let identityData = Data(identity.utf8)
        for offset in state.markers[identity] ?? [] {
            if let savedNoteMarker, try equals(Data(savedNoteMarker.utf8), at: offset, descriptor: descriptor) { return true }
            for block in blocks {
                guard let marker = block.range(of: identityData), offset >= UInt64(marker.lowerBound) else { continue }
                if try equals(block, at: offset - UInt64(marker.lowerBound), descriptor: descriptor) { return true }
            }
        }
        return false
    }

    private static func equals(_ expected: Data, at offset: UInt64, descriptor: Int32) throws -> Bool {
        var actual = Data(count: expected.count)
        let count = try actual.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var readCount = 0
            while readCount < bytes.count {
                let result = pread(descriptor, base.advanced(by: readCount), bytes.count - readCount, off_t(offset) + off_t(readCount))
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw posixError() }
                if result == 0 { break }
                readCount += result
            }
            return readCount
        }
        return count == expected.count && actual == expected
    }

    /// Publish a new root note only after its entire header/body has been written
    /// under the lock. Thus a crash cannot expose a saved marker with a short body.
    /// link() installs without replacing a file that appeared since title routing.
    private static func createCompleteNote(_ data: Data, root: VaultDirectoryAnchor, relativePath: String) throws {
        let location = try openLocation(root: root, relativePath: relativePath)
        guard try isCurrent(location.directories) else { throw POSIXError(.EAGAIN) }
        let existing = openat(location.parentDescriptor, location.name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if existing >= 0 {
            try withLockedDescriptor(existing) {
                _ = try validateManagedFile(existing)
                guard try isCurrent(existing, at: location) else { throw POSIXError(.EAGAIN) }
            }
            return
        }
        if errno != ENOENT { throw posixError() }

        let temporaryName = ".note-\(UUID().uuidString).pending"
        let temporaryLocation = FileLocation(directories: location.directories, name: temporaryName)
        let descriptor = openat(location.parentDescriptor, temporaryName,
                                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var removeTemporary = true
        defer {
            if removeTemporary { _ = unlinkat(location.parentDescriptor, temporaryName, 0) }
        }
        try withLockedDescriptor(descriptor) {
            _ = try validateManagedFile(descriptor)
            guard try isCurrent(location.directories), try isCurrent(descriptor, at: temporaryLocation) else {
                throw POSIXError(.EAGAIN)
            }
            try writeAll(data, to: descriptor)
            _ = try validateManagedFile(descriptor)
            guard try isCurrent(descriptor, at: temporaryLocation), try isCurrent(location.directories) else {
                throw POSIXError(.EAGAIN)
            }
            if linkat(location.parentDescriptor, temporaryName, location.parentDescriptor, location.name, 0) != 0 {
                if errno != EEXIST { throw posixError() }
            } else {
                guard unlinkat(location.parentDescriptor, temporaryName, 0) == 0 else { throw posixError() }
                removeTemporary = false
                let installed = openat(location.parentDescriptor, location.name,
                                       O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard installed >= 0 else { throw posixError() }
                defer { close(installed) }
                _ = try validateManagedFile(installed)
                guard try isCurrent(installed, at: location) else { throw POSIXError(.EAGAIN) }
            }
        }
    }

    private static func withLockedDescriptor<T>(_ descriptor: Int32, operation: () throws -> T) throws -> T {
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                written += count
            }
        }
    }
}
