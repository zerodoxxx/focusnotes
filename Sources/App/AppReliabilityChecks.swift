import AppKit
import CaptureKit
@_spi(Checks) import Core
@_spi(Checks) import OverlayKit

/// Regressions that run without OCR, model downloads, or system permission prompts.
@MainActor
func checkAppReliability() async throws {
    try checkUnavailableShortcutMenu()
    try checkFolderShortcuts()
    try await checkFolderShortcutActions()
    try checkRelaunchLifecycle()
    try await checkNotesFolder()
    try await checkChangesDuringInitialScan()
    try await checkDraftTerminationVeto()
    try await checkSessionRenameIdentity()
    try await checkSessionRenameCrashBoundaries()
    try await checkSessionRenameAbandonment()
    try await checkSessionPickerEscapeRestoresSelection()
    try await checkOutsideCaptureInboxCollisions()
    try await checkFixedCapturePreparationBypassesRouting()
}

@MainActor
private func checkOutsideCaptureInboxCollisions() async throws {
    for image in [false, true] {
        for nestedInbox in [false, true] {
            for completion in ["escape", "shutdown", "replay"] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("outside-inbox-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let vaultRoot = root.appendingPathComponent("Vault"), state = root.appendingPathComponent("State")
                let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
                let session = try await pipeline.sessions.start(name: "Inbox")
                let sessionURL = vaultRoot.appendingPathComponent(session.notePath)
                let sessionBefore = try Data(contentsOf: sessionURL)
                let sessionStateURL = state.appendingPathComponent("session.json")
                let sessionStateBefore = try Data(contentsOf: sessionStateURL)
                let persistedSessions = SessionStore(stateDirectory: state, vault: pipeline.vault,
                                                     calendar: pipeline.calendar, now: Date.init)
                guard let persistedSessionBefore = await persistedSessions.current() else {
                    throw SelfTestFailure("Outside capture check could not reload its initial session")
                }
                let nestedURL = vaultRoot.appendingPathComponent("science/Inbox.md")
                let nestedBefore = Data("# Inbox\n\nKeep this nested note unchanged.\n".utf8)
                if nestedInbox {
                    try FileManager.default.createDirectory(at: nestedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try nestedBefore.write(to: nestedURL)
                }
                let png = Data([137, 80, 78, 71])
                let capture = PendingCapture(trigger: image ? .region : .selection,
                                             content: image ? .image(png: png, ocr: "outside recovery OCR") : .text("outside recovery capture"),
                                             source: CaptureSource(appName: "Outside collision check", windowTitle: nil), subtitle: "check")
                // Escape runs the actual picker callback; other cases need no panel.
                let controller = AppController(pipeline: pipeline, presentsUI: completion == "escape")
                defer { controller.inputForChecks?.dismiss() }
                await controller.stage(capture, outsideSession: true)
                let records = try await pipeline.journal.recordURLs()
                guard records.count == 1 else { throw SelfTestFailure("Outside capture was not journaled before choosing a note") }
                let journaled = try await pipeline.journal.load(record: records[0])
                let inbox = Destination(url: pipeline.vault.inboxURL, title: Vault.inboxTitle, kind: .inbox)
                guard journaled.prepared.destination == inbox, await pipeline.sessions.current() == session else {
                    throw SelfTestFailure("Outside default matched a session or nested note named Inbox")
                }
                if completion == "escape" {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while controller.inputForChecks == nil, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard let input = controller.inputForChecks,
                          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53) else {
                        throw SelfTestFailure("Outside capture did not present its picker")
                    }
                    _ = input.handleKeyForChecks(event)
                    while controller.inputForChecks != nil, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard controller.inputForChecks == nil else {
                        throw SelfTestFailure("Escape did not finish the outside capture picker callback")
                    }
                    _ = await controller.beginTermination().value
                } else if completion == "shutdown" {
                    _ = await controller.beginTermination().value
                }
                let reopened = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
                let restored = await reopened.replayUnsaved()
                let scenario = "\(completion), image=\(image), nestedInbox=\(nestedInbox)"
                let expectedRestored = completion == "replay" ? 1 : 0
                guard restored == expectedRestored else {
                    throw SelfTestFailure("Outside capture (\(scenario)) replayed \(restored) records; expected \(expectedRestored)")
                }
                let savedPath = try await reopened.index.capture(id: capture.id)?.notePath
                guard savedPath == "Inbox.md" else {
                    throw SelfTestFailure("Outside capture (\(scenario)) resolved to \(savedPath ?? "no indexed capture"); expected Inbox.md")
                }
                guard try Data(contentsOf: sessionURL) == sessionBefore else {
                    throw SelfTestFailure("Outside capture (\(scenario)) modified the active session note")
                }
                let reopenedSession = await reopened.sessions.current()
                guard await pipeline.sessions.current() == session else {
                    throw SelfTestFailure("Outside capture (\(scenario)) changed the live active session")
                }
                guard try Data(contentsOf: sessionStateURL) == sessionStateBefore else {
                    throw SelfTestFailure("Outside capture (\(scenario)) changed the persisted session bytes")
                }
                // Session persistence uses whole-second ISO 8601 dates. Compare
                // two loaded values, rather than Date()'s original fractions.
                guard reopenedSession == persistedSessionBefore else {
                    throw SelfTestFailure("Outside capture (\(scenario)) changed the reloaded session; expected \(persistedSessionBefore.notePath), got \(reopenedSession?.notePath ?? "none")")
                }
                if nestedInbox, try Data(contentsOf: nestedURL) != nestedBefore {
                    throw SelfTestFailure("Outside capture modified a nested note named Inbox")
                }
                if image {
                    guard case .image(let asset) = journaled.prepared.capture.content,
                          try await reopened.assetData(asset) == png else {
                        throw SelfTestFailure("Outside image recovery lost its pixels")
                    }
                }
            }
        }
    }
}

