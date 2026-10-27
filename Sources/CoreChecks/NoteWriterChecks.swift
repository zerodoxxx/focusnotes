@_spi(Checks) import Core
import Darwin
import Foundation

func checkNoteWriter() async throws {
    let base = try checkMakeDirectory("writer")
    defer { checkRemoveDirectory(base) }
    let root = base.appendingPathComponent("Vault", isDirectory: true)
    let home = base.appendingPathComponent("Home", isDirectory: true)
    let calendar = checkCalendar()
    let vault = Vault(root: root, homeDirectoryURL: home)
    try vault.prepare()
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let when = checkDate(2026, 10, 13, 14, 30)

    try await checkTypedNoteShortWrite(vault: vault, calendar: calendar, date: when)

    let captureID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let block = "### Safari\n\(checkCaptureMarker(captureID)) at=2026-10-13T14:30:00+05:30 app=\"Safari\" -->\n\nHello\n"
    let capture = Capture(
        id: captureID,
        createdAt: when,
        content: .text("Hello"),
        source: CaptureSource(appName: "Safari")
    )

    // A missing file is created with its header, one blank line, then the block.
    let newNote = root.appendingPathComponent("New.md")
    try await writer.append(capture, to: newNote, title: "New")
    let newText = try checkRead(newNote)
    try require(newText == "# New\n\n" + block, "new file bytes were \(newText.debugDescription)")

    // Existing files always end with exactly one blank line before the new block.
    let separatorCases: [(name: String, before: String, expected: String)] = [
        ("no trailing newline", "# N\n\nold", "# N\n\nold\n\n" + block),
        ("one trailing newline", "# N\n\nold\n", "# N\n\nold\n\n" + block),
        ("two trailing newlines", "# N\n\nold\n\n", "# N\n\nold\n\n" + block),
        ("empty file", "", "# N\n\n" + block),
    ]
    for item in separatorCases {
        let url = root.appendingPathComponent("Separator \(item.name).md")
        try checkWrite(item.before, to: url)
        try await writer.append(capture, to: url, title: "N")
        let after = try checkRead(url)
        try require(after == item.expected, "\(item.name): got \(after.debugDescription)")
    }

    // Appending never changes the bytes already in the file.
    let keepURL = root.appendingPathComponent("Keep.md")
    try checkWrite("# Keep\n\nexisting \u{00E9} text\n", to: keepURL)
    let beforeBytes = try Data(contentsOf: keepURL)
    try await writer.append(capture, to: keepURL, title: "Keep")
    let afterBytes = try Data(contentsOf: keepURL)
    try require(afterBytes.starts(with: beforeBytes), "append changed existing bytes")

    // Independent writers race both exclusive creation and append offsets.
    let concurrentURL = root.appendingPathComponent("Concurrent.md")
    let ids = (0..<50).map { _ in UUID() }
    let writers = ids.map { _ in NoteWriter(vault: vault, calendar: calendar) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (index, id) in ids.enumerated() {
            let item = Capture(id: id, createdAt: when, content: .text("Line \(index)"), source: CaptureSource())
            group.addTask {
                try await writers[index].append(item, to: concurrentURL, title: "Concurrent")
            }
        }
        try await group.waitForAll()
    }
    let concurrentText = try checkRead(concurrentURL)
    try require(concurrentText.hasPrefix("# Concurrent\n\n"), "concurrent file should start with its header")
    try require(concurrentText.components(separatedBy: "# Concurrent\n").count - 1 == 1, "exclusive creation must not duplicate the header")
    let markerTotal = concurrentText.components(separatedBy: "<!-- capture:").count - 1
    try require(markerTotal == 50, "expected 50 capture markers, found \(markerTotal)")
    for id in ids {
        let count = concurrentText.components(separatedBy: checkCaptureMarker(id)).count - 1
        try require(count == 1, "marker \(checkCaptureMarker(id)) appeared \(count) times")
    }

    // Images are written under assets/ with a timestamped name.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let assetPath = try await writer.saveImage(png: png, createdAt: when)
    try require(
        assetPath.hasPrefix("assets/2026-10-13-143000-") && assetPath.hasSuffix(".png"),
        "unexpected asset path \(assetPath)"
    )
    let assetData = try Data(contentsOf: root.appendingPathComponent(assetPath))
    try require(assetData == png, "saved PNG bytes differ")
    try await checkImageLinksForManagedLocations(vault: vault, home: home, writer: writer,
                                                 assetPath: assetPath, calendar: calendar, when: when)
    try await checkSourceGrouping(vault: vault, calendar: calendar, capture: capture)
    try await checkPartialCaptureReplay(vault: vault, calendar: calendar, capture: capture)
    try await checkAtomicReplacement(vault: vault, calendar: calendar, capture: capture)
    try await checkAppendCache(vault: vault, calendar: calendar, capture: capture)
    try await checkCachedSourceParsing(vault: vault, calendar: calendar, capture: capture)
    try await checkInPlaceEditBeforeAppend(vault: vault, calendar: calendar, capture: capture)
    try await checkReplacementWhileWaitingForLock(vault: vault, calendar: calendar, capture: capture)
    try await checkRenameAwayWhileWaitingForLock(vault: vault, calendar: calendar, capture: capture)
    try await checkTypedNoteReplacementWhileWaitingForLock(vault: vault, calendar: calendar, date: when)
    try await checkUnsafeNoteTargets(calendar: calendar, capture: capture)
    print("NoteWriter checks passed.")
}

