import Core
import Darwin
import Foundation

func checkVault() throws {
    let root = try checkMakeDirectory("vault")
    defer { checkRemoveDirectory(root) }
    let vault = Vault(root: root)

    try vault.prepare()
    let firstInbox = try checkRead(vault.inboxURL)
    try require(firstInbox == "# Inbox\n", "prepare wrote Inbox.md as \(firstInbox.debugDescription)")
    let initialMode = try FileManager.default.attributesOfItem(atPath: vault.inboxURL.path)[.posixPermissions] as? NSNumber
    try require(initialMode?.intValue == 0o600, "new Inbox.md should be private (0600)")
    try checkWrite("# Inbox\n\nkept\n", to: vault.inboxURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: vault.inboxURL.path)
    try vault.prepare()
    let secondInbox = try checkRead(vault.inboxURL)
    try require(secondInbox == "# Inbox\n\nkept\n", "prepare must not overwrite an existing Inbox.md")
    let existingMode = try FileManager.default.attributesOfItem(atPath: vault.inboxURL.path)[.posixPermissions] as? NSNumber
    try require(existingMode?.intValue == 0o600, "prepare must migrate a legacy readable Inbox.md to owner-only access")
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: vault.inboxURL.path)
    try vault.prepare()
    let readOnlyMode = try FileManager.default.attributesOfItem(atPath: vault.inboxURL.path)[.posixPermissions] as? NSNumber
    try require(readOnlyMode?.intValue == 0o400, "privacy migration must preserve an owner's read-only mode")
    let readOnlyContents = try checkRead(vault.inboxURL)
    try require(readOnlyContents == secondInbox, "permission migration must preserve Inbox contents")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vault.inboxURL.path)
    try checkInboxLinks()
    try require(FileManager.default.fileExists(atPath: vault.sessionsURL.path), "prepare should create Sessions/")
    try require(FileManager.default.fileExists(atPath: vault.assetsURL.path), "prepare should create assets/")

    try checkWrite("# Alpha Title  \nbody\n", to: root.appendingPathComponent("Alpha.md"))
    try checkWrite("no heading here\n", to: root.appendingPathComponent("Beta.md"))
    try checkWrite("\u{FEFF}# BOM Title\n", to: root.appendingPathComponent("Bom.md"))
    try checkWrite("# Hidden\n", to: root.appendingPathComponent(".Hidden.md"))
    try checkWrite("# Not markdown\n", to: root.appendingPathComponent("notes.txt"))
    try checkWrite("# 2026-10-13 Design\n", to: vault.sessionsURL.appendingPathComponent("2026-10-13 Design.md"))
    try checkWrite("plain session\n", to: vault.sessionsURL.appendingPathComponent("Plain.md"))
    try checkWrite("# Trigonometry\n", to: root.appendingPathComponent("science/math/trigonometry.md"))
    try checkWrite("# Archived Session\n", to: vault.sessionsURL.appendingPathComponent("Archive/Review.md"))
    try checkWrite("# Hidden Support Note\n", to: root.appendingPathComponent(".support/private.md"))
    try checkWrite("# Office Lock File\n", to: root.appendingPathComponent("~$draft.md"))
    try checkWrite("# Asset Note\n", to: vault.assetsURL.appendingPathComponent("docs/asset-note.md"))

    let notes = try vault.listNotes()
    let listed = notes.map { "\(checkKindName($0.kind))|\($0.title)" }
    let expectedList = [
        "note|Alpha Title",
        "note|Beta",
        "note|BOM Title",
        "inbox|Inbox",
        "session|2026-10-13 Design",
        "session|Archived Session",
        "session|Plain",
        "note|Trigonometry",
    ]
    try require(listed == expectedList, "listNotes returned \(listed)")
    let listedPaths = Set(notes.compactMap { vault.relativePath(of: $0.url) })
    try require(listedPaths.contains("science/math/trigonometry.md"), "listNotes must preserve nested vault-relative paths")
    try require(listedPaths.contains("Sessions/Archive/Review.md"), "nested session paths must remain discoverable")
    try require(!listedPaths.contains(".support/private.md"), "hidden support folders must not be searched as notes")
    try require(!listedPaths.contains("~$draft.md"), "Office lock files must not be searched as notes")
    try require(!listedPaths.contains("assets/docs/asset-note.md"), "assets must remain outside note discovery")

    try require(
        vault.uniqueNoteURL(forTitle: "Foo").lastPathComponent == "Foo.md",
        "a free title should map to Foo.md"
    )
    try checkWrite("# Foo\n", to: root.appendingPathComponent("Foo.md"))
    try require(
        vault.uniqueNoteURL(forTitle: "Foo").lastPathComponent == "Foo 2.md",
        "a taken Foo.md should map to Foo 2.md"
    )
    try checkWrite("# Foo 2\n", to: root.appendingPathComponent("Foo 2.md"))
    try require(
        vault.uniqueNoteURL(forTitle: "Foo").lastPathComponent == "Foo 3.md",
        "a taken Foo 2.md should map to Foo 3.md"
    )
    try checkUnsafeNoteListing()
    try checkSelectedRootSymlink()
    try checkRootAnchorAdoptsExternalCreation()
    try checkNoteNameResolution()
    try checkCaseInsensitiveAssetsExclusion()
    print("Vault checks passed.")
}