@MainActor
private func checkFixedCapturePreparationBypassesRouting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixed-capture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("State")
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"), stateDirectory: state, calendar: .current)
    let registry = state.appendingPathComponent("external-notes.json")
    let invalidRegistry = Data("{invalid JSON".utf8)
    try invalidRegistry.write(to: registry)
    let probe = Capture(id: UUID(), createdAt: Date(), content: .text("routing probe"),
                        source: CaptureSource(appName: "Fixed routing check", windowTitle: nil))
    do {
        _ = try await pipeline.service.prepare(probe, noteTitle: nil)
        throw SelfTestFailure("Routing probe unexpectedly accepted a damaged registry")
    } catch is ExternalNoteRegistryError {}
    let inboxBefore = try Data(contentsOf: pipeline.vault.inboxURL)
    let inbox = Destination(url: pipeline.vault.inboxURL, title: Vault.inboxTitle, kind: .inbox)
    for image in [false, true] {
        let capture = PendingCapture(trigger: image ? .region : .selection,
                                     content: image ? .image(png: Data([137, 80, 78, 71]), ocr: nil) : .text("fixed capture"),
                                     source: CaptureSource(appName: "Fixed routing check", windowTitle: nil), subtitle: "check")
        let outside = try await pipeline.prepare(capture, noteTitle: nil, outsideSession: true)
        let fixed = try await pipeline.prepare(capture, noteTitle: "../invalid", destination: inbox)
        guard outside.prepared.destination == inbox, fixed.prepared.destination == inbox,
              try Data(contentsOf: registry) == invalidRegistry,
              try Data(contentsOf: pipeline.vault.inboxURL) == inboxBefore,
              try FileManager.default.contentsOfDirectory(atPath: pipeline.vault.root.appendingPathComponent("assets").path).isEmpty else {
            throw SelfTestFailure("Fixed preparation routed or wrote files before honoring its destination")
        }
    }
}

private enum RenameCheckError: Error { case originalFailure }

