import AppKit
import CaptureKit
import SQLite3
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
    try await checkSessionDrainWaitsForAcquisition()
    try await checkFailedChosenNoteCanBeRetried()
    try await checkNewCaptureSavesRetryPendingCapture()
    try await checkHotkeyRedirectEndsWithRetryWarning()
    try await checkAmbiguousCaptureDestinations()
    try await checkQueuedSubmissionSurvivesQuit()
    try await checkRetypedFailedSubheadingSavesOnce()
    try await checkSessionChangeSurvivesIndexFailure()
    try await checkFailedCaptureDoesNotBlockNote()
    try await checkBlockedTitlePickerKeepsRetryWarning()
    try await checkQueuedPanelWaitsForSelectionRead()
}

@MainActor
private func checkAmbiguousCaptureDestinations() async throws {
    for outcome in ["cancel", "choose"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ambiguous-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultRoot = root.appendingPathComponent("Vault"), state = root.appendingPathComponent("State")
        let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
        let firstURL = vaultRoot.appendingPathComponent("Sessions/First.md")
        let secondURL = vaultRoot.appendingPathComponent("Sessions/Second.md")
        try FileManager.default.createDirectory(at: firstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Target\n".utf8).write(to: firstURL)
        try Data("# Target\n".utf8).write(to: secondURL)
        try await pipeline.index.reindex(note: firstURL)
        try await pipeline.index.reindex(note: secondURL)
        var toasts: [Toast] = []
        let controller = AppController(pipeline: pipeline, presentsUI: true) { toasts.append($0) }
        let capture = PendingCapture(trigger: .selection, content: .text("save to the selected duplicate"),
                                     source: CaptureSource(appName: "Ambiguity check"), subtitle: "check")
        await controller.stage(capture, outsideSession: true)
        do {
            _ = try await controller.commitPending(noteTitle: "Target")?.value
            throw SelfTestFailure("Ambiguous capture title unexpectedly selected a destination")
        } catch is SelfTestFailure { throw SelfTestFailure("Ambiguous capture title unexpectedly selected a destination") }
        catch {}

        let pickerDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !controller.isChoosingDestinationForChecks, ContinuousClock.now < pickerDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard controller.isChoosingDestinationForChecks, let picker = controller.inputForChecks,
              controller.pendingForChecks?.id == capture.id else {
            throw SelfTestFailure("Ambiguous title did not retain the capture and show exact destinations")
        }

        if outcome == "cancel" {
            guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53) else {
                throw SelfTestFailure("Could not create destination picker cancel event")
            }
            _ = picker.handleKeyForChecks(escape)
            let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while controller.isChoosingDestinationForChecks, ContinuousClock.now < closeDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard controller.pendingForChecks?.id == capture.id,
                  toasts.last?.title == "Choose where to save",
                  (try await pipeline.index.captureCount(notePath: "Sessions/First.md")) == 0,
                  (try await pipeline.index.captureCount(notePath: "Sessions/Second.md")) == 0 else {
                throw SelfTestFailure("Canceling exact destination choice saved or discarded the pending capture")
            }
            continue
        }

        let selectedURL = URL(fileURLWithPath: secondURL.path).absoluteString
        var selectedSecond = false
        for _ in 0..<8 {
            if picker.selectedValueForChecks == selectedURL {
                selectedSecond = true
                break
            }
            guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125) else { break }
            _ = picker.handleKeyForChecks(down)
        }
        guard selectedSecond,
              let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw SelfTestFailure("Exact destination picker did not expose the second candidate path")
        }
        _ = picker.handleKeyForChecks(enter)
        let savedDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var saved = try await pipeline.index.capture(id: capture.id)
        while saved == nil, ContinuousClock.now < savedDeadline {
            try await Task.sleep(for: .milliseconds(20))
            saved = try await pipeline.index.capture(id: capture.id)
        }
        guard saved?.notePath == "Sessions/Second.md",
              try await pipeline.index.captureCount(notePath: "Sessions/First.md") == 0,
              try await pipeline.index.captureCount(notePath: "Sessions/Second.md") == 1 else {
            throw SelfTestFailure("Capture title ambiguity did not save exactly once to the selected path")
        }
        _ = await controller.beginTermination().value
    }
}

