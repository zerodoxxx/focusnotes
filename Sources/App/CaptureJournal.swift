import CaptureKit
import Core
import CryptoKit
import Foundation
import os

struct CaptureJob: Sendable {
    let prepared: PreparedCapture
    let png: Data?
    let ocr: String?
    var deferredOCR: Task<CaptureKit.OCRResult?, Never>? = nil
    var noteDraft: String? = nil
}

actor CaptureJournal {
    struct SessionRenameIntent: Codable, Sendable {
        let oldPath: String
        let session: Session
        let captureIDs: [UUID]
        let source: ManagedFileIdentity
        let sourceSize: Int64
        let sourceModifiedSeconds: Int64
        let sourceModifiedNanoseconds: Int64
        let sourceChangedSeconds: Int64
        let sourceChangedNanoseconds: Int64
        let sourceDigest: String
        var installation: SessionRenameStage? = nil
        var previousInstallations: [SessionRenameStage] = []

        func isOriginal(_ snapshot: VaultFileSnapshot) -> Bool {
            guard ManagedFileIdentity(snapshot) == source else { return false }
            if snapshot.size == sourceSize &&
                snapshot.modifiedSeconds == sourceModifiedSeconds && snapshot.modifiedNanoseconds == sourceModifiedNanoseconds &&
                snapshot.changedSeconds == sourceChangedSeconds && snapshot.changedNanoseconds == sourceChangedNanoseconds { return true }
            // A rolled-back atomic swap updates ctime even though the original
            // inode and every byte are restored. Accept that same original only
            // after hashing a fresh validated snapshot, never by inode alone.
            guard let contents = snapshot.contents else { return false }
            return Self.digest(contents) == sourceDigest
        }
        func isInstalled(_ snapshot: VaultFileSnapshot) -> Bool {
            ManagedFileIdentity(snapshot) == installation?.installed
        }
        static func digest(_ contents: Data) -> String {
            SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Record: Codable {
        let prepared: PreparedCapture
        let hasPNG: Bool
        let ocr: String?
        let noteDraft: String?
    }

    let directory: URL
    private let renameIntentURL: URL
    private let redirectsURL: URL

    init(stateDirectory: URL) {
        directory = stateDirectory.appendingPathComponent("unsaved", isDirectory: true)
        renameIntentURL = stateDirectory.appendingPathComponent("session-rename.json")
        redirectsURL = stateDirectory.appendingPathComponent("capture-destinations.json")
    }

    func store(_ job: CaptureJob) throws {
        let job = try redirected(job)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = Self.key(for: job.prepared.capture.id)
        if let png = job.png {
            try png.write(to: directory.appendingPathComponent(stem + ".png"), options: .atomic)
        }
        let record = Record(prepared: job.prepared, hasPNG: job.png != nil, ocr: job.ocr, noteDraft: job.noteDraft)
        try Self.writeJSON(record, to: directory.appendingPathComponent(stem + ".json"))
    }

    /// Persist the identity change before touching Markdown. Redirects are keyed
    /// by capture UUID, so creating a new session at the old filename later does
    /// not redirect unrelated captures.
    func beginSessionRename(oldPath: String, session: Session, vault: Vault,
                            preparedJobs: [CaptureJob]) throws -> SessionRenameIntent {
        let currentJobs = try preparedJobs.map { try redirected($0) }
        var ids = Set(currentJobs.filter {
            (try? vault.noteID(for: $0.prepared.destination.url)) == oldPath
        }.map { $0.prepared.capture.id })
        for url in try recordURLs() {
            let data = try Data(contentsOf: url)
            guard let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            if (try? vault.noteID(for: record.prepared.destination.url)) == oldPath {
                ids.insert(record.prepared.capture.id)
            }
        }
        guard let source = try vault.fileSnapshot(relativePath: oldPath), let contents = source.contents else {
            throw SessionStoreError.candidateNoLongerExists(oldPath)
        }
        let intent = SessionRenameIntent(oldPath: oldPath, session: session,
                                        captureIDs: ids.sorted { $0.uuidString < $1.uuidString },
                                        source: ManagedFileIdentity(source), sourceSize: source.size,
                                        sourceModifiedSeconds: source.modifiedSeconds, sourceModifiedNanoseconds: source.modifiedNanoseconds,
                                        sourceChangedSeconds: source.changedSeconds, sourceChangedNanoseconds: source.changedNanoseconds,
                                        sourceDigest: SessionRenameIntent.digest(contents))
        try FileManager.default.createDirectory(at: renameIntentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeJSON(intent, to: renameIntentURL)
        return intent
    }

    /// The staged inode is recorded before the atomic swap. Recovery only adopts
    /// that exact managed file, never an unrelated file at the destination name.
    func installationRecorder(for intent: SessionRenameIntent) -> @Sendable (SessionRenameStage) throws -> Void {
        let url = renameIntentURL
        return { stage in
            var installed = intent
            if let previous = installed.installation { installed.previousInstallations.append(previous) }
            installed.installation = stage
            try Self.writeJSON(installed, to: url)
        }
    }

    private static func key(for id: UUID) -> String { id.uuidString.lowercased() }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }

    /// An undecodable intent is quarantined so it cannot block startup or captures.
    func pendingSessionRename() throws -> SessionRenameIntent? {
        guard FileManager.default.fileExists(atPath: renameIntentURL.path) else { return nil }
        let data = try Data(contentsOf: renameIntentURL)
        do { return try JSONDecoder().decode(SessionRenameIntent.self, from: data) }
        catch {
            let corrupt = directory.appendingPathComponent("corrupt", isDirectory: true)
            try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
            let stem = renameIntentURL.deletingPathExtension().lastPathComponent
            let target = FileManager.default.fileExists(atPath: corrupt.appendingPathComponent(stem + ".json").path)
                ? stem + "-" + UUID().uuidString.lowercased() : stem
            try FileManager.default.moveItem(at: renameIntentURL, to: corrupt.appendingPathComponent(target + ".json"))
            Logger(subsystem: AppInfo.bundleIdentifier, category: "journal")
                .error("Corrupt session rename intent quarantined (\(AppErrorLog.summary(error), privacy: .public))")
            return nil
        }
    }

    func finishSessionRename(_ intent: SessionRenameIntent, vault: Vault) throws {
        var redirects = try destinationRedirects()
        let destination = Destination(url: try vault.managedURL(forRelativePath: intent.session.notePath),
                                      title: intent.session.name, kind: .session)
        for id in intent.captureIDs { redirects[Self.key(for: id)] = destination }
        try Self.writeJSON(redirects, to: redirectsURL)
        for id in intent.captureIDs {
            let url = directory.appendingPathComponent(Self.key(for: id) + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // Replay quarantines an undecodable record; it must not block recovery at startup.
            guard let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url)) else { continue }
            guard let destination = redirects[Self.key(for: record.prepared.capture.id)] else { continue }
            let updated = Record(prepared: replacingDestination(record.prepared, with: destination),
                                 hasPNG: record.hasPNG, ocr: record.ocr, noteDraft: record.noteDraft)
            try Self.writeJSON(updated, to: url)
        }
    }

    /// After recovery, persisted records already contain their destination and a
    /// fresh process has no stale prepared objects requiring UUID redirects.
    func discardPreviousProcessRedirects() throws {
        try Self.removeIfPresent(redirectsURL)
    }

    func clearSessionRename() throws {
        try Self.removeIfPresent(renameIntentURL)
    }

    func redirected(_ job: CaptureJob) throws -> CaptureJob {
        guard let destination = try destinationRedirects()[Self.key(for: job.prepared.capture.id)] else { return job }
        return CaptureJob(prepared: replacingDestination(job.prepared, with: destination), png: job.png,
                          ocr: job.ocr, deferredOCR: job.deferredOCR, noteDraft: job.noteDraft)
    }

    private func destinationRedirects() throws -> [String: Destination] {
        guard FileManager.default.fileExists(atPath: redirectsURL.path) else { return [:] }
        return try JSONDecoder().decode([String: Destination].self, from: Data(contentsOf: redirectsURL))
    }

    private func replacingDestination(_ prepared: PreparedCapture, with destination: Destination) -> PreparedCapture {
        PreparedCapture(capture: prepared.capture, destination: destination,
                        createsNote: prepared.createsNote == true, noteMarkerIsIdentity: prepared.noteMarkerIsIdentity == true)
    }

    enum RecordError: Error {
        case corrupt
    }

    func recordURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let records = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let date = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url)).prepared.capture.createdAt
                return (url: url, date: date ?? .distantPast)
            }
        return records.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }.map(\.url)
    }

    /// Replay owns only one record's PNG at a time. I/O failures remain retryable.
    func load(record url: URL) throws -> CaptureJob {
        let data = try Data(contentsOf: url)
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) }
        catch { throw RecordError.corrupt }
        guard url.deletingPathExtension().lastPathComponent == Self.key(for: record.prepared.capture.id) else {
            throw RecordError.corrupt
        }
        var png: Data?
        if record.hasPNG {
            do { png = try Data(contentsOf: url.deletingPathExtension().appendingPathExtension("png")) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                guard let text = record.ocr, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RecordError.corrupt
                }
                let original = record.prepared.capture
                let capture = Capture(id: original.id, createdAt: original.createdAt, content: .text(text), source: original.source)
                return try redirected(CaptureJob(prepared: PreparedCapture(capture: capture, destination: record.prepared.destination), png: nil, ocr: nil))
            }
        }
        return try redirected(CaptureJob(prepared: record.prepared, png: png, ocr: record.ocr, noteDraft: record.noteDraft))
    }

    /// Keep undecodable records and their PNGs without retrying them on every launch.
    func quarantine(record url: URL) throws {
        let corrupt = directory.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        let targetStem = FileManager.default.fileExists(atPath: corrupt.appendingPathComponent(stem + ".json").path)
            ? stem + "-" + UUID().uuidString.lowercased() : stem
        for ext in ["json", "png"] {
            let source = directory.appendingPathComponent(stem + "." + ext)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: corrupt.appendingPathComponent(targetStem + "." + ext))
            }
        }
    }

    func remove(id: UUID) throws {
        let stem = Self.key(for: id)
        // Remove the recovery record only after the note append has succeeded.
        for ext in ["json", "png"] {
            let file = directory.appendingPathComponent(stem + "." + ext)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