private func checkCaseInsensitiveAssetsExclusion() throws {
    let root = try checkMakeDirectory("vault-case-variant-assets")
    defer { checkRemoveDirectory(root) }
    let variantAssets = root.appendingPathComponent("ASSETS", isDirectory: true)
    try checkWrite("# Private asset note\n\ncasevariantassetsecret\n",
                   to: variantAssets.appendingPathComponent("docs/Asset note.md"))

    // Create the variant before Vault.init/prepare: on case-insensitive macOS,
    // preparing lowercase `assets` adopts this existing directory spelling.
    let vault = Vault(root: root)
    try vault.prepare()
    let paths = Set(try vault.listNotes().compactMap { vault.relativePath(of: $0.url) })
    try require(!paths.contains("ASSETS/docs/Asset note.md"),
                "assets with any root-level case spelling must be excluded from note discovery")
    try require(!paths.contains("assets/docs/Asset note.md"),
                "the managed assets directory must never be discovered as a note folder")
}

private func checkNoteNameResolution() throws {
    let root = try checkMakeDirectory("vault-note-name-resolution")
    defer { checkRemoveDirectory(root) }
    let vault = Vault(root: root)
    try vault.prepare()

    let math = root.appendingPathComponent("Science", isDirectory: true)
        .appendingPathComponent("Math", isDirectory: true)
    try FileManager.default.createDirectory(at: math, withIntermediateDirectories: true)
    let existing = math.appendingPathComponent("Trigonometry.md")
    try checkWrite("# Trigonometry\n\nkeep these bytes\n", to: existing)

    let resolved = try vault.resolveNoteName("science/math/trigonometry")
    try require(resolved.scope == .vault && resolved.relativePath == "Science/Math/Trigonometry.md",
                "existing path components should retain their case-insensitive canonical spelling")
    try require(resolved.id == "Science/Math/Trigonometry.md" && resolved.url == existing,
                "vault locations should retain relative-path IDs and absolute URLs")
    let existingContents = try checkRead(resolved.url)
    try require(existingContents == "# Trigonometry\n\nkeep these bytes\n",
                "resolving an existing note must leave its contents untouched")

    let missing = try vault.resolveNoteName("science/physics/quantum")
    try require(missing.relativePath == "Science/physics/quantum.md",
                "missing paths should reuse existing folder spelling and preserve new segments")
    try require(!FileManager.default.fileExists(atPath: math.appendingPathComponent("physics").path),
                "resolving a missing note must not create its folders")
    try require((try? vault.resolveNoteName("Assets/hidden-note")) == nil,
                "managed asset folders must not accept note destinations")

    let outside = root.appendingPathComponent("linked-note-target", isDirectory: true)
    try checkWrite("# External\n", to: outside.appendingPathComponent("Note.md"))
    let linked = root.appendingPathComponent("Linked", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    try require((try? vault.resolveNoteName("linked/note")) == nil,
                "case-insensitive folder matching must reject symbolic-link ancestors")

    let homeName = "Codex Issue 8 \(UUID().uuidString)"
    let homeLocation = try vault.resolveNoteName("/\(homeName)/Nested/Theory")
    let homeRoot = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
    let expectedHomeURL = homeRoot.appendingPathComponent(homeName, isDirectory: true)
        .appendingPathComponent("Nested", isDirectory: true)
        .appendingPathComponent("Theory.md")
    try require(homeLocation.scope == .home && homeLocation.relativePath == "\(homeName)/Nested/Theory.md",
                "leading slash paths should resolve below the user's home")
    try require(homeLocation.url == expectedHomeURL && homeLocation.id == expectedHomeURL.standardizedFileURL.absoluteString,
                "home locations should use canonical absolute file URL IDs")
    try require(!FileManager.default.fileExists(atPath: expectedHomeURL.deletingLastPathComponent().path),
                "resolving a home-relative destination must not create folders")

    let unavailableRoot = root.appendingPathComponent("NotMounted", isDirectory: true)
    let unavailableVault = Vault(root: unavailableRoot)
    let deferred = try unavailableVault.resolveNoteName("notes/math/queued")
    try require(deferred.url == unavailableRoot.appendingPathComponent("notes/math/queued.md"),
                "a missing vault should still yield a validated deterministic journal destination")
    try require(!FileManager.default.fileExists(atPath: unavailableRoot.path),
                "resolving against a missing vault must not create its root")
}

private func checkUnsafeNoteListing() throws {
    let base = try checkMakeDirectory("vault-listing-links")
    defer { checkRemoveDirectory(base) }
    let root = base.appendingPathComponent("Vault", isDirectory: true)
    let vault = Vault(root: root)
    try vault.prepare()
    let outside = base.appendingPathComponent("outside.md")
    try checkWrite("# Outside title\nprivate body\n", to: outside)
    let outsideDirectory = base.appendingPathComponent("outside-folder", isDirectory: true)
    try checkWrite("# Linked directory note\n", to: outsideDirectory.appendingPathComponent("Nested.md"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Symlink.md"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked folder", isDirectory: true), withDestinationURL: outsideDirectory)
    try FileManager.default.linkItem(at: outside, to: root.appendingPathComponent("Hardlink.md"))
    let fifo = root.appendingPathComponent("Waiting.md")
    try require(mkfifo(fifo.path, 0o600) == 0, "could not create FIFO fixture")

    let names = try vault.listNotes().map(\.url.lastPathComponent)
    let repeatedNames = try vault.listNotes().map(\.url.lastPathComponent)
    try require(names == repeatedNames, "repeated descriptor-backed listings must return the same notes")
    try require(!names.contains("Symlink.md"), "listNotes must skip symlink notes")
    try require(!names.contains("Hardlink.md"), "listNotes must skip hard-linked notes")
    try require(!names.contains("Waiting.md"), "listNotes must skip FIFOs without blocking")
    let paths = Set(try vault.listNotes().compactMap { vault.relativePath(of: $0.url) })
    try require(!paths.contains("Linked folder/Nested.md"), "recursive listing must not follow symlink directories")
}

private func checkSelectedRootSymlink() throws {
    let base = try checkMakeDirectory("vault-root-symlink")
    defer { checkRemoveDirectory(base) }
    let target = base.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let alias = base.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    let vault = Vault(root: alias)
    let targetVault = Vault(root: target)
    try vault.prepare()
    try require(vault.root.standardizedFileURL.path == targetVault.root.standardizedFileURL.path,
                "Vault should resolve a user-selected root symlink once")
    try require(FileManager.default.fileExists(atPath: target.appendingPathComponent("Inbox.md").path),
                "a resolved vault root symlink should remain writable")
}

private func checkRootAnchorAdoptsExternalCreation() throws {
    let base = try checkMakeDirectory("vault-root-created-later")
    defer { checkRemoveDirectory(base) }
    let root = base.appendingPathComponent("Vault", isDirectory: true)
    let vault = Vault(root: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let emptyListing = try vault.listNotes()
    try require(emptyListing.isEmpty, "an absent Sessions directory should be treated as an empty listing")
    let sessionDirectory = vault.sessionsURL
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let note = sessionDirectory.appendingPathComponent("External.md")
    try checkWrite("# External\nbody\n", to: note)

    guard let snapshot = try vault.fileSnapshot(relativePath: "Sessions/External.md"),
          let contents = snapshot.contents else {
        throw CheckFailure.failed("a root created after Vault initialization should be adopted for safe reads")
    }
    try require(String(decoding: contents, as: UTF8.self) == "# External\nbody\n",
                "the adopted root snapshot returned wrong bytes")
    let listed = try vault.listNotes()
    try require(listed.contains { $0.title == "External" && $0.kind == .session },
                "descriptor-backed listing should adopt an externally created root")
}

private func checkInboxLinks() throws {
    let root = try checkMakeDirectory("inbox-links")
    defer { checkRemoveDirectory(root) }
    let outside = root.appendingPathComponent("Outside.md")
    try checkWrite("outside bytes\n", to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
    let vault = Vault(root: root.appendingPathComponent("vault"))
    try FileManager.default.createDirectory(at: vault.root, withIntermediateDirectories: true)
    for symbolic in [true, false] {
        if symbolic { try FileManager.default.createSymbolicLink(at: vault.inboxURL, withDestinationURL: outside) }
        else { try FileManager.default.linkItem(at: outside, to: vault.inboxURL) }
        do {
            try vault.prepare()
            throw CheckFailure.failed("prepare must reject a linked Inbox instead of changing an outside target")
        } catch is CheckFailure { throw CheckFailure.failed("linked Inbox unexpectedly accepted") }
        catch {}
        let mode = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o644, "prepare must leave an outside linked target's permissions untouched")
        let contents = try checkRead(outside)
        try require(contents == "outside bytes\n", "prepare must leave an outside linked target's content untouched")
        try FileManager.default.removeItem(at: vault.inboxURL)
    }
}