private func checkTypedNoteShortWrite(vault: Vault, calendar: Calendar, date: Date) async throws {
    let url = vault.root.appendingPathComponent("Typed short write.md")
    let original = "# Typed short write\n\nExisting body.\n"
    try checkWrite(original, to: url)
    let capture = Capture(id: UUID(), createdAt: date, content: .note("A complete typed body"), source: CaptureSource())
    let writer = NoteWriter(vault: vault, calendar: calendar)

    // setrlimit is process-wide; CoreChecks awaits each check in sequence, so nothing else writes meanwhile.
    var limit = rlimit()
    try require(getrlimit(RLIMIT_FSIZE, &limit) == 0, "could not read the file-size limit")
    let oldLimit = limit.rlim_cur
    // 90 bytes include the complete marker and separator, followed by only
    // part of the body, which reproduces the journal-replay failure mode.
    let appendAllowance = rlim_t(90)
    limit.rlim_cur = rlim_t(original.utf8.count) + appendAllowance
    try require(setrlimit(RLIMIT_FSIZE, &limit) == 0, "could not set the file-size limit")
    let oldHandler = signal(SIGXFSZ, SIG_IGN)
    defer {
        _ = signal(SIGXFSZ, oldHandler)
        limit.rlim_cur = oldLimit
        _ = setrlimit(RLIMIT_FSIZE, &limit)
    }

    do {
        try await writer.appendIfMissing(capture, to: Destination(url: url, title: "Typed short write", kind: .note),
                                         noteMarkerIsIdentity: true)
        throw CheckFailure.failed("a typed-note append beyond RLIMIT_FSIZE must fail")
    } catch let error as POSIXError {
        try require(error.code == .EFBIG, "a forced short write should report EFBIG")
    }
    let rolledBack = try checkRead(url)
    try require(rolledBack == original, "a failed typed-note append must roll back its marker and partial body")

    limit.rlim_cur = oldLimit
    try require(setrlimit(RLIMIT_FSIZE, &limit) == 0, "could not restore the file-size limit before replay")
    try await writer.appendIfMissing(capture, to: Destination(url: url, title: "Typed short write", kind: .note),
                                     noteMarkerIsIdentity: true)
    try await writer.appendIfMissing(capture, to: Destination(url: url, title: "Typed short write", kind: .note),
                                     noteMarkerIsIdentity: true)
    let contents = try checkRead(url)
    try require(contents.hasPrefix(original) && contents.contains("\nA complete typed body\n") &&
                contents.components(separatedBy: "<!-- note:\(capture.id.uuidString.lowercased()) at=").count - 1 == 1,
                "the retry after a short write must save the full typed note exactly once")
}