@MainActor
private func checkSessionDrainWaitsForAcquisition() async throws {
    for transition in ["end", "start"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acquisition-session-drain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"),
                                                      stateDirectory: root.appendingPathComponent("State"), calendar: .current)
        let initialSession = transition == "end" ? try await pipeline.sessions.start(name: "Acquisition destination") : nil
        let capture = PendingCapture(trigger: .selection, content: .text("acquisition before session \(transition)"),
                                     source: CaptureSource(appName: "Drain check"), subtitle: "check")
        var release: (() -> Void)?
        let controller = AppController(pipeline: pipeline, presentsUI: false)
        guard controller.beginAcquisition({
            await withCheckedContinuation { continuation in
                release = { continuation.resume(returning: capture) }
            }
        }) else { throw SelfTestFailure("Could not begin the gated capture acquisition") }
        await Task.yield()
        let changing = Task {
            await controller.drainCaptures()
            if let initialSession { _ = try await controller.endSession(initialSession) }
            else { _ = try await controller.startSession(name: "Started after acquisition") }
        }
        await Task.yield()
        guard await pipeline.sessions.current() == initialSession else {
            throw SelfTestFailure("Session changed before the in-flight capture acquired its contents")
        }
        guard let release else { throw SelfTestFailure("Capture acquisition did not reach its deterministic gate") }
        release()
        try await changing.value
        let saved = try await pipeline.index.capture(id: capture.id)
        let finalSession = await pipeline.sessions.current()
        let expectedPath = initialSession?.notePath ?? "Inbox.md"
        guard saved?.notePath == expectedPath,
              transition == "end" ? finalSession == nil : finalSession?.name == "Started after acquisition" else {
            throw SelfTestFailure("Capture acquired before session \(transition) was saved to \(saved?.notePath ?? "no note") instead of \(expectedPath)")
        }
    }
}

@MainActor
private func checkFailedChosenNoteCanBeRetried() async throws {
    try await checkChosenNoteRetry(notes: ["Target.md"], pick: "Target.md")
    // A picked nested note is saved there, not to a root note with the same heading (title routing is root-only).
    try await checkChosenNoteRetry(notes: ["Roadmap.md", "Projects/Roadmap.md"], pick: "Projects/Roadmap.md")
}

