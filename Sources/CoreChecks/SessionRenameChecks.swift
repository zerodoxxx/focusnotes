@_spi(Checks) import Core
import Darwin
import Foundation

func checkSessionRename() async throws {
    let base = try checkMakeDirectory("session-rename")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    try vault.prepare()
    let state = base.appendingPathComponent("State")
    let store = SessionStore(stateDirectory: state, vault: vault, calendar: checkCalendar(), now: { checkDate(2026, 10, 22, 10, 0) })
    let source = vault.root.appendingPathComponent("Sessions/archive/Standup.md")
    let suffix = "\r\n\r\n![](../../assets/example.png)\r\nuntouched body\r\n"
    let original = "\u{FEFF}# Standup" + suffix
    try checkWrite(original, to: source)
    let candidate = SessionCandidate(name: "Standup", notePath: "Sessions/archive/Standup.md", modifiedAt: .distantPast)
    let renamed = try await store.rename(candidate, to: "  Daily   sync  ")
    let target = vault.root.appendingPathComponent("Sessions/archive/Daily sync.md")
    try require(renamed.name == "Daily sync" && renamed.notePath == "Sessions/archive/Daily sync.md" && renamed.resumed == true,
                "rename must sanitize, stay in the folder and resume the new identity")
    let bytes = try Data(contentsOf: target)
    try require(bytes == Data(("\u{FEFF}# Daily sync" + suffix).utf8), "rename must preserve BOM, CRLF, relative images and every body byte")
    try require(!FileManager.default.fileExists(atPath: source.path), "rename must remove the old filename")
    let restored = SessionStore(stateDirectory: state, vault: vault, calendar: checkCalendar(), now: Date.init)
    let current = await restored.current()
    try require(current == renamed, "renamed active identity must persist")
    let selected = SessionCandidate(name: renamed.name, notePath: renamed.notePath, modifiedAt: .distantPast)
    let same = try await store.rename(selected, to: "Daily sync")
    let sameBytes = try Data(contentsOf: target)
    try require(same.notePath == renamed.notePath && sameBytes == bytes, "confirming the same name must preserve all content")
    for invalid in ["", "  ", ".", "..", "archive/Move", "archive\\Move", "bad\0name", "~$draft"] {
        do {
            _ = try await store.rename(selected, to: invalid)
            throw CheckFailure.failed("unsafe rename was accepted: \(invalid.debugDescription)")
        } catch SessionStoreError.invalidRename {}
        let unchanged = try Data(contentsOf: target)
        try require(unchanged == bytes, "invalid rename must leave the source unchanged")
    }
    let conflict = vault.root.appendingPathComponent("Sessions/archive/Occupied.MD")
    try checkWrite("do not replace", to: conflict)
    for name in ["occupied", "daily sync"] {
        do {
            _ = try await store.rename(selected, to: name)
            throw CheckFailure.failed("case-insensitive collision was accepted")
        } catch SessionStoreError.renameConflict where name == "occupied" {}
        catch SessionStoreError.caseOnlyRename where name == "daily sync" {}
    }
    let conflictBytes = try checkRead(conflict)
    let afterCollision = try Data(contentsOf: target)
    try require(conflictBytes == "do not replace" && afterCollision == bytes, "collision must preserve both files")

    // A destination appearing during staging must be caught by the final
    // folded-name check without changing the source or the new owner's bytes.
    let racedTarget = vault.root.appendingPathComponent("Sessions/archive/Raced.md")
    do {
        _ = try await store.rename(selected, to: "Raced", beforeInstall: { _ in
            try Data("racing owner".utf8).write(to: racedTarget)
        })
        throw CheckFailure.failed("racing destination was overwritten")
    } catch SessionStoreError.renameConflict {} catch is CheckFailure { throw CheckFailure.failed("racing destination was overwritten") }
    let afterRace = try Data(contentsOf: target)
    let racedBytes = try checkRead(racedTarget)
    try require(afterRace == bytes && racedBytes == "racing owner", "a late destination collision must preserve both files")

    let mixedCaseTarget = vault.root.appendingPathComponent("Sessions/archive/rAcEd mixed.md")
    do {
        _ = try await store.rename(selected, to: "Raced mixed", beforeInstall: { _ in
            try Data("mixed-case owner".utf8).write(to: mixedCaseTarget)
        })
        throw CheckFailure.failed("a late case-insensitive collision was accepted")
    } catch SessionStoreError.renameConflict {} catch is CheckFailure { throw CheckFailure.failed("a late case-insensitive collision was accepted") }
    let afterMixedCaseRace = try Data(contentsOf: target)
    let mixedCaseBytes = try checkRead(mixedCaseTarget)
    try require(afterMixedCaseRace == bytes && mixedCaseBytes == "mixed-case owner",
                "a late folded-name collision must preserve source and destination even on a case-sensitive volume")

    let outside = base.appendingPathComponent("outside.md")
    try checkWrite("# Outside\n", to: outside)
    let hardLink = vault.root.appendingPathComponent("Sessions/archive/Hard.md")
    guard link(outside.path, hardLink.path) == 0 else { throw CheckFailure.failed("could not create hardlink fixture") }
    let symlink = vault.root.appendingPathComponent("Sessions/archive/Linked.md")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    for path in ["Sessions/archive/Hard.md", "Sessions/archive/Linked.md"] {
        do {
            _ = try await store.rename(SessionCandidate(name: "Unsafe", notePath: path, modifiedAt: .distantPast), to: "Escape")
            throw CheckFailure.failed("linked file was renamed")
        } catch SessionStoreError.candidateNoLongerExists(let missing) {
            try require(missing == path, "a linked candidate must be rejected at its exact path")
        }
    }
    let outsideBytes = try checkRead(outside)
    try require(outsideBytes == "# Outside\n", "rename must not rewrite a linked file outside the vault")

    // A non-cooperating editor replacing the source during staging must keep
    // its own bytes and must never publish our stale snapshot at the new name.
    // Its unlinked source descriptor fails the single-link guard with EPERM.
    do {
        _ = try await store.rename(selected, to: "Stale", beforeInstall: { _ in
            try Data("# External edit\nkeep me\n".utf8).write(to: target, options: .atomic)
        })
        throw CheckFailure.failed("replaced source snapshot was renamed")
    } catch let error as POSIXError where error.code == .EPERM {}
    let external = try checkRead(target)
    try require(external == "# External edit\nkeep me\n" && !FileManager.default.fileExists(atPath: vault.root.appendingPathComponent("Sessions/archive/Stale.md").path),
                "source identity changes must preserve the editor's replacement and reject stale output")
    let directoryNames = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
    try require(!directoryNames.contains(where: { $0.hasPrefix(".session-") }), "renames must remove temporary snapshots")
    try await checkSessionRenameEdgeCases(base: base, vault: vault, store: store, state: state)
    print("Session rename checks passed.")
}