private func checkImageLinksForManagedLocations(vault: Vault, home: URL, writer: NoteWriter, assetPath: String,
                                                calendar: Calendar, when: Date) async throws {
    let homeNote = home.appendingPathComponent("Deep/Visual Notes.md")
    try checkWrite("# Visual Notes\n\nExisting text\n", to: homeNote)
    let capture = Capture(id: UUID(), createdAt: when, content: .image(assetPath: assetPath), source: CaptureSource())
    let destination = Destination(url: homeNote, title: "Visual Notes", kind: .note)
    let original = try Data(contentsOf: homeNote)
    try await writer.appendIfMissing(capture, to: destination)
    let written = try Data(contentsOf: homeNote)
    try require(written.starts(with: original), "writing a home-relative note must append without changing its existing bytes")
    try await writer.appendIfMissing(capture, to: destination)
    let replayed = try Data(contentsOf: homeNote)
    try require(replayed == written, "replaying an external image capture must remain idempotent")

    let homeText = String(decoding: written, as: UTF8.self)
    let homeLink = try markdownImageTarget(in: homeText)
    let resolvedHomeAsset = URL(string: homeLink, relativeTo: homeNote.deletingLastPathComponent())!.standardizedFileURL
    let expectedAsset = vault.root.appendingPathComponent(assetPath).standardizedFileURL
    try require(resolvedHomeAsset.path == expectedAsset.path, "home note image link should resolve to the vault-managed asset")
    let homeParsed = NoteParser.parse(contents: homeText, notePath: homeNote.absoluteString, titleFallback: "Visual Notes",
                                     calendar: calendar, assetRootURL: vault.assetsURL)
    try require(homeParsed.blocks.contains { $0.kind == .image && $0.assetPath == assetPath },
                "home-relative note image links should map back to the vault asset path")

    let rootNote = vault.root.appendingPathComponent("Root image note.md")
    var rootCapture = capture
    rootCapture.id = UUID()
    try await writer.append(rootCapture, to: rootNote, title: "Root image note")
    let rootText = try checkRead(rootNote)
    let rootLink = try markdownImageTarget(in: rootText)
    let resolvedRootAsset = URL(string: rootLink, relativeTo: rootNote.deletingLastPathComponent())!.standardizedFileURL
    try require(rootLink == assetPath && resolvedRootAsset.path == expectedAsset.path,
                "root note image link should use the vault-relative assets path")

    let nestedNote = vault.root.appendingPathComponent("Projects/Research/Deep/Nested.md")
    var nestedCapture = capture
    nestedCapture.id = UUID()
    try await writer.append(nestedCapture, to: nestedNote, title: "Nested")
    let nestedText = try checkRead(nestedNote)
    let nestedLink = try markdownImageTarget(in: nestedText)
    let resolvedNestedAsset = URL(string: nestedLink, relativeTo: nestedNote.deletingLastPathComponent())!.standardizedFileURL
    try require(nestedLink == "../../../\(assetPath)" && resolvedNestedAsset.path == expectedAsset.path,
                "depth-three nested note image link should walk back to the vault assets directory")

    let outside = vault.root.appendingPathComponent("Outside note.md")
    try checkWrite("outside bytes\n", to: outside)
    let linked = home.appendingPathComponent("Linked.md")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    do {
        try await writer.appendIfMissing(capture, to: Destination(url: linked, title: "Linked", kind: .note))
        throw CheckFailure.failed("home-relative note appends must reject a symlink target")
    } catch is CheckFailure { throw CheckFailure.failed("home note symlink unexpectedly accepted") }
    catch {}
    let outsideAfter = try checkRead(outside)
    try require(outsideAfter == "outside bytes\n", "a home-note symlink must not change its outside target")
}

private func markdownImageTarget(in contents: String) throws -> String {
    guard let line = contents.components(separatedBy: "\n").first(where: { $0.hasPrefix("![](") && $0.hasSuffix(")") }) else {
        throw CheckFailure.failed("image capture did not contain a Markdown image link")
    }
    return String(line.dropFirst(4).dropLast())
}

private func checkUnsafeNoteTargets(calendar: Calendar, capture: Capture) async throws {
    let base = try checkMakeDirectory("writer-links")
    defer { checkRemoveDirectory(base) }
    let root = base.appendingPathComponent("Vault", isDirectory: true)
    let vault = Vault(root: root)
    try vault.prepare()
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let outside = base.appendingPathComponent("outside.md")
    try checkWrite("outside bytes\n", to: outside)

    let symlink = vault.root.appendingPathComponent("Linked.md")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    do {
        try await writer.append(capture, to: symlink, title: "Linked")
        throw CheckFailure.failed("note appends must reject a symlink target")
    } catch is CheckFailure { throw CheckFailure.failed("note symlink unexpectedly accepted") }
    catch let error as POSIXError {
        try require(error.code == .ELOOP, "a symlink note append should report ELOOP (O_NOFOLLOW), got \(error.code)")
    }
    let afterSymlink = try checkRead(outside)
    try require(afterSymlink == "outside bytes\n", "a symlink note append changed the outside file")

    try FileManager.default.removeItem(at: symlink)
    let hardlink = vault.root.appendingPathComponent("Hardlinked.md")
    try FileManager.default.linkItem(at: outside, to: hardlink)
    do {
        try await writer.append(capture, to: hardlink, title: "Hardlinked")
        throw CheckFailure.failed("note appends must reject a hard-linked target")
    } catch is CheckFailure { throw CheckFailure.failed("hard-linked note unexpectedly accepted") }
    catch let error as POSIXError {
        try require(error.code == .EPERM, "a hard-linked note append should report EPERM, got \(error.code)")
    }
    let afterHardlink = try checkRead(outside)
    try require(afterHardlink == "outside bytes\n", "a hard-linked note append changed the outside file")

    let outsidePNG = base.appendingPathComponent("outside.png")
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    try png.write(to: outsidePNG)
    let linkedAsset = vault.assetsURL.appendingPathComponent("Linked.png")
    try FileManager.default.createSymbolicLink(at: linkedAsset, withDestinationURL: outsidePNG)
    var imageCapture = capture
    imageCapture.id = UUID()
    imageCapture.content = .image(assetPath: "assets/Linked.png")
    do {
        try await writer.appendIfMissing(imageCapture,
                                         to: Destination(url: vault.root.appendingPathComponent("Linked asset.md"), title: "Linked asset", kind: .note),
                                         png: png)
        throw CheckFailure.failed("asset replay must reject a symlink target")
    } catch is CheckFailure { throw CheckFailure.failed("symlink asset replay unexpectedly succeeded") }
    catch {}
    let afterAssetSymlink = try Data(contentsOf: outsidePNG)
    try require(afterAssetSymlink == png, "asset replay through a symlink changed outside bytes")

    try FileManager.default.removeItem(at: linkedAsset)
    let hardlinkedAsset = vault.assetsURL.appendingPathComponent("Hardlinked.png")
    try FileManager.default.linkItem(at: outsidePNG, to: hardlinkedAsset)
    imageCapture.id = UUID()
    imageCapture.content = .image(assetPath: "assets/Hardlinked.png")
    do {
        try await writer.appendIfMissing(imageCapture,
                                         to: Destination(url: vault.root.appendingPathComponent("Hardlinked asset.md"), title: "Hardlinked asset", kind: .note),
                                         png: png)
        throw CheckFailure.failed("asset replay must reject a hard-linked target")
    } catch is CheckFailure { throw CheckFailure.failed("hard-linked asset replay unexpectedly succeeded") }
    catch {}
    let afterAssetHardlink = try Data(contentsOf: outsidePNG)
    try require(afterAssetHardlink == png, "asset replay through a hard link changed outside bytes")
}

