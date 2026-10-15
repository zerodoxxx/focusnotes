import EmbedKit
import Foundation
import os

/// Downloads the opt-in semantic-search models into `modelsDirectory`.
///
/// Every file is checked against its pinned SHA-256 from the manifest. Partial downloads live in a sibling
/// staging directory and resume on the next call. The models directory is replaced only after everything verifies.
public actor ModelInstaller {
    /// Bytes completed out of the total download size.
    public struct Progress: Sendable {
        public let completedBytes: Int64
        public let totalBytes: Int64

        public var fraction: Double {
            guard totalBytes > 0 else { return 1 }
            return min(1, Double(completedBytes) / Double(totalBytes))
        }
    }

    private static let extractionHeadroom: Int64 = 300_000_000
    private static let maxNetworkRetries = 3
    private static let extractDirectoryName = ".runtime-extract"

    private let modelsDirectory: URL
    private let bundledResources: URL
    private let manifest: ModelManifest
    private let transport: any ModelTransport
    private let freeSpace: @Sendable (URL) throws -> Int64
    private let tarExecutable: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ModelInstall", category: "model-install")
    /// True for the whole of `install()`, so `remove()` and a second install cannot touch the same files.
    private var installing = false

    public init(modelsDirectory: URL, bundledResources: URL, manifest: ModelManifest = .current,
                transport: any ModelTransport = URLSessionTransport(),
                freeSpace: @escaping @Sendable (URL) throws -> Int64 = ModelInstaller.volumeFreeSpace,
                tarExecutable: URL = URL(fileURLWithPath: "/usr/bin/tar")) {
        self.modelsDirectory = modelsDirectory
        self.bundledResources = bundledResources
        self.manifest = manifest
        self.transport = transport
        self.freeSpace = freeSpace
        self.tarExecutable = tarExecutable
    }

    /// Sibling of the models directory where downloads accumulate until they verify.
    public nonisolated var stagingDirectory: URL {
        modelsDirectory.deletingLastPathComponent().appendingPathComponent("models.download", isDirectory: true)
    }

    /// True when an earlier download left files behind that the next `install` call can resume.
    public nonisolated var hasPartialDownload: Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
        return !contents.isEmpty
    }

    /// Installs the models, resuming any earlier partial download. Nothing is downloaded unless this is called.
    public func install(progress: @escaping @Sendable (Progress) -> Void) async throws {
        guard !installing else {
            throw ModelInstallError.unavailable("An install is already running.")
        }
        installing = true
        defer { installing = false }
        do {
            try await performInstall(progress: progress)
        } catch is CancellationError {
            throw ModelInstallError.cancelled
        } catch let error as ModelInstallError {
            throw error
        } catch {
            throw ModelInstallError.io(error.localizedDescription)
        }
    }

    /// Deletes the installed models and any partial download.
    public func remove() throws {
        guard !installing else {
            throw ModelInstallError.unavailable("A download is in progress.")
        }
        let fm = FileManager.default
        do {
            for url in [modelsDirectory, stagingDirectory] where fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        } catch {
            throw ModelInstallError.io(error.localizedDescription)
        }
    }

    /// Free bytes available for important usage on the volume that holds `url`.
    public static func volumeFreeSpace(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw ModelInstallError.unavailable("The free space on this volume is unknown.")
        }
        return bytes
    }

    // MARK: - Install steps

    private func performInstall(progress: @escaping @Sendable (Progress) -> Void) async throws {
        let fm = FileManager.default
        let staging = stagingDirectory
        let parent = modelsDirectory.deletingLastPathComponent()
        let total = manifest.totalDownloadBytes

        // Step 1: staging directory (also creates the parent) and cleanup of backups left by a crash.
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        removeStaleBackups(in: parent)

        // Fail before any download when a bundled license is missing from the app.
        for license in manifest.licenses {
            let source = bundledResources.appendingPathComponent(license.resourceName)
            guard fm.fileExists(atPath: source.path) else {
                throw ModelInstallError.missingBundledResource(license.resourceName)
            }
        }

        // Step 2: work list. Files that already verify are reused and count as completed.
        var downloads: [Download] = []
        var completed: Int64 = 0
        // .part files of files that no longer need downloading. Removed only after the space check passes.
        var stalePartNames: [String] = []
        for artifact in manifest.modelFiles {
            let staged = staging.appendingPathComponent(artifact.path)
            if try hashMatches(staged, artifact.sha256) {
                stalePartNames.append(artifact.path)
                completed += artifact.size
                continue
            }
            let installed = modelsDirectory.appendingPathComponent(artifact.path)
            if try hashMatches(installed, artifact.sha256) {
                stalePartNames.append(artifact.path)
                try replaceItem(at: staged, copyingFrom: installed)
                completed += artifact.size
                continue
            }
            downloads.append(Download(name: artifact.path, url: artifact.url, sha256: artifact.sha256, size: artifact.size))
        }

        let runtime = manifest.runtime
        let runtimeFiles = [
            (manifest.dylibName, runtime.dylibSHA256),
            (manifest.runtimeLicenseName, runtime.licenseSHA256),
            (manifest.runtimeNoticesName, runtime.noticesSHA256),
        ]
        var runtimeInstalled = true
        for (name, digest) in runtimeFiles {
            if try !hashMatches(staging.appendingPathComponent(name), digest) {
                runtimeInstalled = false
                break
            }
        }
        let archive = staging.appendingPathComponent("runtime.tgz")
        if runtimeInstalled {
            stalePartNames.append("runtime.tgz")
            try? fm.removeItem(at: archive)
            try? fm.removeItem(at: staging.appendingPathComponent(Self.extractDirectoryName, isDirectory: true))
            completed += runtime.size
        } else if try hashMatches(archive, runtime.sha256) {
            stalePartNames.append("runtime.tgz")
            completed += runtime.size
        } else {
            downloads.append(Download(name: "runtime.tgz", url: runtime.url, sha256: runtime.sha256, size: runtime.size))
        }

        // Step 3: disk pre-flight, counting bytes already present in .part files as downloaded.
        // Read-only: nothing is deleted until the space check has passed.
        var remainingBytes: Int64 = 0
        for item in downloads {
            let partial = try partialBytes(at: partURL(item.name), expectedSize: item.size)
            remainingBytes += item.size - partial
        }
        let required = remainingBytes + Self.extractionHeadroom
        let available = try freeSpace(parent)
        guard available >= required else {
            throw ModelInstallError.insufficientDiskSpace(required: required, available: available)
        }
        for name in stalePartNames {
            discardPartialFile(for: name)
        }
        logger.info("Model install: \(downloads.count, privacy: .public) files to fetch, \(remainingBytes, privacy: .public) bytes remaining")

        let throttle = ProgressThrottle(total: total, callback: progress)
        throttle.report(completed, force: true)

        // Step 4: downloads in manifest order, with the runtime archive last.
        for item in downloads {
            try Task.checkCancellation()
            let base = completed
            let size = item.size
            try await fetch(item) { onDisk in
                throttle.report(base + min(onDisk, size))
            }
            completed += item.size
        }

        // Step 5: unpack the runtime archive and verify each member before it is installed.
        if !runtimeInstalled {
            try extractRuntime(archive: archive, staging: staging)
        }

        // Step 6: bundled license files, verified before they are copied in.
        for license in manifest.licenses {
            let source = bundledResources.appendingPathComponent(license.resourceName)
            guard try hashMatches(source, license.sha256) else {
                throw ModelInstallError.checksumMismatch(file: license.resourceName)
            }
            try replaceItem(at: staging.appendingPathComponent(license.installedName), copyingFrom: source)
        }

        // Step 7: everything the app needs is present, and nothing is half-written.
        let requiredNames = manifest.requiredFiles
            + [manifest.runtimeLicenseName, manifest.runtimeNoticesName]
            + manifest.licenses.map(\.installedName)
        for name in requiredNames where !fm.fileExists(atPath: staging.appendingPathComponent(name).path) {
            throw ModelInstallError.io("\(name) is missing after the download")
        }
        if containsPartialFiles(in: staging) {
            throw ModelInstallError.io("an incomplete download is still present")
        }

        // Step 8: atomic commit. The old directory is kept until the new one is in place.
        guard fm.fileExists(atPath: staging.path) else {
            throw ModelInstallError.io("the staging folder was removed during the install")
        }
        try commit(staging: staging)
        logger.info("Model install complete: \(requiredNames.count, privacy: .public) files")

        // Step 9: final progress.
        throttle.report(total, force: true)
    }

    /// Downloads one file, resuming from its .part file, with retries on network errors.
    private func fetch(_ item: Download, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let part = partURL(item.name)
        let destination = stagingDirectory.appendingPathComponent(item.name)
        guard let source = URL(string: item.url) else {
            throw ModelInstallError.io("the download address for \(item.name) is invalid")
        }
        try ensureParent(of: destination)
        logger.info("Downloading \(item.name, privacy: .public) (\(item.size, privacy: .public) bytes)")

        var networkRetries = 0
        var checksumRetried = false
        while true {
            // Read before every attempt, so a retry after a stale range resumes from the file's real size.
            let offset = try partialBytes(at: part, expectedSize: item.size)
            if offset == 0 {
                try? FileManager.default.removeItem(at: part)
            }
            do {
                try await transport.download(from: source, appendingTo: part, offset: offset, progress: progress)
            } catch let error as ModelInstallError where isRetryable(error) {
                guard networkRetries < Self.maxNetworkRetries else {
                    throw error
                }
                networkRetries += 1
                logger.notice("Download of \(item.name, privacy: .public) failed; retry \(networkRetries, privacy: .public)")
                try await Task.sleep(for: .seconds(networkRetries))
                continue
            }
            if try hashMatches(part, item.sha256) {
                try replaceItem(at: destination, movingFrom: part)
                logger.info("Verified \(item.name, privacy: .public)")
                return
            }
            try? FileManager.default.removeItem(at: part)
            guard !checksumRetried else {
                throw ModelInstallError.checksumMismatch(file: item.name)
            }
            checksumRetried = true
            logger.error("Checksum mismatch for \(item.name, privacy: .public); downloading it again from the start")
        }
    }

    /// Extracts the three runtime members with the system tar and verifies each against its pinned hash.
    private func extractRuntime(archive: URL, staging: URL) throws {
        let fm = FileManager.default
        let runtime = manifest.runtime
        let extractDirectory = staging.appendingPathComponent(Self.extractDirectoryName, isDirectory: true)
        try? fm.removeItem(at: extractDirectory)
        try fm.createDirectory(at: extractDirectory, withIntermediateDirectories: true)

        let members: [(member: String, digest: String, installedName: String)] = [
            (runtime.dylibMember, runtime.dylibSHA256, manifest.dylibName),
            (runtime.licenseMember, runtime.licenseSHA256, manifest.runtimeLicenseName),
            (runtime.noticesMember, runtime.noticesSHA256, manifest.runtimeNoticesName),
        ]

        let process = Process()
        let stderr = Pipe()
        process.executableURL = tarExecutable
        process.arguments = ["-xzf", archive.path, "-C", extractDirectory.path] + members.map(\.member)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            try? fm.removeItem(at: extractDirectory)
            throw ModelInstallError.extractionFailed(error.localizedDescription)
        }
        let errorOutput = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? fm.removeItem(at: extractDirectory)
            let text = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModelInstallError.extractionFailed(text.isEmpty ? "tar exited with status \(process.terminationStatus)" : text)
        }

        for entry in members {
            let extracted = extractDirectory.appendingPathComponent(entry.member)
            guard fm.fileExists(atPath: extracted.path) else {
                try? fm.removeItem(at: extractDirectory)
                throw ModelInstallError.extractionFailed("\(entry.member) is not in the archive")
            }
            guard try FileDigest.sha256Hex(of: extracted) == entry.digest else {
                try? fm.removeItem(at: extractDirectory)
                try? fm.removeItem(at: archive)
                throw ModelInstallError.checksumMismatch(file: entry.member)
            }
        }
        for entry in members {
            try replaceItem(at: staging.appendingPathComponent(entry.installedName),
                            movingFrom: extractDirectory.appendingPathComponent(entry.member))
        }
        try? fm.removeItem(at: extractDirectory)
        try? fm.removeItem(at: archive)
    }

    /// Swaps the staged directory in for the models directory. On failure the old directory is restored.
    private func commit(staging: URL) throws {
        let fm = FileManager.default
        let parent = modelsDirectory.deletingLastPathComponent()
        var backup: URL?
        if fm.fileExists(atPath: modelsDirectory.path) {
            let old = parent.appendingPathComponent("models.old-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: modelsDirectory, to: old)
            backup = old
        }
        do {
            try fm.moveItem(at: staging, to: modelsDirectory)
        } catch {
            if let backup {
                try? fm.moveItem(at: backup, to: modelsDirectory)
            }
            throw error
        }
        if let backup {
            try? fm.removeItem(at: backup)
        }
    }

    /// Heals an interrupted commit. Safe to call on every launch, before anything reads the models directory.
    public nonisolated func recoverInterruptedCommit() {
        removeStaleBackups(in: modelsDirectory.deletingLastPathComponent())
    }

    /// Removes `models.old-*` directories left behind by an interrupted commit. Only this installer creates them.
    /// If the models directory is missing (the crash fell between moving it aside and moving the new one in),
    /// the newest backup is restored first so the previous models survive.
    private nonisolated func removeStaleBackups(in parent: URL) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        var backups: [(url: URL, created: Date)] = names.filter { $0.hasPrefix("models.old-") }.map { name in
            let url = parent.appendingPathComponent(name, isDirectory: true)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (url, created)
        }
        guard !backups.isEmpty else { return }
        backups.sort { $0.created > $1.created }

        if !fm.fileExists(atPath: modelsDirectory.path) {
            do {
                try fm.moveItem(at: backups[0].url, to: modelsDirectory)
            } catch {
                // Keep every backup if the restore fails, so no models are lost.
                return
            }
            backups.removeFirst()
        }
        for backup in backups {
            try? fm.removeItem(at: backup.url)
        }
    }

    // MARK: - File helpers

    private func hashMatches(_ file: URL, _ expected: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return try FileDigest.sha256Hex(of: file) == expected
    }

    /// Bytes already in the partial file for `part`. Read-only: 0 when the file is missing or larger than expected.
    private func partialBytes(at part: URL, expectedSize: Int64) throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: part.path) else { return 0 }
        let attributes = try fm.attributesOfItem(atPath: part.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return size <= expectedSize ? size : 0
    }

    /// Network drops and server-side failures (429 and 5xx) are retried; other statuses fail at once.
    private func isRetryable(_ error: ModelInstallError) -> Bool {
        switch error {
        case .network:
            return true
        case .httpStatus(let code, _):
            return code == 429 || (500...599).contains(code)
        default:
            return false
        }
    }

    private func partURL(_ name: String) -> URL {
        stagingDirectory.appendingPathComponent(name + ".part")
    }

    private func discardPartialFile(for name: String) {
        try? FileManager.default.removeItem(at: partURL(name))
    }

    private func ensureParent(of url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func replaceItem(at destination: URL, copyingFrom source: URL) throws {
        let fm = FileManager.default
        try ensureParent(of: destination)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private func replaceItem(at destination: URL, movingFrom source: URL) throws {
        let fm = FileManager.default
        try ensureParent(of: destination)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: source, to: destination)
    }
}

private struct Download: Sendable {
    let name: String
    let url: String
    let sha256: String
    let size: Int64
}

/// Shares one progress callback between the transport's delegate queue and the installer,
/// and limits it to about ten calls per second unless forced.
private struct ProgressThrottle: Sendable {
    let total: Int64
    let callback: @Sendable (ModelInstaller.Progress) -> Void
    private let lastEmit = OSAllocatedUnfairLock<TimeInterval>(initialState: -.infinity)

    func report(_ completed: Int64, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldEmit = lastEmit.withLock { last -> Bool in
            guard force || now - last >= 0.1 else { return false }
            last = now
            return true
        }
        guard shouldEmit else { return }
        callback(ModelInstaller.Progress(completedBytes: min(max(completed, 0), total), totalBytes: total))
    }
}

/// True when any `.part` file exists under `root`.
private func containsPartialFiles(in root: URL) -> Bool {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return false
    }
    for case let url as URL in enumerator where url.pathExtension == "part" {
        return true
    }
    return false
}
