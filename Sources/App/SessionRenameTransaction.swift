import Core
import CryptoKit
import Foundation
import os

/// Owns the crash-safe session rename: the durable intent, the file swap,
/// recovery or abandonment, and moving captures, pins and the index to the new note.
actor SessionRenameTransaction {
    struct Intent: Codable, Sendable {
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

    let vault: Vault
    let sessions: SessionStore
    let journal: CaptureJournal
    let pins: NotePinStore
    let index: SearchIndex
    let semantic: SemanticIndexer
    let logger: Logger
    private let intentURL: URL

    init(vault: Vault, sessions: SessionStore, journal: CaptureJournal, pins: NotePinStore,
         index: SearchIndex, semantic: SemanticIndexer, logger: Logger) {
        self.vault = vault
        self.sessions = sessions
        self.journal = journal
        self.pins = pins
        self.index = index
        self.semantic = semantic
        self.logger = logger
        intentURL = journal.stateDirectory.appendingPathComponent("session-rename.json")
    }

    /// Called only after the controller drains capture writes. The durable
    /// intent survives a crash between the file operation and identity updates.
    func rename(_ candidate: SessionCandidate, to name: String,
                followingCaptures: [CaptureJob],
                beforeInstall: (@Sendable (SessionRenameStage) throws -> Void)? = nil,
                afterSwap: (@Sendable () throws -> Void)? = nil) async throws -> SessionRenameOutcome {
        try await recover(allowFileRename: true)
        let renamed = try await sessions.renameDestination(candidate, to: name)
        let intent = try await begin(oldPath: candidate.notePath, session: renamed, followingCaptures: followingCaptures)
        let recorder = installationRecorder(for: intent)
        do {
            _ = try await sessions.rename(candidate, to: name, beforeInstall: { stage in
                try recorder(stage)
                try beforeInstall?(stage)
            }, afterSwap: afterSwap)
        }
        catch {
            let renameError = error
            do {
                if let recorded = try pending(),
                   try vault.fileSnapshot(relativePath: renamed.notePath, includingContents: false).map(recorded.isInstalled) != true {
                    if let source = try vault.fileSnapshot(relativePath: recorded.oldPath, includingContents: false),
                       recorded.isInstalled(source) {
                        if try await recover(allowFileRename: true) {
                            logger.error("Session rename completed after interrupted swap (\(AppErrorLog.summary(renameError), privacy: .public))")
                            return SessionRenameOutcome(session: renamed, identityUpdatePending: false)
                        }
                    } else {
                        try await abandon(recorded, error: renameError)
                    }
                }
            } catch {
                logger.error("Rename cleanup failed after \(AppErrorLog.summary(renameError), privacy: .public): \(AppErrorLog.summary(error), privacy: .public)")
            }
            // Persistence can fail after the file has committed. Detect that
            // outcome by the staged inode recorded before installation.
            guard let recorded = try? pending(),
                  let target = try? vault.fileSnapshot(relativePath: renamed.notePath, includingContents: false),
                  recorded.isInstalled(target) else { throw renameError }
            // The file is installed; report success and let recovery finish identity updates.
            do {
                try await recover(allowFileRename: false)
                return SessionRenameOutcome(session: renamed, identityUpdatePending: false)
            } catch {
                logger.error("Session renamed; identity update pending (\(AppErrorLog.summary(renameError), privacy: .public); \(AppErrorLog.summary(error), privacy: .public))")
                return SessionRenameOutcome(session: renamed, identityUpdatePending: true)
            }
        }
        do {
            try await recover(allowFileRename: false)
            return SessionRenameOutcome(session: renamed, identityUpdatePending: false)
        } catch {
            logger.error("Session renamed; identity update pending (\(AppErrorLog.summary(error), privacy: .public))")
            return SessionRenameOutcome(session: renamed, identityUpdatePending: true)
        }
    }

    /// Persist the identity change before touching Markdown. Redirects are keyed
    /// by capture UUID, so creating a new session at the old filename later does
    /// not redirect unrelated captures.
    func begin(oldPath: String, session: Session, followingCaptures: [CaptureJob]) async throws -> Intent {
        let ids = try await journal.captureIDs(targeting: oldPath, vault: vault, among: followingCaptures)
        guard let source = try vault.fileSnapshot(relativePath: oldPath), let contents = source.contents else {
            throw SessionStoreError.candidateNoLongerExists(oldPath)
        }
        let intent = Intent(oldPath: oldPath, session: session, captureIDs: ids,
                            source: ManagedFileIdentity(source), sourceSize: source.size,
                            sourceModifiedSeconds: source.modifiedSeconds, sourceModifiedNanoseconds: source.modifiedNanoseconds,
                            sourceChangedSeconds: source.changedSeconds, sourceChangedNanoseconds: source.changedNanoseconds,
                            sourceDigest: Intent.digest(contents))
        try FileManager.default.createDirectory(at: intentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeJSON(intent, to: intentURL)
        return intent
    }

    /// The staged inode is recorded before the atomic swap. Recovery only adopts
    /// that exact managed file, never an unrelated file at the destination name.
    func installationRecorder(for intent: Intent) -> @Sendable (SessionRenameStage) throws -> Void {
        let url = intentURL
        return { stage in
            var installed = intent
            if let previous = installed.installation { installed.previousInstallations.append(previous) }
            installed.installation = stage
            try Self.writeJSON(installed, to: url)
        }
    }

    /// An undecodable intent is quarantined so it cannot block startup or captures.
    func pending() throws -> Intent? {
        guard FileManager.default.fileExists(atPath: intentURL.path) else { return nil }
        let data = try Data(contentsOf: intentURL)
        do { return try JSONDecoder().decode(Intent.self, from: data) }
        catch {
            let corrupt = journal.directory.appendingPathComponent("corrupt", isDirectory: true)
            try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
            let stem = intentURL.deletingPathExtension().lastPathComponent
            let target = FileManager.default.fileExists(atPath: corrupt.appendingPathComponent(stem + ".json").path)
                ? stem + "-" + UUID().uuidString.lowercased() : stem
            try FileManager.default.moveItem(at: intentURL, to: corrupt.appendingPathComponent(target + ".json"))
            Logger(subsystem: AppInfo.bundleIdentifier, category: "journal")
                .error("Corrupt session rename intent quarantined (\(AppErrorLog.summary(error), privacy: .public))")
            return nil
        }
    }

    /// Returns true only when a pending rename completed its identity migration.
    @discardableResult
    func recover(allowFileRename: Bool) async throws -> Bool {
        guard var intent = try pending() else { return false }
        if allowFileRename {
            // Startup must never stay blocked on the file step: any failure before
            // the target holds the installed identity abandons, leaving files as they are.
            do { intent = try await resume(intent) }
            catch {
                // Abandon the latest intent so stages recorded during the resume are cleaned up too.
                try await abandon((try? pending()) ?? intent, error: error)
                return false
            }
        } else {
            let target = try vault.fileSnapshot(relativePath: intent.session.notePath, includingContents: false)
            if target.map(intent.isInstalled) != true {
                // Startup finishes the app's own staged swap; anything else is a stale request.
                if let source = try vault.fileSnapshot(relativePath: intent.oldPath), intent.isInstalled(source) {
                    throw SessionRenameRecoveryError.changedFile
                }
                try await abandon(intent, error: SessionRenameRecoveryError.changedFile)
                return false
            }
        }
        try await sessions.recoverRenamedSession(intent.session)
        try await journal.relocate(intent.captureIDs, to: Destination(
            url: try vault.managedURL(forRelativePath: intent.session.notePath), title: intent.session.name, kind: .session))
        try pins.rename(from: intent.oldPath, to: intent.session.notePath)
        try await cleanup(intent, completed: true)
        try clear()
        do {
            _ = try await index.sync()
            await semantic.schedule()
        } catch {
            logger.error("Session renamed; index update failed (\(AppErrorLog.summary(error), privacy: .public))")
        }
        return true
    }

    /// Returns the intent whose installed identity is at the target. Throws only
    /// while the target does not hold that identity.
    private func resume(_ intent: Intent) async throws -> Intent {
        let target = try vault.fileSnapshot(relativePath: intent.session.notePath, includingContents: false)
        if target.map(intent.isInstalled) == true { return intent }
        let source = try vault.fileSnapshot(relativePath: intent.oldPath)
        guard let source, intent.isOriginal(source) || intent.isInstalled(source) else {
            throw SessionRenameRecoveryError.changedFile
        }
        let candidate = SessionCandidate(name: intent.session.name, notePath: intent.oldPath, modifiedAt: source.modifiedAt)
        let recorder = installationRecorder(for: intent)
        do { _ = try await sessions.rename(candidate, to: intent.session.name, beforeInstall: recorder) }
        catch {
            // State persistence can fail after installation; keep that committed file.
            guard let recorded = try pending(),
                  let installed = try vault.fileSnapshot(relativePath: recorded.session.notePath, includingContents: false),
                  recorded.isInstalled(installed) else { throw error }
            return recorded
        }
        guard let recorded = try pending() else { throw SessionRenameRecoveryError.changedFile }
        return recorded
    }

    private func abandon(_ intent: Intent, error: any Error) async throws {
        logger.error("Session rename abandoned; preserving note files (\(AppErrorLog.summary(error), privacy: .public))")
        try await cleanup(intent)
        try clear()
    }

    private func cleanup(_ intent: Intent, completed: Bool = false) async throws {
        for stage in intent.previousInstallations + (intent.installation.map { [$0] } ?? []) {
            let parent = (intent.session.notePath as NSString).deletingLastPathComponent
            let path = parent + "/" + stage.temporaryName
            do {
                guard let temporary = try vault.fileSnapshot(relativePath: path, includingContents: false) else { continue }
                let source = try vault.fileSnapshot(relativePath: intent.oldPath, includingContents: false)
                if !completed {
                    // Abandoning may only discard an unswapped staged copy whose original is
                    // still at the old name. Any swapped-out original may hold user edits.
                    guard ManagedFileIdentity(temporary) == stage.installed,
                          source.map(ManagedFileIdentity.init) == stage.original else {
                        logger.error("Session rename temporary retained at \(path, privacy: .private)")
                        continue
                    }
                } else if stage.original == intent.source,
                          source.map(ManagedFileIdentity.init) != intent.source {
                    // Only a confirmed completed install may discard its original backup.
                    let target = try vault.fileSnapshot(relativePath: intent.session.notePath, includingContents: false)
                    guard target.map(intent.isInstalled) == true else {
                        logger.error("Session rename temporary retained at \(path, privacy: .private); original identity absent from old path")
                        continue
                    }
                }
                try await sessions.cleanupRenameTemporary(stage, in: intent.session)
            }
            catch {
                // Cleanup must not block captures or remove an uncertain file.
                logger.error("Session temporary retained at \(path, privacy: .private) (\(AppErrorLog.summary(error), privacy: .public))")
            }
        }
    }

    private func clear() throws {
        do { try FileManager.default.removeItem(at: intentURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

enum SessionRenameRecoveryError: Error {
    case changedFile
}