@MainActor
private func checkChosenNoteRetry(notes: [String], pick: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-chosen-note-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultRoot = root.appendingPathComponent("Vault"), state = root.appendingPathComponent("State")
    let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    for note in notes {
        let url = vaultRoot.appendingPathComponent(note)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# \(url.deletingPathExtension().lastPathComponent)\n".utf8).write(to: url)
        try await pipeline.index.reindex(note: url)
    }
    var toasts: [Toast] = []
    let controller = AppController(pipeline: pipeline, presentsUI: true) { toasts.append($0) }
    let capture = PendingCapture(trigger: .selection, content: .text("retry this capture once"),
                                 source: CaptureSource(appName: "Retry check"), subtitle: "check")
    await controller.stage(capture, outsideSession: true)
    do {
        _ = try await controller.commitPending(noteTitle: "../escape")?.value
        throw SelfTestFailure("Invalid chosen note unexpectedly saved")
    } catch is SelfTestFailure { throw SelfTestFailure("Invalid chosen note unexpectedly saved") }
    catch {}

    let failureDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while controller.pendingForChecks?.id != capture.id, ContinuousClock.now < failureDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard controller.pendingForChecks?.id == capture.id,
          toasts.last?.title == "Couldn't save to that note",
          toasts.last?.subtitle?.contains("Capture kept") == true else {
        throw SelfTestFailure("Failed chosen-note save did not preserve the capture with retry guidance")
    }

    controller.capture(.selection, context: FrontmostContext(appName: "Other app", bundleIdentifier: nil,
                                                               processIdentifier: 1, windowTitle: nil))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while controller.inputForChecks == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard let input = controller.inputForChecks else {
        throw SelfTestFailure("Repeating the capture shortcut did not reopen the note chooser")
    }
    var selectedTarget = false
    for _ in 0..<32 {
        if input.selectedValueForChecks == pick {
            selectedTarget = true
            break
        }
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125) else { break }
        _ = input.handleKeyForChecks(down)
    }
    guard selectedTarget,
          let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
        throw SelfTestFailure("Retry chooser did not offer the existing target note")
    }
    _ = input.handleKeyForChecks(enter)
    let saveDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while controller.pendingForChecks != nil, ContinuousClock.now < saveDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    var saved = try await pipeline.index.capture(id: capture.id)
    while saved == nil, ContinuousClock.now < saveDeadline {
        try await Task.sleep(for: .milliseconds(20))
        saved = try await pipeline.index.capture(id: capture.id)
    }
    let targetCount = try await pipeline.index.captureCount(notePath: pick)
    guard controller.pendingForChecks == nil, saved?.notePath == pick, targetCount == 1 else {
        throw SelfTestFailure("Retry did not save the retained capture exactly once to the selected note")
    }
    _ = await controller.beginTermination().value
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
                _ = try await pipeline.renames.rename(candidate, to: "Daily sync", followingCaptures: [], beforeInstall: { _ in
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
            guard try await reopened.renames.pending() == nil,
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
            let outcome = try await pipeline.renames.rename(candidate, to: "Daily sync", followingCaptures: [], afterSwap: {
                throw SessionRenameInterruption.afterSwap
            })
            let pending = try FileManager.default.contentsOfDirectory(atPath: targetURL.deletingLastPathComponent().path)
            guard !outcome.identityUpdatePending, outcome.session.notePath == destination.notePath,
                  await pipeline.sessions.current()?.notePath == destination.notePath,
                  try await pipeline.renames.pending() == nil,
                  !FileManager.default.fileExists(atPath: oldURL.path),
                  try String(contentsOf: targetURL, encoding: .utf8) == "# Daily sync\n" + body,
                  !pending.contains(where: { $0.hasPrefix(".session-") }) else {
                throw SelfTestFailure("Rename catch did not complete the interrupted swap before returning success")
            }
        } else if checkpoint == "caught-recovery-error" {
            let unrelated = Data("# Other owner\nkeep every byte\n".utf8)
            do {
                _ = try await pipeline.renames.rename(candidate, to: "Daily sync", followingCaptures: [], afterSwap: {
                    try unrelated.write(to: targetURL, options: .atomic)
                    throw SessionRenameInterruption.afterSwap
                })
                throw SelfTestFailure("A failed swap recovery hid the original rename error")
            } catch SessionRenameInterruption.afterSwap {}
            // The blocked resume abandons: the half-applied rename stays put with its backup.
            let temporaries = try FileManager.default.contentsOfDirectory(at: oldURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".session-") }
            let renamedBytes = "# Daily sync\n" + body
            guard try await pipeline.renames.pending() == nil,
                  try String(contentsOf: oldURL, encoding: .utf8) == renamedBytes,
                  temporaries.count == 1, try String(contentsOf: temporaries[0], encoding: .utf8) == "# Standup\n" + body,
                  try Data(contentsOf: targetURL) == unrelated else {
                throw SelfTestFailure("Failed swap recovery kept a blocking intent or lost the original backup or unrelated target")
            }
            let reopened = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
            guard try await reopened.renames.pending() == nil,
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
            let outcome = try await pipeline.renames.rename(candidate, to: "Daily sync", followingCaptures: [])
            guard outcome.identityUpdatePending, outcome.session.notePath == destination.notePath,
                  !FileManager.default.fileExists(atPath: oldURL.path),
                  try String(contentsOf: targetURL, encoding: .utf8) == "# Daily sync\n" + body,
                  try await pipeline.renames.pending() != nil else {
                throw SelfTestFailure("A committed rename with failed state persistence was reported as a failure")
            }
            try FileManager.default.removeItem(at: stateFile)
        } else {
            let intent = try await pipeline.renames.begin(oldPath: source.notePath, session: destination, followingCaptures: [])
            let recorder = await pipeline.renames.installationRecorder(for: intent)
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
                guard try await pipeline.renames.pending() != nil else {
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
            guard try await reopened.renames.pending() == nil,
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
            guard try await reopened.renames.pending() == nil,
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
              try await reopened.renames.pending() == nil,
              try await again.renames.pending() == nil else {
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
                _ = try await pipeline.renames.rename(candidate, to: "Renamed", followingCaptures: [], afterSwap: {
                    try edited.write(to: oldURL, options: .atomic)
                })
                throw SelfTestFailure("Rename hid the original post-swap failure")
            } catch let error as POSIXError where error.code == .EAGAIN {}
            guard try await pipeline.renames.pending() == nil,
                  try Data(contentsOf: oldURL) == edited,
                  !FileManager.default.fileExists(atPath: targetURL.path) else {
                throw SelfTestFailure("Failed rename retained its intent or changed the editor's bytes")
            }
            recovered = pipeline
        } else {
            let intent = try await pipeline.renames.begin(oldPath: session.notePath, session: destination, followingCaptures: [])
            let recorder = await pipeline.renames.installationRecorder(for: intent)
            do {
                _ = try await pipeline.sessions.rename(candidate, to: "Renamed", beforeInstall: recorder,
                                                       afterSwap: { throw SessionRenameInterruption.afterSwap })
                throw SelfTestFailure("Missing-source checkpoint did not interrupt rename")
            } catch SessionRenameInterruption.afterSwap {}
            try FileManager.default.removeItem(at: oldURL)
            if scenario == "unknown-target" { try edited.write(to: targetURL) }
            recovered = try await CapturePipeline.open(vaultRoot: vault, stateDirectory: state, calendar: .current)
            guard try await recovered.renames.pending() == nil,
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
            guard try await reopened.renames.pending() == nil else {
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
    let outcome = try await pipeline.renames.rename(candidate, to: "Daily sync", followingCaptures: [job])
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
    let intent = try await pipeline.renames.begin(oldPath: recoverySession.notePath, session: planned, followingCaptures: [recoveryJob])
    let recorder = await pipeline.renames.installationRecorder(for: intent)
    _ = try await pipeline.sessions.rename(recoveryCandidate, to: "Recovered", beforeInstall: recorder)
    let reopened = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    guard try await reopened.renames.pending() == nil,
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
    _ = try await reopened.renames.begin(oldPath: before.notePath, session: beforeTarget, followingCaptures: [])
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
    let firstRename = try await finished.renames.rename(repeatedA, to: "Repeated B", followingCaptures: [unstaged])
    let repeatedB = SessionCandidate(name: firstRename.session.name, notePath: firstRename.session.notePath, modifiedAt: .distantPast)
    let secondRename = try await finished.renames.rename(repeatedB, to: "Repeated C", followingCaptures: [unstaged])
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
    let pendingOutcome = try await finished.renames.rename(pendingCandidate, to: "Waiting metadata", followingCaptures: [])
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
    _ = try await finished.renames.begin(oldPath: changed.notePath, session: changedTarget, followingCaptures: [])
    let changedURL = vaultRoot.appendingPathComponent(changed.notePath)
    let writer = try FileHandle(forWritingTo: changedURL)
    try writer.seekToEnd()
    try writer.write(contentsOf: Data("external edit after intent\n".utf8))
    try writer.close()
    let edited = try Data(contentsOf: changedURL)
    let afterDrift = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    guard try await afterDrift.renames.pending() == nil,
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
    for hotkey in [Hotkey.captureSelectionOutsideSession, .captureRegionOutsideSession, .writeNoteOutsideSession] {
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

/// Stages a capture, fails its chosen-note save, and waits until it is retry-pending.
@MainActor
private func makeRetryPendingCapture(_ controller: AppController, text: String) async throws -> PendingCapture {
    let capture = PendingCapture(trigger: .selection, content: .text(text),
                                 source: CaptureSource(appName: "Retry check"), subtitle: "check")
    await controller.stage(capture, outsideSession: true)
    _ = try? await controller.commitPending(noteTitle: "../escape")?.value
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while controller.pendingForChecks?.id != capture.id, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard controller.pendingForChecks?.id == capture.id else {
        throw SelfTestFailure("Failed chosen-note save did not leave the capture retry-pending")
    }
    return capture
}

@MainActor
private func checkNewCaptureSavesRetryPendingCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-new-capture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultRoot = root.appendingPathComponent("Vault"), state = root.appendingPathComponent("State")
    let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
    var toasts: [Toast] = []
    let controller = AppController(pipeline: pipeline, presentsUI: true) { toasts.append($0) }
    let first = try await makeRetryPendingCapture(controller, text: "retry pending first capture")
    let second = PendingCapture(trigger: .selection, content: .text("newer second capture"),
                                source: CaptureSource(appName: "Retry check"), subtitle: "newer")
    await controller.stage(second)

    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var savedFirst = try await pipeline.index.capture(id: first.id)
    while (savedFirst == nil || controller.hasPreparedJobForChecks(first.id)), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
        savedFirst = try await pipeline.index.capture(id: first.id)
    }
    guard let savedFirst, controller.pendingForChecks?.id == second.id,
          try await pipeline.index.capture(id: second.id) == nil,
          !controller.hasPreparedJobForChecks(first.id) else {
        throw SelfTestFailure("A newer capture did not save the retry-pending capture before itself")
    }
    guard toasts.contains(where: { $0.subtitle?.contains("Previous capture saved") == true }) else {
        throw SelfTestFailure("Saving a retry-pending capture for a newer one gave no notice")
    }
    await controller.drainCaptures()
    let note = try String(contentsOf: vaultRoot.appendingPathComponent(savedFirst.notePath), encoding: .utf8)
    guard let firstRange = note.range(of: "retry pending first capture"),
          let secondRange = note.range(of: "newer second capture"), firstRange.lowerBound < secondRange.lowerBound else {
        throw SelfTestFailure("The retry-pending capture was not saved before the newer capture")
    }
}

@MainActor
private func checkHotkeyRedirectEndsWithRetryWarning() async throws {
    let other = FrontmostContext(appName: "Other app", bundleIdentifier: nil, processIdentifier: 1, windowTitle: nil)
    func open(_ name: String) async throws -> (CapturePipeline, URL, AppController, [Toast]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-\(name)-\(UUID().uuidString)")
        let vaultRoot = root.appendingPathComponent("Vault"), state = root.appendingPathComponent("State")
        let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: state, calendar: .current)
        return (pipeline, root, AppController(pipeline: pipeline, presentsUI: true), [])
    }

    // While the retry warning is visible, the hotkey reopens the chooser for the kept capture.
    do {
        let (_, root, controller, _) = try await open("visible")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await makeRetryPendingCapture(controller, text: "visible warning capture")
        controller.capture(.selection, context: other)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.inputForChecks == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard controller.inputForChecks != nil, controller.pendingForChecks?.id == first.id else {
            throw SelfTestFailure("The capture hotkey did not reopen the chooser while the retry warning was visible")
        }
    }

    // Implicit commits (note, subheading, toast, drain) must not route a retry-pending capture.
    do {
        let (pipeline, root, controller, _) = try await open("implicit")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await makeRetryPendingCapture(controller, text: "implicit retry pending capture")
        _ = try? await controller.addNote("implicit note")
        _ = try? await controller.addSubheading("Implicit heading")
        controller.showToastForChecks(Toast(style: .warning, title: "Unrelated warning"))
        await controller.drainCaptures()
        try await Task.sleep(for: .milliseconds(100))
        guard controller.pendingForChecks?.id == first.id, try await pipeline.index.capture(id: first.id) == nil else {
            throw SelfTestFailure("An implicit commit saved a retry-pending capture to the default destination")
        }
    }

    // Once the warning is gone, the hotkey captures a new selection instead (supplied, no real read).
    do {
        let (pipeline, root, controller, _) = try await open("hidden")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await makeRetryPendingCapture(controller, text: "hidden warning capture")
        let second = PendingCapture(trigger: .selection, content: .text("fresh hotkey capture"),
                                    source: CaptureSource(appName: "Retry check"), subtitle: "fresh")
        controller.acquiredSelectionForChecks = second
        controller.hideToastForChecks()
        controller.capture(.selection, context: other)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.pendingForChecks?.id != second.id, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard controller.pendingForChecks?.id == second.id, controller.inputForChecks == nil else {
            throw SelfTestFailure("The capture hotkey did not stage a new capture after the retry warning was gone")
        }
        await controller.drainCaptures()
        guard try await pipeline.index.capture(id: first.id) != nil, try await pipeline.index.capture(id: second.id) != nil else {
            throw SelfTestFailure("The retry-pending and newer captures were not both saved")
        }
    }
}

@MainActor
private func editableField(in view: NSView?, label: String) -> NSTextField? {
    guard let view else { return nil }
    if let field = view as? NSTextField, field.isEditable, field.accessibilityLabel() == label { return field }
    return view.subviews.lazy.compactMap { editableField(in: $0, label: label) }.first
}

/// The prompt's own window (read from its private `panel`), so a stale panel from an earlier prompt cannot match.
@MainActor
private func promptWindow(of input: InputPanelController) -> NSWindow? {
    Mirror(reflecting: input).children.first { $0.label == "panel" }?.value as? NSWindow
}

/// A subheading submitted behind a busy action must still save during quit, but not after the deadline.
@MainActor
private func checkQueuedSubmissionSurvivesQuit() async throws {
    for pastDeadline in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("queued-submit-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"),
                                                      stateDirectory: root.appendingPathComponent("State"), calendar: .current)
        let controller = AppController(pipeline: pipeline, presentsUI: false)
        let heading = pastDeadline ? "Late quit heading" : "Queued quit heading"
        func inbox() -> String { (try? String(contentsOf: pipeline.vault.inboxURL, encoding: .utf8)) ?? "" }
        func waitForInput() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while controller.inputForChecks == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard controller.inputForChecks != nil else { throw SelfTestFailure("Subheading prompt was not presented") }
        }
        controller.openSubheading()
        try await waitForInput()
        // The second open parks behind an unfinished acquisition, so the submission below queues after it.
        var release: (() -> Void)?
        guard controller.beginAcquisition({
            await withCheckedContinuation { continuation in release = { continuation.resume(returning: nil) } }
        }) else { throw SelfTestFailure("Could not begin the gated acquisition") }
        await Task.yield()
        controller.openSubheading()
        try await Task.sleep(for: .milliseconds(100))
        guard let release,
              let input = controller.inputForChecks,
              let field = promptWindow(of: input).flatMap({ editableField(in: $0.contentView, label: "Add subheading") }),
              let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 36) else {
            throw SelfTestFailure("Could not submit the queued subheading")
        }
        field.stringValue = heading
        _ = input.handleKeyForChecks(enter)
        try await Task.sleep(for: .milliseconds(100))
        guard !inbox().contains(heading) else { throw SelfTestFailure("Subheading saved before the busy action finished") }
        let quit = controller.beginTermination(timeout: pastDeadline ? .milliseconds(300) : .seconds(5))
        // New work after quit began is refused.
        controller.openSubheading()
        if !pastDeadline { release() }
        _ = await quit.value
        if pastDeadline { release(); try await Task.sleep(for: .milliseconds(300)) }
        guard controller.inputForChecks == nil else { throw SelfTestFailure("A subheading prompt opened after quit began") }
        guard inbox().contains(heading) == !pastDeadline else {
            throw SelfTestFailure(pastDeadline ? "A queued subheading started after the shutdown deadline"
                                               : "A subheading queued behind a busy action was dropped on quit")
        }
    }
}