@MainActor
private func checkSessionRenameCrashBoundaries() async throws {
    for checkpoint in ["after-swap", "caught-after-swap", "caught-recovery-error", "after-move", "unrelated-target", "cleanup-error",
                       "persist-failure", "pre-install-conflict", "after-swap-conflict"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-checkpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Vault"), state = root.appendingPathComponent("State")
        let pipeline = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
        let source = try await pipeline.sessions.start(name: "archive/Standup")
        let candidate = SessionCandidate(name: source.name, notePath: source.notePath, modifiedAt: .distantPast)
        let oldURL = vault.appendingPathComponent(source.notePath)
        let body = "\noriginal bytes\n![](../../assets/screen.png)\n"
        let writer = try FileHandle(forWritingTo: oldURL)
        try writer.seekToEnd(); try writer.write(contentsOf: Data(body.utf8)); try writer.close()
        let destination = try await pipeline.sessions.renameDestination(candidate, to: "Daily sync")
        let targetURL = vault.appendingPathComponent(destination.notePath)
        if checkpoint == "cleanup-error" {
            let intentURL = state.appendingPathComponent("session-rename.json")
            do {
                _ = try await pipeline.renameSession(candidate, to: "Daily sync", preparedJobs: [], beforeInstall: { _ in
                    try Data("{invalid JSON".utf8).write(to: intentURL, options: .atomic)
                    throw RenameCheckError.originalFailure
                })
                throw SelfTestFailure("Rename hid its original staging failure")
            } catch RenameCheckError.originalFailure {}
            let quarantined = state.appendingPathComponent("unsaved/corrupt/session-rename.json")
            guard try String(contentsOf: oldURL, encoding: .utf8) == "# Standup\n" + body,
                  !FileManager.default.fileExists(atPath: intentURL.path),
                  FileManager.default.fileExists(atPath: quarantined.path) else {
                throw SelfTestFailure("Failure cleanup altered the source bytes or kept a corrupt intent in place")
            }
            // A corrupt intent left by a crash must not block startup or the next capture.
            try Data("{invalid JSON".utf8).write(to: intentURL, options: .atomic)
            let reopened = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
            let capture = PendingCapture(trigger: .selection, content: .text("capture after corrupt intent"),
                                         source: CaptureSource(appName: "Rename check", windowTitle: nil), subtitle: "check")
            let saved = try await reopened.commit(try await reopened.prepare(capture, noteTitle: nil))
            let corrupt = try FileManager.default.contentsOfDirectory(atPath: quarantined.deletingLastPathComponent().path)
            guard try await reopened.journal.pendingSessionRename() == nil,
                  !FileManager.default.fileExists(atPath: intentURL.path),
                  corrupt.filter({ $0.hasPrefix("session-rename") }).count == 2,
                  saved.destination.url == oldURL,
                  try String(contentsOf: oldURL, encoding: .utf8).hasPrefix("# Standup\n" + body),
                  try String(contentsOf: oldURL, encoding: .utf8).contains("capture after corrupt intent") else {
                throw SelfTestFailure("A corrupt rename intent blocked startup or the following capture")
            }
            continue
        }
        if checkpoint == "caught-after-swap" {
            let outcome = try await pipeline.renameSession(candidate, to: "Daily sync", preparedJobs: [], afterSwap: {
                throw SessionRenameInterruption.afterSwap
            })
            let pending = try FileManager.default.contentsOfDirectory(atPath: targetURL.deletingLastPathComponent().path)
            guard !outcome.identityUpdatePending, outcome.session.notePath == destination.notePath,
                  await pipeline.sessions.current()?.notePath == destination.notePath,
                  try await pipeline.journal.pendingSessionRename() == nil,
                  !FileManager.default.fileExists(atPath: oldURL.path),
                  try String(contentsOf: targetURL, encoding: .utf8) == "# Daily sync\n" + body,
                  !pending.contains(where: { $0.hasPrefix(".session-") }) else {
                throw SelfTestFailure("Rename catch did not complete the interrupted swap before returning success")
            }
        } else if checkpoint == "caught-recovery-error" {
            let unrelated = Data("# Other owner\nkeep every byte\n".utf8)
            do {
                _ = try await pipeline.renameSession(candidate, to: "Daily sync", preparedJobs: [], afterSwap: {
                    try unrelated.write(to: targetURL, options: .atomic)
                    throw SessionRenameInterruption.afterSwap
                })
                throw SelfTestFailure("A failed swap recovery hid the original rename error")
            } catch SessionRenameInterruption.afterSwap {}
            // The blocked resume abandons: the half-applied rename stays put with its backup.
            let temporaries = try FileManager.default.contentsOfDirectory(at: oldURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".session-") }
            let renamedBytes = "# Daily sync\n" + body
            guard try await pipeline.journal.pendingSessionRename() == nil,
                  try String(contentsOf: oldURL, encoding: .utf8) == renamedBytes,
                  temporaries.count == 1, try String(contentsOf: temporaries[0], encoding: .utf8) == "# Standup\n" + body,
                  try Data(contentsOf: targetURL) == unrelated else {
                throw SelfTestFailure("Failed swap recovery kept a blocking intent or lost the original backup or unrelated target")
            }
            let reopened = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
            guard try await reopened.journal.pendingSessionRename() == nil,
                  try Data(contentsOf: targetURL) == unrelated,
                  try String(contentsOf: oldURL, encoding: .utf8) == renamedBytes,
                  try String(contentsOf: temporaries[0], encoding: .utf8) == "# Standup\n" + body else {
                throw SelfTestFailure("Reopen after an abandoned swap recovery changed files or retained its intent")
            }
            continue
        } else if checkpoint == "persist-failure" {
            // Session state persistence fails after the file is installed: still a committed rename.
            let stateFile = state.appendingPathComponent("session.json")
            try? FileManager.default.removeItem(at: stateFile)
            try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
            let outcome = try await pipeline.renameSession(candidate, to: "Daily sync", preparedJobs: [])
            guard outcome.identityUpdatePending, outcome.session.notePath == destination.notePath,
                  !FileManager.default.fileExists(atPath: oldURL.path),
                  try String(contentsOf: targetURL, encoding: .utf8) == "# Daily sync\n" + body,
                  try await pipeline.journal.pendingSessionRename() != nil else {
                throw SelfTestFailure("A committed rename with failed state persistence was reported as a failure")
            }
            try FileManager.default.removeItem(at: stateFile)
        } else {
            let intent = try await pipeline.journal.beginSessionRename(oldPath: source.notePath, session: destination,
                                                                      vault: pipeline.vault, preparedJobs: [])
            let recorder = await pipeline.journal.installationRecorder(for: intent)
            if checkpoint == "after-swap" || checkpoint == "after-swap-conflict" {
                do {
                    _ = try await pipeline.sessions.rename(candidate, to: "Daily sync", beforeInstall: recorder,
                                                           afterSwap: { throw SessionRenameInterruption.afterSwap })
                    throw SelfTestFailure("The simulated crash checkpoint did not interrupt rename")
                } catch SessionRenameInterruption.afterSwap {}
                let pending = try FileManager.default.contentsOfDirectory(atPath: oldURL.deletingLastPathComponent().path)
                guard pending.contains(where: { $0.hasPrefix(".session-") }), !FileManager.default.fileExists(atPath: targetURL.path) else {
                    throw SelfTestFailure("Swap checkpoint did not retain the original backup and old filename")
                }
            }
            if checkpoint == "after-swap" {
                do {
                    try await pipeline.recoverSessionIdentity()
                    throw SelfTestFailure("Capture preparation bypassed an unfinished swap")
                } catch SessionRenameRecoveryError.changedFile {}
                guard try await pipeline.journal.pendingSessionRename() != nil else {
                    throw SelfTestFailure("Capture preparation abandoned an unfinished swap")
                }
            } else if checkpoint != "after-swap-conflict" && checkpoint != "pre-install-conflict" {
                _ = try await pipeline.sessions.rename(candidate, to: "Daily sync", beforeInstall: recorder)
            }
        }
        if checkpoint.hasSuffix("-conflict") {
            // A user file appears at the target before startup resumes the rename.
            let unrelated = Data("# Other owner\nkeep every byte\n".utf8)
            try unrelated.write(to: targetURL, options: .atomic)
            let oldBytes = try Data(contentsOf: oldURL)
            func temporaries() throws -> [String: Data] {
                var found: [String: Data] = [:]
                for url in try FileManager.default.contentsOfDirectory(at: oldURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix(".session-") { found[url.lastPathComponent] = try Data(contentsOf: url) }
                return found
            }
            let before = try temporaries()
            let reopened = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
            let original = Data(("# Standup\n" + body).utf8)
            guard try await reopened.journal.pendingSessionRename() == nil,
                  try Data(contentsOf: targetURL) == unrelated,
                  try Data(contentsOf: oldURL) == oldBytes,
                  try temporaries() == before,
                  checkpoint == "pre-install-conflict" ? oldBytes == original : before.values.contains(original) else {
                throw SelfTestFailure("A target conflict blocked startup or changed note files and backups")
            }
            continue
        }
        if checkpoint == "unrelated-target" {
            let unrelated = "# Other owner\nkeep every byte\n"
            try Data(unrelated.utf8).write(to: targetURL, options: .atomic)
            let reopened = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
            guard try await reopened.journal.pendingSessionRename() == nil,
                  !FileManager.default.fileExists(atPath: oldURL.path),
                  try String(contentsOf: targetURL, encoding: .utf8) == unrelated else {
                throw SelfTestFailure("Abandoned recovery changed the unrelated target or retained its intent")
            }
            continue
        }
        let reopened = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
        let again = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
        let bytes = try String(contentsOf: targetURL, encoding: .utf8)
        let pending = try FileManager.default.contentsOfDirectory(atPath: targetURL.deletingLastPathComponent().path)
        guard bytes == "# Daily sync\n" + body, !pending.contains(where: { $0.hasPrefix(".session-") }),
              !FileManager.default.fileExists(atPath: oldURL.path),
              await reopened.sessions.current()?.notePath == destination.notePath,
              await again.sessions.current()?.notePath == destination.notePath,
              try await reopened.journal.pendingSessionRename() == nil,
              try await again.journal.pendingSessionRename() == nil else {
            throw SelfTestFailure("Checkpoint recovery lost bytes, left an orphan, or was not idempotent")
        }
    }
}