private final class InPlaceSourceEditor: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private(set) var error: Error?

    func arm() {
        lock.lock()
        defer { lock.unlock() }
        armed = true
    }

    func edit(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard armed else { return }
        armed = false
        do {
            let before = try String(contentsOf: url, encoding: .utf8)
            let bytes = Data(before.replacingOccurrences(of: "### Safari\n", with: "### Chrome\n").utf8)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: bytes)
        } catch { self.error = error }
    }
}

private func checkInPlaceEditBeforeAppend(vault: Vault, calendar: Calendar, capture: Capture) async throws {
    let editor = InPlaceSourceEditor()
    let writer = NoteWriter(vault: vault, calendar: calendar, beforeAppend: { editor.edit($0) }, afterAppend: { _ in })
    let url = vault.root.appendingPathComponent("Prewrite edit.md")
    let destination = Destination(url: url, title: "Prewrite edit", kind: .note)
    try await writer.appendIfMissing(capture, to: destination)
    editor.arm()
    var next = capture
    next.id = UUID(); next.content = .text("After racing edit")
    try await writer.appendIfMissing(next, to: destination)
    let contents = try checkRead(url)
    let statistics = await writer.appendCacheStatistics
    try require(editor.error == nil, "in-place prewrite fixture failed")
    try require(statistics.fullScans == 2, "a detected in-place edit must retry and rescan before writing")
    try require(contents.contains("### Chrome\n" + checkCaptureMarker(capture.id)) &&
                contents.contains("### Safari\n" + checkCaptureMarker(next.id)),
                "a detected edit must recompute the source heading and preserve editor bytes")
    try require(contents.components(separatedBy: checkCaptureMarker(next.id)).count - 1 == 1, "prewrite retry must append the new capture exactly once")
}

private func checkReplacementWhileWaitingForLock(vault: Vault, calendar: Calendar, capture: Capture) async throws {
    let url = vault.root.appendingPathComponent("Lock replacement.md")
    try checkWrite("# Lock replacement\n\nold body\n", to: url)
    let lockDescriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    try require(lockDescriptor >= 0, "could not open the lock fixture")
    var held = flock(lockDescriptor, LOCK_EX) == 0
    defer { if held { _ = flock(lockDescriptor, LOCK_UN) }; close(lockDescriptor) }
    try require(held, "could not lock the fixture note")

    let writer = NoteWriter(vault: vault, calendar: calendar)
    let append = Task.detached { try await writer.append(capture, to: url, title: "Lock replacement") }
    // The append blocks on the held flock. If it has not opened the note yet, it
    // simply sees the replacement, so a slow start can only weaken this check.
    try await Task.sleep(nanoseconds: 300_000_000)
    // An atomic save unlinks the locked inode (nlink 0) and installs a new one.
    try Data("# Replacement\n\neditor kept this\n".utf8).write(to: url, options: .atomic)
    _ = flock(lockDescriptor, LOCK_UN)
    held = false
    try await append.value

    let text = try checkRead(url)
    try require(text.hasPrefix("# Replacement\n\neditor kept this\n"), "a replacement must keep the editor's bytes")
    try require(text.components(separatedBy: checkCaptureMarker(capture.id)).count - 1 == 1,
                "an append interrupted by a replacement must land once on the current note")
}