private func checkSessionRenameEdgeCases(base: URL, vault: Vault, store: SessionStore, state: URL) async throws {
    let cases: [(Data, Data)] = [
        (Data("body\n".utf8), Data("# New\n\nbody\n".utf8)),
        (Data("first\nlater\r\n".utf8), Data("# New\r\n\r\nfirst\nlater\r\n".utf8)),
        (Data(), Data("# New\n\n".utf8)),
        (Data("# Old".utf8), Data("# New".utf8)),
        (Data("#body\n".utf8), Data("# New\n\n#body\n".utf8)),
        (Data([0x23, 0x20, 0xFF, 0x0A, 0xFE]), Data([0x23, 0x20, 0x4E, 0x65, 0x77, 0x0A, 0xFE])),
        (Data([0xFF, 0x0A, 0xFE]), Data("# New\n\n".utf8) + Data([0xFF, 0x0A, 0xFE]))
    ]
    for (i, pair) in cases.enumerated() {
        let path = "Sessions/edge-\(i)/Old.md"
        let source = vault.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pair.0.write(to: source)
        let renamed = try await store.rename(SessionCandidate(name: "Old", notePath: path, modifiedAt: .distantPast), to: "New")
        let result = try Data(contentsOf: vault.root.appendingPathComponent(renamed.notePath))
        try require(result == pair.1, "heading edge case \(i) must preserve exact bytes")
    }

    let sourcePath = "Sessions/edge-directory/Old.md"
    let source = vault.root.appendingPathComponent(sourcePath)
    try checkWrite("# Old\nkeep\n", to: source)
    let candidate = SessionCandidate(name: "Old", notePath: sourcePath, modifiedAt: .distantPast)
    let occupied = source.deletingLastPathComponent().appendingPathComponent("Occupied.md")
    try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
    do {
        _ = try await store.rename(candidate, to: "Occupied")
        throw CheckFailure.failed("a directory occupying the target was replaced")
    } catch SessionStoreError.renameConflict {}

    let outside = base.appendingPathComponent("linked-ancestor")
    try checkWrite("# Outside\nkeep\n", to: outside.appendingPathComponent("Old.md"))
    let link = vault.root.appendingPathComponent("Sessions/ancestor-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    do {
        _ = try await store.rename(SessionCandidate(name: "Old", notePath: "Sessions/ancestor-link/Old.md", modifiedAt: .distantPast), to: "New")
        throw CheckFailure.failed("a symlinked ancestor was accepted")
    } catch SessionStoreError.candidateNoLongerExists(let path) {
        try require(path == "Sessions/ancestor-link/Old.md", "linked ancestor must reject the selected path")
    }
    let outsideBytes = try checkRead(outside.appendingPathComponent("Old.md"))
    try require(outsideBytes == "# Outside\nkeep\n", "linked ancestor must leave outside bytes intact")

    let stateFile = state.appendingPathComponent("session.json")
    try FileManager.default.removeItem(at: stateFile)
    try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
    do {
        _ = try await store.rename(candidate, to: "Persisted later")
        throw CheckFailure.failed("state persistence unexpectedly succeeded over a directory")
    } catch let error as CocoaError {
        // Foundation on newer SDKs reports ENOENT when the target is a directory.
        let missingTarget = error.code == .fileNoSuchFile &&
            (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain == NSPOSIXErrorDomain &&
            (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT)
        try require(error.code == .fileWriteFileExists || error.code == .fileWriteUnknown || error.code == .fileWriteNoPermission || missingTarget,
                    "state persistence must report a write error, got \(error.code)")
    }
    let current = await store.current()
    let newFile = source.deletingLastPathComponent().appendingPathComponent("Persisted later.md")
    let newBytes = try checkRead(newFile)
    try require(current?.notePath == "Sessions/edge-directory/Persisted later.md" && newBytes == "# Persisted later\nkeep\n",
                "a persistence failure must retain the committed file and in-memory session")
    try FileManager.default.removeItem(at: stateFile)

    // An editor replacing the swapped-in note must survive the rollback guard.
    let rollbackPath = "Sessions/edge-rollback/Old.md"
    let rollbackSource = vault.root.appendingPathComponent(rollbackPath)
    let original = "# Old\noriginal body\n"
    try checkWrite(original, to: rollbackSource)
    do {
        _ = try await store.rename(SessionCandidate(name: "Old", notePath: rollbackPath, modifiedAt: .distantPast), to: "New",
                                   afterSwap: {
            try Data("# Unrelated\neditor bytes\n".utf8).write(to: rollbackSource, options: .atomic)
            throw POSIXError(.EAGAIN)
        })
        throw CheckFailure.failed("post-swap source replacement was accepted")
    } catch let error as POSIXError where error.code == .EAGAIN {}
    let unrelated = try checkRead(rollbackSource)
    let pending = try FileManager.default.contentsOfDirectory(at: rollbackSource.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(".session-") }
    try require(unrelated == "# Unrelated\neditor bytes\n" && pending.count == 1, "rollback must preserve editor bytes and the original backup")
    let backup = try checkRead(pending[0])
    try require(backup == original, "the retained backup must preserve every original byte")
}