@MainActor
private func checkSessionRenameAbandonment() async throws {
    for scenario in ["editor-replacement", "missing-target", "unknown-target"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-abandon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Vault"), state = root.appendingPathComponent("State")
        let pipeline = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
        let session = try await pipeline.sessions.start(name: "archive/Original")
        let candidate = SessionCandidate(name: session.name, notePath: session.notePath, modifiedAt: .distantPast)
        let oldURL = vault.appendingPathComponent(session.notePath)
        let original = Data("# Original\noriginal body\n".utf8)
        let edited = Data("# Editor\nkeep these bytes\n".utf8)
        try original.write(to: oldURL)
        let destination = try await pipeline.sessions.renameDestination(candidate, to: "Renamed")
        let targetURL = vault.appendingPathComponent(destination.notePath)
        let recovered: CapturePipeline
        if scenario == "editor-replacement" {
            do {
                _ = try await pipeline.renameSession(candidate, to: "Renamed", preparedJobs: [], afterSwap: {
                    try edited.write(to: oldURL, options: .atomic)
                })
                throw SelfTestFailure("Rename hid the original post-swap failure")
            } catch let error as POSIXError where error.code == .EAGAIN {}
            guard try await pipeline.journal.pendingSessionRename() == nil,
                  try Data(contentsOf: oldURL) == edited,
                  !FileManager.default.fileExists(atPath: targetURL.path) else {
                throw SelfTestFailure("Failed rename retained its intent or changed the editor's bytes")
            }
            recovered = pipeline
        } else {
            let intent = try await pipeline.journal.beginSessionRename(oldPath: session.notePath, session: destination,
                                                                      vault: pipeline.vault, preparedJobs: [])
            let recorder = await pipeline.journal.installationRecorder(for: intent)
            do {
                _ = try await pipeline.sessions.rename(candidate, to: "Renamed", beforeInstall: recorder,
                                                       afterSwap: { throw SessionRenameInterruption.afterSwap })
                throw SelfTestFailure("Missing-source checkpoint did not interrupt rename")
            } catch SessionRenameInterruption.afterSwap {}
            try FileManager.default.removeItem(at: oldURL)
            if scenario == "unknown-target" { try edited.write(to: targetURL) }
            recovered = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
            guard try await recovered.journal.pendingSessionRename() == nil,
                  !FileManager.default.fileExists(atPath: oldURL.path) else {
                throw SelfTestFailure("Missing-source recovery retained its intent or recreated the source")
            }
            if scenario == "unknown-target" {
                guard try Data(contentsOf: targetURL) == edited else { throw SelfTestFailure("Recovery changed an unknown target") }
            } else if FileManager.default.fileExists(atPath: targetURL.path) {
                throw SelfTestFailure("Recovery created a missing target")
            }
        }
        let temporaries = try FileManager.default.contentsOfDirectory(at: oldURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".session-") }
        guard temporaries.count == 1, try Data(contentsOf: temporaries[0]) == original else {
            throw SelfTestFailure("Abandoning rename deleted the only copy of the original bytes")
        }
        if scenario == "editor-replacement" {
            let capture = PendingCapture(trigger: .selection, content: .text("capture after rollback"),
                                         source: CaptureSource(appName: "Rename check", windowTitle: nil), subtitle: "check")
            let job = try await recovered.prepare(capture, noteTitle: nil)
            let saved = try await recovered.commit(job)
            guard saved.destination.url == oldURL,
                  try Data(contentsOf: oldURL).starts(with: edited),
                  try String(contentsOf: oldURL, encoding: .utf8).contains("capture after rollback"),
                  try Data(contentsOf: temporaries[0]) == original else {
                throw SelfTestFailure("Capture after abandoning rollback failed or lost the retained original")
            }
            let reopened = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
            guard try await reopened.journal.pendingSessionRename() == nil else {
                throw SelfTestFailure("Abandoned rollback blocked the next startup")
            }
        }
    }
}