/// A note moved away (for example by a session rename) while an append waited must not be recreated at its old path.
/// If the append starts only after the move, it is a first attempt that may create the note; that run is inconclusive.
private func checkRenameAwayWhileWaitingForLock(vault: Vault, calendar: Calendar, capture: Capture) async throws {
    let url = vault.root.appendingPathComponent("Moved away.md")
    let movedURL = vault.root.appendingPathComponent("Moved away elsewhere.md")
    let original = "# Moved away\n\nold body\n"
    try checkWrite(original, to: url)
    let lockDescriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    try require(lockDescriptor >= 0, "could not open the lock fixture")
    var held = flock(lockDescriptor, LOCK_EX) == 0
    defer { if held { _ = flock(lockDescriptor, LOCK_UN) }; close(lockDescriptor) }
    try require(held, "could not lock the fixture note")

    let writer = NoteWriter(vault: vault, calendar: calendar)
    let append = Task.detached { () -> Error? in
        do { try await writer.append(capture, to: url, title: "Moved away"); return nil }
        catch { return error }
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    try FileManager.default.moveItem(at: url, to: movedURL)
    _ = flock(lockDescriptor, LOCK_UN)
    held = false
    let failure = await append.value

    let movedText = try checkRead(movedURL)
    try require(movedText == original, "the moved note must stay untouched")
    if failure == nil {
        // Slow start: the append only began after the move, so it legitimately created a fresh
        // note on the missing path (first attempt). Accept only that, as an inconclusive run.
        let fresh = try checkRead(url)
        try require(fresh.hasPrefix("# Moved away\n\n") && !fresh.contains("old body") &&
                    fresh.components(separatedBy: checkCaptureMarker(capture.id)).count - 1 == 1,
                    "an append that succeeded must have created a fresh note, not touched the old one")
        return
    }
    try require((failure as? POSIXError)?.code == .ENOENT, "an append to a moved-away note must fail with ENOENT, got \(String(describing: failure))")
    try require(!FileManager.default.fileExists(atPath: url.path), "an append must not recreate the moved-away path")
}

/// A typed-note save to an existing note locks it first; a replacement while waiting must be retried, not rejected.
private func checkTypedNoteReplacementWhileWaitingForLock(vault: Vault, calendar: Calendar, date: Date) async throws {
    let url = vault.root.appendingPathComponent("Typed lock replacement.md")
    try checkWrite("# Typed lock replacement\n\nold body\n", to: url)
    let lockDescriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    try require(lockDescriptor >= 0, "could not open the lock fixture")
    var held = flock(lockDescriptor, LOCK_EX) == 0
    defer { if held { _ = flock(lockDescriptor, LOCK_UN) }; close(lockDescriptor) }
    try require(held, "could not lock the fixture note")

    let capture = Capture(id: UUID(), createdAt: date, content: .note("typed body after replacement"), source: CaptureSource())
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let save = Task.detached {
        try await writer.appendIfMissing(capture, to: Destination(url: url, title: "Typed lock replacement", kind: .note),
                                         noteMarkerIsIdentity: true)
    }
    // As above, a slow start can only weaken this check.
    try await Task.sleep(nanoseconds: 300_000_000)
    try Data("# Replacement\n\neditor kept this\n".utf8).write(to: url, options: .atomic)
    _ = flock(lockDescriptor, LOCK_UN)
    held = false
    try await save.value

    let text = try checkRead(url)
    try require(text.hasPrefix("# Replacement\n\neditor kept this\n") && text.contains("\ntyped body after replacement\n") &&
                text.components(separatedBy: "<!-- note:\(capture.id.uuidString.lowercased()) at=").count - 1 == 1,
                "a typed-note save interrupted by a replacement must land once on the current note")
}

private func checkAppendCache(vault: Vault, calendar: Calendar, capture: Capture) async throws {
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let url = vault.root.appendingPathComponent("Cached.md")
    let destination = Destination(url: url, title: "Cached", kind: .note)
    try checkWrite("# Cached\n\n" + String(repeating: "old content\n", count: 100_000), to: url)
    try await writer.appendIfMissing(capture, to: destination)
    var next = capture
    next.id = UUID(); next.content = .text("Second cached body")
    try await writer.appendIfMissing(next, to: destination)
    let saved = try Data(contentsOf: url)
    try await writer.appendIfMissing(capture, to: destination)
    let replayed = try Data(contentsOf: url)
    var statistics = await writer.appendCacheStatistics
    try require(replayed == saved && statistics.fullScans == 1, "warm appends/replay should use one initial scan and exact block verification")

    // Same inode, same size and restored mtime: ctime must still invalidate source state.
    var beforeEdit = stat()
    try require(stat(url.path, &beforeEdit) == 0, "could not read the cache invalidation fixture's timestamps")
    let edited = String(decoding: saved, as: UTF8.self).replacingOccurrences(of: "### Safari\n", with: "### Chrome\n")
    try checkWrite(edited, to: url)
    let times = [beforeEdit.st_atimespec, beforeEdit.st_mtimespec]
    let restored = times.withUnsafeBufferPointer { utimensat(AT_FDCWD, url.path, $0.baseAddress, 0) }
    try require(restored == 0, "could not restore the cache invalidation fixture's exact mtime")
    var afterEditStat = stat()
    try require(stat(url.path, &afterEditStat) == 0, "could not inspect the edited cache invalidation fixture")
    try require(afterEditStat.st_ino == beforeEdit.st_ino && afterEditStat.st_size == beforeEdit.st_size &&
                afterEditStat.st_mtimespec.tv_sec == beforeEdit.st_mtimespec.tv_sec &&
                afterEditStat.st_mtimespec.tv_nsec == beforeEdit.st_mtimespec.tv_nsec,
                "cache invalidation fixture must preserve inode, size, and nanosecond mtime")
    try require(afterEditStat.st_ctimespec.tv_sec != beforeEdit.st_ctimespec.tv_sec ||
                afterEditStat.st_ctimespec.tv_nsec != beforeEdit.st_ctimespec.tv_nsec,
                "cache invalidation fixture must change ctime")
    next.id = UUID(); next.content = .text("After same-size edit")
    try await writer.appendIfMissing(next, to: destination)
    let afterEdit = try checkRead(url)
    statistics = await writer.appendCacheStatistics
    try require(statistics.fullScans == 2 && afterEdit.contains("### Safari\n" + checkCaptureMarker(next.id)), "same-size edits must invalidate cached source context")

    // An atomic editor save can preserve every byte while replacing the inode.
    try Data(afterEdit.utf8).write(to: url, options: .atomic)
    try await writer.appendIfMissing(next, to: destination)
    let afterReplacement = try checkRead(url)
    statistics = await writer.appendCacheStatistics
    try require(statistics.fullScans == 3 && afterReplacement == afterEdit, "replacement must rescan and keep replay idempotent")

    // The metadata cache is bounded even when captures visit many destinations.
    for index in 0..<12 {
        next.id = UUID()
        let note = vault.root.appendingPathComponent("Cache limit \(index).md")
        try await writer.appendIfMissing(next, to: Destination(url: note, title: "Cache limit", kind: .note))
    }
    statistics = await writer.appendCacheStatistics
    try require(statistics.cachedFiles <= 8, "append cache must evict old destinations")
    let scansBefore = statistics.fullScans
    try await writer.appendIfMissing(capture, to: destination)
    statistics = await writer.appendCacheStatistics
    try require(statistics.fullScans == scansBefore + 1, "an evicted destination must safely rescan for a replay")
}

private func checkCachedSourceParsing(vault: Vault, calendar: Calendar, capture: Capture) async throws {
    // Compare one persistent writer against fresh full-scan writers after every
    // append, including open fences, legacy grouping and headings inside notes.
    let cached = vault.root.appendingPathComponent("Source cached.md")
    let fresh = vault.root.appendingPathComponent("Source fresh.md")
    let legacy = "# Source\n\n### 2026-10-13 14:30 · Safari\n<!-- capture:\(UUID().uuidString.lowercased()) -->\n\nlegacy\n"
    try checkWrite(legacy, to: cached)
    try checkWrite(legacy, to: fresh)
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let bodies: [CaptureContent] = [
        .text("ordinary"), .text("```markdown\n## fenced heading\n```"),
        .text("~~~\n# still fenced"), .text("### hidden source\n~~~"),
        .note("## Note section\nbody"), .text("after a note heading"),
        .subheading("Details"), .text("after a subheading"),
        .text("````\n```\n## fenced\n````"), .text("final"),
    ]
    for content in bodies {
        var item = capture
        item.id = UUID(); item.content = content
        try await writer.appendIfMissing(item, to: Destination(url: cached, title: "Source", kind: .note))
        let other = NoteWriter(vault: vault, calendar: calendar)
        try await other.appendIfMissing(item, to: Destination(url: fresh, title: "Source", kind: .note))
        let cachedBytes = try Data(contentsOf: cached)
        let freshBytes = try Data(contentsOf: fresh)
        try require(cachedBytes == freshBytes, "incremental source grouping must match full scans across fences, notes, and legacy markers")
        for source in ["Safari", "Chrome", "Unknown source"] {
            try require(NoteWriter.sourceGroupingMatchesFullParser(String(decoding: cachedBytes, as: UTF8.self), source: source, calendar: calendar), "source scanner must agree with the full note parser")
        }
    }
    for suffix in ["\r\n### Safari\r\n", "\n### Chrome", "\n~~~\n## fenced", "\n### Safari\n<!-- capture:\(capture.id.uuidString.lowercased()) -->", "\n    ```\n# indented"] {
        try require(NoteWriter.sourceGroupingMatchesFullParser(legacy + suffix, source: "Safari", calendar: calendar), "source scanner must preserve partial-line and fence semantics")
    }
}

private func checkPartialCaptureReplay(vault: Vault, calendar: Calendar, capture: Capture) async throws {
    let block = CaptureFormat.block(for: capture, noteRelativeDir: "", calendar: calendar)
    let writer = NoteWriter(vault: vault, calendar: calendar)
    for (offset, fragment) in [String(block[..<block.range(of: " -->")!.upperBound]), String(block.dropLast(3))].enumerated() {
        let url = vault.root.appendingPathComponent("Partial \(offset).md")
        try checkWrite("# Partial\n\n" + fragment, to: url)
        let before = try Data(contentsOf: url)
        let destination = Destination(url: url, title: "Partial", kind: .note)
        try await writer.appendIfMissing(capture, to: destination)
        let after = try Data(contentsOf: url)
        try require(after.starts(with: before), "partial recovery must preserve every existing byte")
        let text = String(decoding: after, as: UTF8.self)
        try require(text.components(separatedBy: checkCaptureMarker(capture.id)).count - 1 == 2, "a partial block must be followed by a full replay block")
        let parsed = NoteParser.parse(contents: text, notePath: url.lastPathComponent, titleFallback: "", calendar: calendar)
        try require(parsed.blocks.count == 1 && parsed.blocks[0].captureID == capture.id && parsed.blocks[0].body == "Hello", "parser must prefer the last full occurrence of a repeated capture")
        try await writer.appendIfMissing(capture, to: destination)
        let repeated = try Data(contentsOf: url)
        try require(repeated == after, "replay of a complete block must be a byte-for-byte no-op")
        let index = try SearchIndex(vault: vault, databaseURL: vault.root.appendingPathComponent("partial-index.sqlite"), calendar: calendar)
        try await index.reindex(note: url)
        let count = try await index.captureCount(notePath: url.lastPathComponent)
        let hits = try await index.search("Hello")
        try require(count == 1 && hits.filter { $0.notePath == url.lastPathComponent }.count == 1, "repeated markers must produce one search row")
    }
}

private final class EditorReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private(set) var error: Error?
    let copyAppend: Bool

    init(copyAppend: Bool, count: Int = 1) { self.copyAppend = copyAppend; remaining = count }

    func replace(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return }
        remaining -= 1
        do {
            let bytes = copyAppend ? try Data(contentsOf: url) : Data("# Replacement\n\neditor kept this\n".utf8)
            try bytes.write(to: url, options: .atomic)
        } catch { self.error = error }
    }
}

