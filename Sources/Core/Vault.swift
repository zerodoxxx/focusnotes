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
    let url: URL
    let kind: NoteKind
}

/// The notes folder: root notes, `Sessions/` and `assets/`.
public struct Vault: Sendable {
    public static let inboxFileName = "Inbox.md"
    public static let inboxTitle = "Inbox"
    public static let sessionsDirectoryName = "Sessions"
    public static let assetsDirectoryName = "assets"

    public let root: URL
    let rootAnchor: VaultDirectoryAnchor

    public init(root: URL) {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = resolved
        rootAnchor = VaultDirectoryAnchor(url: root)
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

    /// Creates the folder layout and `Inbox.md` if missing. Never overwrites existing files.
    public func prepare() throws {
        try rootAnchor.prepareRoot()
        try NoteFile.prepareManagedDirectory(Self.sessionsDirectoryName, in: rootAnchor)
        try NoteFile.prepareManagedDirectory(Self.assetsDirectoryName, in: rootAnchor)
        try NoteFile.prepareInbox(Data(CaptureFormat.noteHeader(title: Self.inboxTitle).utf8), in: rootAnchor)
    }

    /// Lists `*.md` files directly in the root and in `Sessions/`. Hidden files are skipped.
    public func listNotes() throws -> [NoteRef] {
        var refs: [NoteRef] = []
        for (url, prefix) in try markdownFiles(in: root, relativeDirectory: "") {
            let kind: NoteKind = url.lastPathComponent == Self.inboxFileName ? .inbox : .note
            refs.append(NoteRef(url: url, title: title(of: url, prefix: prefix), kind: kind))
        }
        for (url, prefix) in try markdownFiles(in: sessionsURL, relativeDirectory: Self.sessionsDirectoryName) {
            refs.append(NoteRef(url: url, title: title(of: url, prefix: prefix), kind: .session))
        }
        return refs
    }

    /// Lists Markdown paths without opening their contents. Index synchronization
    /// performs its own descriptor-backed metadata read and does not need titles.
    func listNoteFiles() throws -> [VaultNoteFile] {
        let rootNames = try markdownFileNames(in: root, relativeDirectory: "")
        let sessionNames = try markdownFileNames(in: sessionsURL, relativeDirectory: Self.sessionsDirectoryName)
        return rootNames.map { name in
            VaultNoteFile(url: root.appendingPathComponent(name), kind: name == Self.inboxFileName ? .inbox : .note)
        } + sessionNames.map { VaultNoteFile(url: sessionsURL.appendingPathComponent($0), kind: .session) }
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

    /// Resolves a vault-relative, slash-separated path such as `Sessions/2026-10-13 Foo.md`.
    public func url(forRelativePath path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
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

    private func markdownFiles(in directory: URL, relativeDirectory: String) throws -> [(URL, Data)] {
        try markdownFileNames(in: directory, relativeDirectory: relativeDirectory).compactMap { name in
            let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
            guard let prefix = try? NoteFile.readManagedPrefix(4096, in: rootAnchor, relativePath: relativePath) else { return nil }
            return (directory.appendingPathComponent(name), prefix)
        }
    }

    private func markdownFileNames(in directory: URL, relativeDirectory: String) throws -> [String] {
        let names: [String]
        do {
            names = try NoteFile.listManagedDirectoryNames(in: rootAnchor, relativePath: relativeDirectory)
        } catch let error as POSIXError where error.code == .ENOENT {
            return []
        }
        return names
            .filter { !$0.hasPrefix(".") && URL(fileURLWithPath: $0).pathExtension.lowercased() == "md" }
            .sorted()
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