@MainActor
private func checkSessionPickerEscapeRestoresSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-picker-escape-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let first = try await pipeline.sessions.start(name: "Standup")
    let second = try await pipeline.sessions.start(name: "archive/Standup")
    try await pipeline.sessions.end()
    let candidates = [first, second].map { SessionCandidate(name: $0.name, notePath: $0.notePath, modifiedAt: .distantPast) }
    let controller = AppController(pipeline: pipeline, presentsUI: false)
    controller.presentSessionCandidates(candidates)
    defer { controller.inputForChecks?.dismiss() }
    func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
        guard let input = controller.inputForChecks,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else {
            throw SelfTestFailure("Session-picker controller did not present input")
        }
        _ = input.handleKeyForChecks(event)
    }
    try key(125); try key(125)
    guard controller.inputForChecks?.selectedValueForChecks == second.notePath else { throw SelfTestFailure("Second same-title session was not highlighted") }
    try key(36, modifiers: .command)
    try await Task.sleep(for: .milliseconds(350))
    try key(53)
    try await Task.sleep(for: .milliseconds(350))
    guard controller.inputForChecks?.selectedValueForChecks == second.notePath, await pipeline.sessions.current() == nil else {
        throw SelfTestFailure("Escape from rename did not restore the original picker selection without activating a session")
    }
}