private func checkAtomicReplacement(vault: Vault, calendar: Calendar, capture: Capture) async throws {
    for copiesAppend in [false, true] {
        let url = vault.root.appendingPathComponent("Replacement \(copiesAppend).md")
        let editor = EditorReplacement(copyAppend: copiesAppend)
        let writer = NoteWriter(vault: vault, calendar: calendar, afterAppend: { editor.replace($0) })
        try await writer.appendIfMissing(capture, to: Destination(url: url, title: "Replacement", kind: .note))
        let text = try checkRead(url)
        try require(editor.error == nil, "atomic replacement fixture failed")
        try require(text.components(separatedBy: checkCaptureMarker(capture.id)).count - 1 == 1 && text.contains("Hello\n"), "replacement retry must keep exactly one full capture on the current inode")
        if !copiesAppend { try require(text.contains("editor kept this"), "replacement retry must preserve the editor's bytes") }
    }
    let editor = EditorReplacement(copyAppend: false, count: 10)
    let writer = NoteWriter(vault: vault, calendar: calendar, afterAppend: { editor.replace($0) })
    do {
        try await writer.appendIfMissing(capture, to: Destination(url: vault.root.appendingPathComponent("Unstable.md"), title: "Unstable", kind: .note))
        throw CheckFailure.failed("continually replaced notes must fail rather than silently lose an append")
    } catch is CheckFailure { throw CheckFailure.failed("unstable note unexpectedly succeeded") }
    catch {}
    try require(editor.error == nil, "bounded replacement fixture failed")
}