/// A subheading whose commit failed and is then retyped must reuse its identity, so the quit drain
/// writes it once. A failed subheading with different text stays a separate intent and is still saved.
@MainActor
private func checkRetypedFailedSubheadingSavesOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retyped-subheading-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultRoot = root.appendingPathComponent("Vault")
    let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let controller = AppController(pipeline: pipeline, presentsUI: false)
    let session = try await controller.startSession(name: "Linked")
    // A second hard link makes the session note unsafe to write, so each commit fails.
    let link = root.appendingPathComponent("second-link.md")
    try FileManager.default.linkItem(at: vaultRoot.appendingPathComponent(session.notePath), to: link)
    for heading in ["Retyped heading", "Other heading"] {
        do {
            _ = try await controller.addSubheading(heading)
            throw SelfTestFailure("A subheading unexpectedly saved to an unsafe note")
        } catch is SelfTestFailure { throw SelfTestFailure("A subheading unexpectedly saved to an unsafe note") }
        catch {}
    }
    try FileManager.default.removeItem(at: link)
    guard try await controller.addSubheading("Retyped heading") != nil else {
        throw SelfTestFailure("A retyped subheading did not save once the note was writable")
    }
    _ = await controller.beginTermination().value
    let note = try String(contentsOf: vaultRoot.appendingPathComponent(session.notePath), encoding: .utf8)
    guard note.components(separatedBy: "## Retyped heading\n").count - 1 == 1,
          note.components(separatedBy: "## Other heading\n").count - 1 == 1 else {
        throw SelfTestFailure("A retyped failed subheading was not written exactly once alongside the other failed subheading")
    }
}