@MainActor
private func checkSessionRenameIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-session-rename-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultRoot = root.appendingPathComponent("Vault")
    let state = root.appendingPathComponent("State")
    let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    let original = try await pipeline.sessions.start(name: "archive/Standup")
    let oldURL = vaultRoot.appendingPathComponent(original.notePath)
    let candidate = SessionCandidate(name: original.name, notePath: original.notePath, modifiedAt: .distantPast)
    try pipeline.pins.set(original.notePath, pinned: true)
    _ = try await pipeline.index.sync()
    let capture = Capture(id: UUID(), createdAt: Date(), content: .text("queuedrenameneedle"),
                          source: CaptureSource(appName: "Rename check", windowTitle: nil))
    let prepared = PreparedCapture(capture: capture, destination: Destination(url: oldURL, title: original.name, kind: .session),
                                   noteMarkerIsIdentity: true)
    let job = CaptureJob(prepared: prepared, png: nil, ocr: nil, noteDraft: "retain draft metadata")
    try await pipeline.journal.store(job)
    // An unrelated malformed job must not block an otherwise valid rename.
    let corrupt = state.appendingPathComponent("unsaved/unrelated.json")
    try Data("{invalid".utf8).write(to: corrupt)
    let outcome = try await pipeline.renameSession(candidate, to: "Daily sync", preparedJobs: [job])
    let newPath = "Sessions/archive/Daily sync.md"
    guard !outcome.identityUpdatePending, outcome.session.notePath == newPath,
          pipeline.pins.isPinned(newPath), !pipeline.pins.isPinned(original.notePath),
          await pipeline.sessions.current()?.notePath == newPath else {
        throw SelfTestFailure("Session rename did not migrate pins and active identity")
    }
    let suggestions = try await pipeline.index.titleSuggestions(prefix: "", limit: Int.max)
    guard suggestions.contains(where: { $0.path == newPath && $0.title == "Daily sync" }),
          !suggestions.contains(where: { $0.path == original.notePath }) else {
        throw SelfTestFailure("Session rename left its old search identity or failed to index the new heading")
    }
    let redirected = try await pipeline.journal.redirected(job)
    guard redirected.prepared.capture == capture, redirected.prepared.destination.url == vaultRoot.appendingPathComponent(newPath),
          redirected.prepared.noteMarkerIsIdentity == true, redirected.noteDraft == job.noteDraft else {
        throw SelfTestFailure("Session rename changed capture identity or lost prepared metadata")
    }
    // Store and commit a stale in-memory preparation after the rename. Both
    // paths must resolve the UUID redirect without recreating the old filename.
    try await pipeline.journal.store(job)
    let recordURL = state.appendingPathComponent("unsaved/\(capture.id.uuidString.lowercased()).json")
    let persisted = try await pipeline.journal.load(record: recordURL)
    guard persisted.prepared.destination.url == redirected.prepared.destination.url else {
        throw SelfTestFailure("A stale journal write restored the old session destination")
    }
    let saved = try await pipeline.commit(job)
    guard saved.destination.url == vaultRoot.appendingPathComponent(newPath),
          !FileManager.default.fileExists(atPath: oldURL.path),
          try String(contentsOf: saved.destination.url, encoding: .utf8).contains("queuedrenameneedle") else {
        throw SelfTestFailure("A stale prepared capture recreated the old session after rename")
    }

    // Simulate a crash after the Markdown move and before any identity updates.
    let recoverySession = try await pipeline.sessions.start(name: "archive/Recovery")
    let recoveryCandidate = SessionCandidate(name: recoverySession.name, notePath: recoverySession.notePath, modifiedAt: .distantPast)
    try pipeline.pins.set(recoverySession.notePath, pinned: true)
    let recoveryCapture = Capture(id: UUID(), createdAt: Date(), content: .text("recoveredrenamecapture"), source: capture.source)
    let recoveryJob = CaptureJob(prepared: PreparedCapture(capture: recoveryCapture,
                                                          destination: Destination(url: vaultRoot.appendingPathComponent(recoverySession.notePath),
                                                                                   title: recoverySession.name, kind: .session)), png: nil, ocr: nil)
    try await pipeline.journal.store(recoveryJob)
    let planned = try await pipeline.sessions.renameDestination(recoveryCandidate, to: "Recovered")
    let intent = try await pipeline.journal.beginSessionRename(oldPath: recoverySession.notePath, session: planned,
                                                              vault: pipeline.vault, preparedJobs: [recoveryJob])
    let recorder = await pipeline.journal.installationRecorder(for: intent)
    _ = try await pipeline.sessions.rename(recoveryCandidate, to: "Recovered", beforeInstall: recorder)
    let reopened = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    guard try await reopened.journal.pendingSessionRename() == nil,
          reopened.pins.isPinned(planned.notePath), !reopened.pins.isPinned(recoverySession.notePath),
          await reopened.sessions.current()?.notePath == planned.notePath,
          !FileManager.default.fileExists(atPath: state.appendingPathComponent("capture-destinations.json").path) else {
        throw SelfTestFailure("Startup did not complete a committed session rename and prune previous-process redirects")
    }
    let replayed = await reopened.replayUnsaved()
    guard replayed == 1, !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(recoverySession.notePath).path),
          try String(contentsOf: vaultRoot.appendingPathComponent(planned.notePath), encoding: .utf8).contains("recoveredrenamecapture") else {
        throw SelfTestFailure("Journal recovery did not keep captures on the renamed session")
    }

    // Simulate a crash before file installation. Recovery may finish the user's
    // request only while the recorded original identity and contents still match.
    let before = try await reopened.sessions.start(name: "archive/Before install")
    let beforeCandidate = SessionCandidate(name: before.name, notePath: before.notePath, modifiedAt: .distantPast)
    let beforeTarget = try await reopened.sessions.renameDestination(beforeCandidate, to: "After install")
    _ = try await reopened.journal.beginSessionRename(oldPath: before.notePath, session: beforeTarget,
                                                     vault: reopened.vault, preparedJobs: [])
    // A rollback swap (or a harmless touch) updates inode timestamps. Its
    // unchanged bytes still prove that this is the recorded original note.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                         ofItemAtPath: vaultRoot.appendingPathComponent(before.notePath).path)
    let finished = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    guard await finished.sessions.current()?.notePath == beforeTarget.notePath,
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(before.notePath).path) else {
        throw SelfTestFailure("Startup did not safely resume a staged rename before installation")
    }

    let repeated = try await finished.sessions.start(name: "archive/Repeated A")
    let unstagedCapture = Capture(id: UUID(), createdAt: Date(), content: .text("unstaged repeated rename"), source: capture.source)
    let unstaged = CaptureJob(prepared: PreparedCapture(capture: unstagedCapture,
                                                       destination: Destination(url: vaultRoot.appendingPathComponent(repeated.notePath),
                                                                                title: repeated.name, kind: .session)), png: nil, ocr: nil)
    let repeatedA = SessionCandidate(name: repeated.name, notePath: repeated.notePath, modifiedAt: .distantPast)
    let firstRename = try await finished.renameSession(repeatedA, to: "Repeated B", preparedJobs: [unstaged])
    let repeatedB = SessionCandidate(name: firstRename.session.name, notePath: firstRename.session.notePath, modifiedAt: .distantPast)
    let secondRename = try await finished.renameSession(repeatedB, to: "Repeated C", preparedJobs: [unstaged])
    let repeatedSaved = try await finished.commit(unstaged)
    guard repeatedSaved.destination.url == vaultRoot.appendingPathComponent(secondRename.session.notePath),
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(repeated.notePath).path),
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(firstRename.session.notePath).path) else {
        throw SelfTestFailure("Repeated renames did not update an unstaged in-memory capture's existing UUID redirect")
    }

    // If metadata storage fails after installation, every preparation entry
    // point must finish recovery before it can route a newly acquired UUID.
    try finished.pins.set(secondRename.session.notePath, pinned: true)
    let pinBackup = state.appendingPathComponent("saved-pins.json")
    try FileManager.default.moveItem(at: finished.pins.url, to: pinBackup)
    try FileManager.default.createDirectory(at: finished.pins.url, withIntermediateDirectories: false)
    let pendingCandidate = SessionCandidate(name: secondRename.session.name, notePath: secondRename.session.notePath, modifiedAt: .distantPast)
    let pendingOutcome = try await finished.renameSession(pendingCandidate, to: "Waiting metadata", preparedJobs: [])
    guard pendingOutcome.identityUpdatePending,
          await finished.sessions.current()?.notePath == pendingOutcome.session.notePath else {
        throw SelfTestFailure("A metadata failure did not retain the installed session identity and recovery intent")
    }
    let pendingCapture = PendingCapture(trigger: .selection, content: .text("new UUID after rename"), source: capture.source, subtitle: "check")
    let directCapture = Capture(id: UUID(), createdAt: Date(), content: .note("typed UUID after rename"), source: capture.source)
    do {
        _ = try await finished.prepare(pendingCapture, noteTitle: nil)
        throw SelfTestFailure("Capture preparation routed around an unfinished rename")
    } catch let error as CocoaError {
        guard error.code == .fileReadUnknown || error.code == .fileReadNoPermission else { throw error }
    }
    do {
        _ = try await finished.prepareNote(directCapture, destination: nil, newNote: false)
        throw SelfTestFailure("Typed-note preparation routed around an unfinished rename")
    } catch let error as CocoaError {
        guard error.code == .fileReadUnknown || error.code == .fileReadNoPermission else { throw error }
    }
    do {
        _ = try await finished.prepareCapture(directCapture, destination: nil)
        throw SelfTestFailure("Subheading preparation routed around an unfinished rename")
    } catch let error as CocoaError {
        guard error.code == .fileReadUnknown || error.code == .fileReadNoPermission else { throw error }
    }
    try FileManager.default.removeItem(at: finished.pins.url)
    try FileManager.default.moveItem(at: pinBackup, to: finished.pins.url)
    let afterRepair = try await finished.prepare(pendingCapture, noteTitle: nil)
    guard afterRepair.prepared.destination.url == vaultRoot.appendingPathComponent(pendingOutcome.session.notePath),
          finished.pins.isPinned(pendingOutcome.session.notePath),
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(secondRename.session.notePath).path) else {
        throw SelfTestFailure("Preparation did not recover pin metadata and route to the installed session after storage repair")
    }

    let changed = try await finished.sessions.start(name: "archive/Changed source")
    let changedCandidate = SessionCandidate(name: changed.name, notePath: changed.notePath, modifiedAt: .distantPast)
    let changedTarget = try await finished.sessions.renameDestination(changedCandidate, to: "Must not move")
    _ = try await finished.journal.beginSessionRename(oldPath: changed.notePath, session: changedTarget,
                                                     vault: finished.vault, preparedJobs: [])
    let changedURL = vaultRoot.appendingPathComponent(changed.notePath)
    let writer = try FileHandle(forWritingTo: changedURL)
    try writer.seekToEnd()
    try writer.write(contentsOf: Data("external edit after intent\n".utf8))
    try writer.close()
    let edited = try Data(contentsOf: changedURL)
    let afterDrift = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    guard try await afterDrift.journal.pendingSessionRename() == nil,
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(changedTarget.notePath).path),
          try Data(contentsOf: changedURL) == edited else {
        throw SelfTestFailure("Abandoned rename recovery retained its intent or altered the edited source")
    }
    let next = PendingCapture(trigger: .selection, content: .text("capture after drift"), source: capture.source, subtitle: "check")
    let nextJob = try await afterDrift.prepare(next, noteTitle: nil)
    let nextSaved = try await afterDrift.commit(nextJob)
    guard nextSaved.destination.url == changedURL, try Data(contentsOf: changedURL).starts(with: edited),
          try String(contentsOf: changedURL, encoding: .utf8).contains("capture after drift"),
          !FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(changedTarget.notePath).path) else {
        throw SelfTestFailure("Capture after abandoning a drifted rename did not commit to the edited session")
    }
}

