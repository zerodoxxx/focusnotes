import Darwin
import Foundation

/// Persists only HOME-relative notes explicitly selected by the user.
/// It intentionally does not discover or scan arbitrary files under HOME.
final class ExternalNoteRegistry: @unchecked Sendable {
    private struct Store: Codable {
        var version = 1
        var paths: [String] = []
    }

    private let anchor: VaultDirectoryAnchor
    private let name: String
    private let lockName: String

    init(url: URL) {
        let standardized = url.standardizedFileURL
        anchor = VaultDirectoryAnchor(url: standardized.deletingLastPathComponent())
        name = standardized.lastPathComponent
        lockName = ".\(standardized.lastPathComponent).lock"
    }

    func paths() throws -> [String] {
        try withLockedDirectory(createIfMissing: true) { root in
            try readStore(in: root).paths
        }
    }

    /// Idempotently records a validated HOME-relative Markdown path.
    func register(_ path: String) throws {
        guard Self.isSafeRelativeMarkdownPath(path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try withLockedDirectory(createIfMissing: true) { root in
            var store = try readStore(in: root)
            guard !store.paths.contains(path) else { return }
            store.paths.append(path)
            store.paths.sort()
            try writeStore(store, in: root)
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
            guard decoded.version == 1 else { return Store() }
            return Store(version: 1, paths: Array(Set(decoded.paths.filter(Self.isSafeRelativeMarkdownPath))).sorted())
        } catch is DecodingError {
            // A damaged registry must not prevent the vault from opening. The
            // next explicit external save repairs it with a fresh valid store.
            return Store()
        }
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