private func checkSourceGrouping(vault: Vault, calendar: Calendar, capture: Capture) async throws {
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let note = vault.root.appendingPathComponent("Grouped.md")
    let destination = Destination(url: note, title: "Grouped", kind: .note)
    try await writer.appendIfMissing(capture, to: destination)
    var repeatCapture = capture
    repeatCapture.id = UUID(); repeatCapture.content = .text("Repeat body")
    try await writer.appendIfMissing(repeatCapture, to: destination)
    let repeated = try checkRead(note)
    try require(repeated.components(separatedBy: "### Safari\n").count - 1 == 1, "same source must omit its heading")
    try require(repeated.contains("Hello\n\n" + checkCaptureMarker(repeatCapture.id)), "heading-less capture separator changed")
    try await writer.appendIfMissing(repeatCapture, to: destination)
    let retried = try checkRead(note)
    try require(retried == repeated, "heading-less retry must not duplicate a capture")
    // Heading-like lines in fenced code must not force another heading.
    let handle = try FileHandle(forWritingTo: note)
    try handle.seekToEnd(); try handle.write(contentsOf: Data("\n```markdown\n## code heading\n```\n".utf8)); try handle.close()
    repeatCapture.id = UUID()
    try await writer.appendIfMissing(repeatCapture, to: destination)
    let fenced = try checkRead(note)
    try require(fenced.components(separatedBy: "### Safari\n").count - 1 == 1, "fenced headings must not force re-emission")
    let subheading = Capture(id: UUID(), createdAt: capture.createdAt, content: .subheading("### Details\n next"), source: CaptureSource())
    try await writer.appendIfMissing(subheading, to: destination)
    let beforeRetry = try checkRead(note)
    try await writer.appendIfMissing(subheading, to: destination)
    let subheadingRetried = try checkRead(note)
    try require(subheadingRetried == beforeRetry && beforeRetry.contains("## Details next\n<!-- subheading:"), "subheading must be cleaned and idempotent")
    repeatCapture.id = UUID()
    try await writer.appendIfMissing(repeatCapture, to: destination)
    let afterSubheading = try checkRead(note)
    try require(afterSubheading.components(separatedBy: "### Safari\n").count - 1 == 2, "subheading must force a source heading")
    repeatCapture.id = UUID(); repeatCapture.source.windowTitle = "Other page - Google Chrome"
    try await writer.appendIfMissing(repeatCapture, to: destination)
    let changed = try checkRead(note)
    try require(changed.contains("### Other page\n" + checkCaptureMarker(repeatCapture.id)), "changed source must emit a heading")
    let legacyNote = vault.root.appendingPathComponent("Legacy replay.md")
    let legacy = "# Legacy\n\n### 2026-10-13 14:30 · Safari\n<!-- capture:\(capture.id.uuidString.lowercased()) -->\n\nHello\n"
    try checkWrite(legacy, to: legacyNote)
    try await writer.appendIfMissing(capture, to: Destination(url: legacyNote, title: "Legacy", kind: .note))
    let legacyAfter = try checkRead(legacyNote)
    try require(legacyAfter == legacy, "upgraded replay must not duplicate a complete legacy capture")
    let damaged = vault.root.appendingPathComponent("Interrupted metadata.md")
    let metadataFragment = "# Interrupted\n\n### Safari\n" + checkCaptureMarker(capture.id) + " at=2026-10"
    try checkWrite(metadataFragment, to: damaged)
    try await writer.appendIfMissing(capture, to: Destination(url: damaged, title: "Interrupted", kind: .note))
    let damagedAfter = try checkRead(damaged)
    let recovered = NoteParser.parse(contents: damagedAfter, notePath: damaged.lastPathComponent, titleFallback: "", calendar: calendar)
    try require(damagedAfter.hasPrefix(metadataFragment) && recovered.blocks.filter { $0.captureID == capture.id && $0.body == "Hello" }.count == 1,
                "interrupted metadata must retain its bytes and recover one complete capture")
    // Independent writers must decide under the same lock.
    let concurrent = vault.root.appendingPathComponent("Grouped concurrent.md")
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<20 {
            let item = Capture(id: UUID(), createdAt: capture.createdAt, content: .text("Concurrent body"), source: capture.source)
            group.addTask {
                let other = NoteWriter(vault: vault, calendar: calendar)
                try await other.appendIfMissing(item, to: Destination(url: concurrent, title: "Concurrent", kind: .note))
            }
        }
        try await group.waitForAll()
    }
    let text = try checkRead(concurrent)
    try require(text.components(separatedBy: "### Safari\n").count - 1 == 1 && text.components(separatedBy: "<!-- capture:").count - 1 == 20,
                "concurrent source decisions must emit one heading and every capture")
}