@MainActor
private func checkRelaunchLifecycle() throws {
    var launches = 0
    let lifecycle = RelaunchLifecycle { launches += 1 }
    lifecycle.request()
    guard launches == 0 else {
        throw SelfTestFailure("A relaunch must wait until AppKit confirms termination")
    }
    lifecycle.terminationWasVetoed()
    lifecycle.applicationWillTerminate()
    guard launches == 0 else {
        throw SelfTestFailure("A vetoed termination must discard its pending relaunch")
    }

    lifecycle.request()
    guard launches == 0 else {
        throw SelfTestFailure("A slow shutdown must not launch another app instance while it is draining")
    }
    lifecycle.applicationWillTerminate()
    lifecycle.applicationWillTerminate()
    guard launches == 1 else {
        throw SelfTestFailure("An accepted termination must launch exactly one replacement instance")
    }
}

@MainActor
private func checkUnavailableShortcutMenu() throws {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    AppController.configureShortcut(item, title: "Capture Selection", hotkey: .captureSelection, failure: .conflict)
    guard item.title == "Capture Selection", item.keyEquivalent.isEmpty,
          item.keyEquivalentModifierMask.isEmpty, item.toolTip?.contains("Another app") == true,
          item.toolTip?.contains("Retry Shortcuts") == true else {
        throw SelfTestFailure("Conflicting shortcuts must retain their menu command, explain recovery, and omit the unavailable key")
    }
    AppController.configureShortcut(item, title: "Capture Selection", hotkey: .captureSelection, failure: nil)
    guard item.keyEquivalent == "c", item.keyEquivalentModifierMask == [.option, .shift], item.toolTip == nil else {
        throw SelfTestFailure("A recovered shortcut must regain its menu key and clear its failure message")
    }
    AppController.configureShortcut(item, title: "End Session", hotkey: .toggleSession, failure: .registrationFailed(status: -1))
    guard item.title == "End Session", item.keyEquivalent.isEmpty,
          item.toolTip?.contains("macOS could not register") == true else {
        throw SelfTestFailure("Non-conflict registration failures must also explain the unavailable shortcut")
    }
    for hotkey in [Hotkey.captureSelectionOutsideSession, .captureRegionOutsideSession] {
        AppController.configureShortcut(item, title: "Capture Outside Session", hotkey: hotkey, failure: .conflict)
        guard item.keyEquivalent.isEmpty, item.toolTip?.contains("Retry Shortcuts") == true else {
            throw SelfTestFailure("Outside-session capture conflicts must expose shortcut recovery")
        }
        AppController.configureShortcut(item, title: "Capture Outside Session", hotkey: hotkey, failure: nil)
        guard item.keyEquivalent == hotkey.menuKeyEquivalent, item.keyEquivalentModifierMask == [.control, .shift] else {
            throw SelfTestFailure("Retry must restore the outside-session capture shortcut")
        }
    }
}