/// Renames a core table through a second connection so index reads and writes fail.
private func breakIndex(at url: URL) throws {
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          sqlite3_exec(database, "ALTER TABLE blocks RENAME TO blocks_unavailable", nil, nil, nil) == SQLITE_OK else {
        throw SelfTestFailure("Could not make the search index unavailable")
    }
}

/// An unavailable index must not turn a session that already started or ended into an error.
@MainActor
private func checkSessionChangeSurvivesIndexFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-index-failure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("State")
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"), stateDirectory: state, calendar: .current)
    var toasts: [Toast] = []
    let controller = AppController(pipeline: pipeline, presentsUI: false, onToast: { toasts.append($0) })
    try breakIndex(at: state.appendingPathComponent("index.sqlite"))
    let session = try await controller.startSession(name: "Index down")
    guard await pipeline.sessions.current() == session, toasts.last?.title == "Session started · Index down" else {
        throw SelfTestFailure("Session start was reported as failed because the index update failed")
    }
    let count = try await controller.endSession(session)
    guard count == nil, await pipeline.sessions.current() == nil,
          toasts.last?.title == "Session ended · Index down", toasts.last?.subtitle == nil else {
        throw SelfTestFailure("Session end was reported as failed because the capture count was unavailable")
    }
}

@MainActor
private func checkFailedCaptureDoesNotBlockNote() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("unrelated-commit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultRoot = root.appendingPathComponent("Vault")
    let pipeline = try await CapturePipeline.open(vaultRoot: vaultRoot, stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    var toasts: [Toast] = []
    let controller = AppController(pipeline: pipeline, presentsUI: false, onToast: { toasts.append($0) })
    let session = try await controller.startSession(name: "Linked")
    // A second hard link makes the session note unsafe to write, so the capture's own commit fails.
    try FileManager.default.linkItem(at: vaultRoot.appendingPathComponent(session.notePath),
                                     to: root.appendingPathComponent("second-link.md"))
    await controller.stage(PendingCapture(trigger: .selection, content: .text("capture for a linked session"),
                                          source: CaptureSource(appName: "Commit check"), subtitle: "check"))
    let saved = try await controller.addNote("Unblocked note\nstill saved", outsideSession: true)
    guard saved != nil, FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent("Unblocked note.md").path) else {
        throw SelfTestFailure("An unrelated failed capture commit blocked saving a quick note")
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !toasts.contains(where: { $0.title == "Couldn't save capture" }), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard toasts.contains(where: { $0.title == "Couldn't save capture" }) else {
        throw SelfTestFailure("The failed capture commit did not report its own failure")
    }
}

/// The capture shortcut reopens the picker for a retry-pending capture. If the editor can't close
/// (its draft can't be saved), the picker can't open and the editor's error toast replaces the retry
/// warning; the capture must stay kept, with the warning back so the shortcut can reopen the picker.
@MainActor
private func checkBlockedTitlePickerKeepsRetryWarning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-picker-\(UUID().uuidString)", isDirectory: true)
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let other = FrontmostContext(appName: "Other app", bundleIdentifier: nil, processIdentifier: 1, windowTitle: nil)
    var toasts: [Toast] = []
    let controller = AppController(pipeline: pipeline, presentsUI: true) { toasts.append($0) }
    let first = try await makeRetryPendingCapture(controller, text: "capture behind a stuck editor")
    let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
    controller.openNoteEditor()
    // Match the editor's own text view: a picker opened by the retry setup has a field editor too.
    func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, String(describing: type(of: text)) == "NoteTextView" { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    var panel: OverlayPanel?
    defer {
        if (try? pipeline.drafts.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? FileManager.default.removeItem(at: pipeline.drafts.url)
        }
        panel?.dismiss(animated: false)
        try? FileManager.default.removeItem(at: root)
    }
    let opened = ContinuousClock.now.advanced(by: .seconds(3))
    while panel == nil, ContinuousClock.now < opened {
        panel = NSApp.windows.compactMap { $0 as? OverlayPanel }.first {
            $0.isVisible && !existingWindows.contains(ObjectIdentifier($0)) && $0.contentView.flatMap(textView(in:)) != nil
        }
        if panel == nil { try await Task.sleep(for: .milliseconds(20)) }
    }
    guard let editorPanel = panel, let text = editorPanel.contentView.flatMap(textView(in:)) else {
        throw SelfTestFailure("Could not open the editor for the blocked title picker regression")
    }
    // A directory in place of the draft file fails the editor's save, so it stays open.
    text.string = "Draft that keeps the editor open"
    try? FileManager.default.removeItem(at: pipeline.drafts.url)
    try FileManager.default.createDirectory(at: pipeline.drafts.url, withIntermediateDirectories: false)
    try Data("block replacement".utf8).write(to: pipeline.drafts.url.appendingPathComponent("blocker"))

    let shown = toasts.count
    controller.capture(.selection, context: other)
    func restoredWarning() -> Bool {
        toasts.dropFirst(shown).last.map {
            $0.title == "Couldn't keep draft; editor stays open" && $0.subtitle?.contains("Capture kept") == true
        } ?? false
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !restoredWarning(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard restoredWarning(), controller.pendingForChecks?.id == first.id, controller.inputForChecks == nil, editorPanel.isVisible else {
        throw SelfTestFailure("A picker blocked by an editor that can't close left a retry-pending capture without its warning")
    }
}

/// Holds a simulated selection read open until the check releases it.
@MainActor
private final class ReadGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

/// A queued panel must not appear while a capture reads the selection: the clipboard
/// fallback's ⌘C would land in it. The editor action has no drain, so it reached the panel first.
@MainActor
private func checkQueuedPanelWaitsForSelectionRead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("held-read-\(UUID().uuidString)", isDirectory: true)
    let pipeline = try await CapturePipeline.open(vaultRoot: root.appendingPathComponent("Vault"), stateDirectory: root.appendingPathComponent("State"), calendar: .current)
    let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
    let controller = AppController(pipeline: pipeline, presentsUI: false)
    let gate = ReadGate()
    func editorPanel() -> OverlayPanel? {
        NSApp.windows.compactMap { $0 as? OverlayPanel }.first { $0.isVisible && !existingWindows.contains(ObjectIdentifier($0)) }
    }
    defer {
        gate.open()
        editorPanel()?.dismiss(animated: false)
        try? FileManager.default.removeItem(at: root)
    }
    guard controller.beginAcquisition({ await gate.wait(); return nil }) else {
        throw SelfTestFailure("Could not start the held selection read")
    }
    controller.openNoteEditor()
    let held = ContinuousClock.now.advanced(by: .milliseconds(500))
    while ContinuousClock.now < held {
        guard editorPanel() == nil else {
            throw SelfTestFailure("The quick-note editor appeared while a capture was reading the selection")
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    gate.open()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while editorPanel() == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard editorPanel() != nil else {
        throw SelfTestFailure("The queued editor did not open after the selection read finished")
    }
}
