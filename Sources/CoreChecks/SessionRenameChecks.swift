import Core
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
        } catch is CheckFailure { throw CheckFailure.failed("unsafe rename was accepted: \(invalid.debugDescription)") }
        catch {}
        let unchanged = try Data(contentsOf: target)
        try require(unchanged == bytes, "invalid rename must leave the source unchanged")
    }
    let conflict = vault.root.appendingPathComponent("Sessions/archive/Occupied.MD")
    try checkWrite("do not replace", to: conflict)
    for name in ["occupied", "daily sync"] {
        do {
            _ = try await store.rename(selected, to: name)
            throw CheckFailure.failed("case-insensitive collision was accepted")
        } catch SessionStoreError.renameConflict {} catch is CheckFailure { throw CheckFailure.failed("case-insensitive collision was accepted") }
    }
    let conflictBytes = try checkRead(conflict)
    let afterCollision = try Data(contentsOf: target)
    try require(conflictBytes == "do not replace" && afterCollision == bytes, "collision must preserve both files")

    // A destination appearing during staging must be caught by the final
    // folded-name check without changing the source or the new owner's bytes.
    let racedTarget = vault.root.appendingPathComponent("Sessions/archive/Raced.md")
    do {
        _ = try await store.rename(selected, to: "Raced", beforeInstall: { _, _ in
            try Data("racing owner".utf8).write(to: racedTarget)
        })
        throw CheckFailure.failed("racing destination was overwritten")
    } catch SessionStoreError.renameConflict {} catch is CheckFailure { throw CheckFailure.failed("racing destination was overwritten") }
    let afterRace = try Data(contentsOf: target)
    let racedBytes = try checkRead(racedTarget)
    try require(afterRace == bytes && racedBytes == "racing owner", "a late destination collision must preserve both files")

    let mixedCaseTarget = vault.root.appendingPathComponent("Sessions/archive/rAcEd mixed.md")
    do {
        _ = try await store.rename(selected, to: "Raced mixed", beforeInstall: { _, _ in
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
        } catch is CheckFailure { throw CheckFailure.failed("linked file was renamed") } catch {}
    }
    let outsideBytes = try checkRead(outside)
    try require(outsideBytes == "# Outside\n", "rename must not rewrite a linked file outside the vault")

    // A non-cooperating editor replacing the source during staging must keep
    // its own bytes and must never publish our stale snapshot at the new name.
    do {
        _ = try await store.rename(selected, to: "Stale", beforeInstall: { _, _ in
            try Data("# External edit\nkeep me\n".utf8).write(to: target, options: .atomic)
        })
        throw CheckFailure.failed("replaced source snapshot was renamed")
    } catch is CheckFailure { throw CheckFailure.failed("replaced source snapshot was renamed") } catch {}
    let external = try checkRead(target)
    try require(external == "# External edit\nkeep me\n" && !FileManager.default.fileExists(atPath: vault.root.appendingPathComponent("Sessions/archive/Stale.md").path),
                "source identity changes must preserve the editor's replacement and reject stale output")
    let directoryNames = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
    try require(!directoryNames.contains(where: { $0.hasPrefix(".session-") }), "renames must remove temporary snapshots")
    print("Session rename checks passed.")
}