private actor InitialScanRecorder {
    private var passes = 0
    private var released = false
    private var firstPass: CheckedContinuation<Void, Never>?
    private var noteOnlyAssetRefresh = false
    private var scanFailure: String?

    func scan(_ request: VaultRefreshRequest, index: SearchIndex) async {
        guard request.notes else { return }
        do { _ = try await index.sync() }
        catch { scanFailure = String(describing: error) }
        if request.assets, request.recheckingAssetPaths?.isEmpty == true {
            noteOnlyAssetRefresh = true
        }
        passes += 1
        if passes == 1, !released {
            await withCheckedContinuation { firstPass = $0 }
        }
    }
    func count() -> Int { passes }
    func sawNoteOnlyAssetRefresh() -> Bool { noteOnlyAssetRefresh }
    func failure() -> String? { scanFailure }
    func release() { released = true; firstPass?.resume(); firstPass = nil }
}

@MainActor
private func checkChangesDuringInitialScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-startup-\(UUID().uuidString)", isDirectory: true)
    let vault = Vault(root: root)
    try vault.prepare()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = InitialScanRecorder()
    defer { Task { await recorder.release() } }
    let original = try await CapturePipeline.open(vaultRoot: root, stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let monitor = VaultMonitor(vault: vault) { request in await recorder.scan(request, index: original.index) }
    defer { monitor.stop() }
    let pipeline = CapturePipeline(vault: original.vault, sessions: original.sessions, service: original.service,
                                   index: original.index, semantic: original.semantic, monitor: monitor,
                                   journal: original.journal, drafts: original.drafts, pins: original.pins,
                                   calendar: original.calendar, logger: original.logger)
    let controller = AppController(pipeline: pipeline, presentsUI: false)
    let initialSync = Task { await controller.start() }
    let initialDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await recorder.count() == 0, ContinuousClock.now < initialDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard await recorder.count() == 1 else {
        await recorder.release()
        throw SelfTestFailure("Initial index scan did not begin")
    }
    guard monitor.isRunning else {
        await recorder.release()
        throw SelfTestFailure("The vault watcher must already be running when the initial index scan begins")
    }
    guard try await pipeline.index.search("startupeventneedle").isEmpty else {
        await recorder.release()
        throw SelfTestFailure("The startup regression needle was indexed before its note existed")
    }
    try Data("# During startup\n\nstartupeventneedle\n".utf8).write(to: root.appendingPathComponent("During startup.md"))
    // Keep the first scan suspended through the watcher's event latency. The event
    // must become a second pass, rather than disappear behind the in-flight scan.
    try await Task.sleep(for: .milliseconds(1600))
    await recorder.release()
    _ = await initialSync.value
    let reconcileDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await recorder.count() < 2, ContinuousClock.now < reconcileDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard await recorder.count() >= 2 else {
        throw SelfTestFailure("A vault change received during startup did not trigger reconciliation")
    }
    guard await recorder.failure() == nil,
          try await pipeline.index.search("startupeventneedle").contains(where: { $0.notePath == "During startup.md" }) else {
        throw SelfTestFailure("The note created during the initial scan did not become searchable through watcher reconciliation")
    }
    guard await recorder.sawNoteOnlyAssetRefresh() else {
        throw SelfTestFailure("A note-only event must check new image references without rehashing unchanged assets")
    }
}

@MainActor
private func checkDraftTerminationVeto() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-quit-\(UUID().uuidString)", isDirectory: true)
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let oldText = "Previously saved draft"
    let latestText = "Latest text that must survive a failed quit"
    try pipeline.drafts.store(oldText)
    let oldDraft = try Data(contentsOf: pipeline.drafts.url)
    let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
    let controller = AppController(pipeline: pipeline, presentsUI: false)
    pipeline.monitor.start()
    controller.openNoteEditor()
    var panel: OverlayPanel?
    defer {
        // Restore a writable path before dismissing, including when an assertion fails.
        if (try? pipeline.drafts.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? FileManager.default.removeItem(at: pipeline.drafts.url)
        }
        panel?.dismiss(animated: false)
        pipeline.monitor.stop()
        try? FileManager.default.removeItem(at: root)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while panel == nil, ContinuousClock.now < deadline {
        panel = NSApp.windows.compactMap { $0 as? OverlayPanel }.first {
            $0.isVisible && !existingWindows.contains(ObjectIdentifier($0))
        }
        if panel == nil { try await Task.sleep(for: .milliseconds(20)) }
    }
    func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    guard let panel, let content = panel.contentView, let text = textView(in: content), text.string == oldText else {
        throw SelfTestFailure("Could not open the restored editor for the quit regression")
    }
    text.string = latestText
    try FileManager.default.removeItem(at: pipeline.drafts.url)
    try FileManager.default.createDirectory(at: pipeline.drafts.url, withIntermediateDirectories: false)
    try Data("block replacement".utf8).write(to: pipeline.drafts.url.appendingPathComponent("blocker"))
    guard await controller.beginTermination().value == false, panel.isVisible, pipeline.monitor.isRunning else {
        throw SelfTestFailure("Failed draft persistence must veto quit before stopping app services")
    }
    // Repair storage and make a second quit request. The veto must not poison the
    // controller's shutdown state, and the final flush must preserve the latest text.
    try FileManager.default.removeItem(at: pipeline.drafts.url)
    try oldDraft.write(to: pipeline.drafts.url)
    guard await controller.beginTermination().value, !panel.isVisible, !pipeline.monitor.isRunning,
          try pipeline.drafts.load() == latestText else {
        throw SelfTestFailure("Quit could not retry after a draft failure or lost the newest editor text")
    }
}
