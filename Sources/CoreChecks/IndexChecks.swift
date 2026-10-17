import Darwin
import Core
import SQLite3
import Foundation

func checkSearchIndex() async throws {
    let base = try checkMakeDirectory("index")
    defer { checkRemoveDirectory(base) }
    let vaultRoot = base.appendingPathComponent("Vault", isDirectory: true)
    try checkWrite("# Private asset note\n\ncasevariantassetssecret\n",
                   to: vaultRoot.appendingPathComponent("ASSETS/docs/Asset note.md"))
    let vault = Vault(root: vaultRoot)
    let calendar = checkCalendar()
    let early = checkDate(2026, 10, 13, 10, 4)
    let latest = checkDate(2026, 10, 13, 15, 0)
    let sessions = SessionStore(stateDirectory: base.appendingPathComponent("State"), vault: vault, calendar: calendar, now: { early })
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let service = CaptureService(vault: vault, sessions: sessions, writer: writer, now: { early })
    _ = try await service.saveText("inboxpollen early", source: CaptureSource(), noteTitle: nil)
    let rootSave = try await service.saveText("A token bucket controls request rates. Café 😀 readers enjoy coffee. Extra words give this snippet enough context to read.", source: CaptureSource(appName: "Safari", windowTitle: "Reference"), noteTitle: "Café Networks")
    _ = try await service.saveText("The token economy has unrelated words.", source: CaptureSource(), noteTitle: "Other")
    let active = try await sessions.start(name: "Café Session")
    let sessionURL = vault.root.appendingPathComponent(active.notePath)
    _ = try await service.saveText("A token bucket session explanation.", source: CaptureSource(appName: "Xcode"), noteTitle: nil)
    let latestID = UUID()
    try await writer.append(Capture(id: latestID, createdAt: latest, content: .text("newestcapture " + String(repeating: "😀", count: 160)), source: CaptureSource()), to: sessionURL, title: active.name)
    _ = try await service.saveImage(png: Data([1, 2, 3, 4]), source: CaptureSource(appName: "Preview"), noteTitle: "Café Networks")
    let rootURL = rootSave.destination.url
    let rootPath = rootURL.lastPathComponent
    let manualURL = vault.root.appendingPathComponent("Manual.md")
    try checkWrite("# Café Manual\n\nA documentunique deletedterm paragraph.\n### ordinary heading\nHand edited content.\n", to: manualURL)
    let fallbackURL = vault.root.appendingPathComponent("No Title.md")
    try checkWrite("fallbackunique first line\n\nsecond paragraph", to: fallbackURL)
    try checkWrite("nestedindexneedle from a deeply nested note.\n",
                   to: vault.root.appendingPathComponent("science/math/Nested.md"))
    try FileManager.default.setAttributes([.modificationDate: early], ofItemAtPath: rootURL.path)
    try FileManager.default.setAttributes([.modificationDate: early.addingTimeInterval(60)], ofItemAtPath: sessionURL.path)
    try FileManager.default.setAttributes([.modificationDate: early.addingTimeInterval(120)], ofItemAtPath: manualURL.path)
    let databaseURL = base.appendingPathComponent("Cache/nested/search.sqlite")
    var imagePath = ""
    let beforeNotes = try vault.listNotes().map { ($0.url, try Data(contentsOf: $0.url)) }

    // This scope releases the connection before we simulate deletion of the disposable database.
    do {
        let index = try SearchIndex(vault: vault, databaseURL: databaseURL, calendar: calendar)
        let first = try await index.sync()
        try require(first.added == 7 && first.updated == 0 && first.removed == 0 && first.unchanged == 0, "first sync should add every note, including nested notes and Inbox")
        let excludedAssets = try await index.search("casevariantassetssecret")
        try require(excludedAssets.isEmpty, "mixed-case root assets folders must stay out of the note search index")
        let second = try await index.sync()
        try require(second.unchanged == 7 && second.added == 0 && second.updated == 0 && second.removed == 0, "second sync should be all unchanged")
        for (url, data) in beforeNotes {
            let after = try Data(contentsOf: url)
            try require(after == data, "indexing must never modify Markdown")
        }

        let prefix = try await index.search("toke")
        try require(prefix.count == 3 && prefix.contains { $0.captureID == rootSave.captureID }, "last query token should support prefix matching")
        let andHits = try await index.search("token bucket")
        try require(andHits.count == 2 && !andHits.contains { $0.notePath == "Other.md" }, "multiple query words must use AND")
        let reversed = try await index.search("bucket token")
        try require(reversed.count == 2, "AND matches should not depend on word order")
        let diacritics = try await index.search("cafe")
        try require(diacritics.contains { $0.notePath == rootPath }, "unicode61 should remove diacritics")
        let fallback = try await index.search("fallbackunique")
        try require(fallback.first?.noteTitle == "No Title" && fallback.first?.blockKind == .loose, "ordinary files should have fallback titles and searchable loose blocks")
        let nested = try await index.search("nestedindexneedle")
        try require(nested.count == 1 && nested[0].notePath == "science/math/Nested.md",
                    "search should index nested notes with their full vault-relative path")
        let rootHit = andHits.first { $0.captureID == rootSave.captureID }!
        let lookedUp = try await index.capture(id: rootSave.captureID)
        try require(rootHit.blockID > 0 && lookedUp?.blockID == rootHit.blockID && lookedUp?.body == rootHit.body && rootHit.body.contains("token bucket"), "hits and capture lookup must expose the block ID and full body")
        try require(rootHit.sourceApp == "Safari" && rootHit.windowTitle == "Reference" && rootHit.createdAt == early, "search should return capture metadata")
        let matched = rootHit.snippetMatches.map { String(rootHit.snippet[$0]) }.map { $0.lowercased() }
        try require(matched.contains("token") && matched.contains("bucket"), "snippet ranges should identify matched words")
        try require(!rootHit.snippet.contains("\u{02}") && !rootHit.snippet.contains("\u{03}"), "snippet delimiters should be stripped")
        let unicodeHit = diacritics.first { $0.captureID == rootSave.captureID }!
        try require(unicodeHit.snippetMatches.map { String(unicodeHit.snippet[$0]) }.contains("Café"), "diacritic snippet offsets should index the original Unicode word")
        for query in ["", "   ", "\"", "*", "AND", "OR NOT", "NEAR(", "-x", "a:b", "😀", String(repeating: "x", count: 2_000), "\" OR token*", "{body}:^token+bucket", "\u{00}token", "token -bucket", "\"\u{301}", "a\"\u{301}b", String(repeating: "token ", count: 1_000)] {
            _ = try await index.search(query)
        }
        let empty = try await index.search("AND * \"")
        try require(empty.isEmpty, "a fully stripped query should be empty")
        let zeroSearch = try await index.search("token", limit: 0)
        let negativeRecent = try await index.recent(limit: -1)
        let zeroSuggestions = try await index.titleSuggestions(prefix: "", limit: 0)
        try require(zeroSearch.isEmpty && negativeRecent.isEmpty && zeroSuggestions.isEmpty, "nonpositive limits should return no rows")

        let suggestions = try await index.titleSuggestions(prefix: "  CAFE  ")
        try require(suggestions.map(\.path) == ["Manual.md", active.notePath, rootPath], "title suggestions should fold diacritics and use modification order")
        try require(suggestions[0].modified == early.addingTimeInterval(120), "suggestions should expose note modification dates")
        let allSuggestions = try await index.titleSuggestions(prefix: "")
        try require(allSuggestions.count == 6 && allSuggestions.allSatisfy { $0.kind != .inbox }, "empty title prefix should include all notes except Inbox")
        let literalWildcard = try await index.titleSuggestions(prefix: "%")
        try require(literalWildcard.isEmpty, "title prefix wildcard characters must be literal")
        let recent = try await index.recent()
        try require(recent.count == 6 && recent[0].captureID == latestID && recent[0].noteKind == .session, "recent should order captures by date and exclude loose blocks")
        try require(recent[0].snippet.count == 140 && recent.allSatisfy { $0.snippetMatches.isEmpty }, "recent snippets should be 140 characters without highlights")
        let rootCount = try await index.captureCount(notePath: rootPath)
        let looseCount = try await index.captureCount(notePath: "Manual.md")
        let unknownCount = try await index.captureCount(notePath: "missing.md")
        try require(rootCount == 2 && looseCount == 0 && unknownCount == 0, "captureCount should count only capture blocks")

        let missing = try await index.assetsMissingText()
        try require(missing.count == 1, "new image blocks should need OCR")
        imagePath = missing[0]
        let titleImages = diacritics.filter { $0.blockKind == .image }
        try require(titleImages.count == 1 && titleImages[0].snippet == "Image" && titleImages[0].snippetMatches.isEmpty, "title-only image hits should have an Image snippet")
        try await index.setImageText(assetPath: imagePath, text: "diagramocr Café token schematic text", fingerprint: SearchIndex.imageFingerprint(try Data(contentsOf: vault.root.appendingPathComponent(imagePath))))
        let ocr = try await index.search("diagramocr")
        try require(ocr.count == 1 && ocr[0].assetPath == imagePath && ocr[0].blockKind == .image, "OCR should make image blocks searchable")
        try require(ocr[0].snippetMatches.map { String(ocr[0].snippet[$0]) } == ["diagramocr"], "OCR snippets should highlight OCR words")
        let noMissing = try await index.assetsMissingText()
        try require(noMissing.isEmpty, "current OCR should clear the backfill list")
        let embeddable = try await index.embeddableBlocks()
        let captureKey = rootPath + "#" + rootSave.captureID.uuidString.lowercased()
        let imageKey = ocr[0].embeddingKey
        try require(Set(embeddable.map(\.key)).count == embeddable.count && embeddable.count == 10,
                    "embeddable blocks should include captures, images, and loose paragraphs once")
        try require(embeddable.contains { $0.key == captureKey && $0.body == rootHit.body && $0.noteTitle == rootHit.noteTitle && $0.kind == .text },
                    "text embedding metadata should contain the full body, title, and capture key")
        try require(embeddable.contains { $0.key == imageKey && $0.assetPath == imagePath && $0.ocrText == "diagramocr Café token schematic text" && $0.kind == .image },
                    "image embedding metadata should expose OCR and the vault-relative asset")
        try require(embeddable.contains { $0.key == "No Title.md#loose-0" } && embeddable.contains { $0.key == "No Title.md#loose-1" },
                    "loose block keys should use their zero-based ordinal")
        let resolved = try await index.hits(forEmbeddingKeys: [captureKey, imageKey, "No Title.md#loose-0", "missing.md#loose-0", "bad", imageKey + "#ocr"])
        try require(resolved.count == 3 && resolved[captureKey]?.captureID == rootSave.captureID && resolved[imageKey]?.snippet == "diagramocr Café token schematic text" && resolved.values.allSatisfy { $0.snippetMatches.isEmpty },
                    "key resolution should omit unknown keys and return OCR/body snippets without highlights")
        // Filesystem Unicode normalization can differ from Session.notePath; use emitted keys.
        let longKey = embeddable.first { $0.key.hasSuffix(latestID.uuidString.lowercased()) }?.key ?? ""
        let longResolved = try await index.hits(forEmbeddingKeys: [longKey])
        try require(longResolved.values.first?.snippet.count == 140, "semantic snippets should truncate by characters, including Unicode session paths")

        // One note changes; no-op sync does not discard OCR, and reindexing its owner retains OCR too.
        try checkWrite(try checkRead(fallbackURL) + "\n\nappendedunique", to: fallbackURL)
        let changed = try await index.sync()
        try require(changed.updated == 1 && changed.unchanged == 6 && changed.added == 0 && changed.removed == 0, "one append should update exactly one note")
        try await index.reindex(note: rootURL)
        let stable = try await index.hits(forEmbeddingKeys: [captureKey, imageKey])
        try require(stable.count == 2 && stable[captureKey]?.body == rootHit.body, "embedding keys should survive row replacement on reindex")
        let retainedOCR = try await index.search("diagramocr")
        try require(retainedOCR.count == 1, "note reindexing must preserve image_text")
        let appendedID = UUID()
        try await writer.append(Capture(id: appendedID, createdAt: latest.addingTimeInterval(60), content: .text("immediateunique"), source: CaptureSource()), to: rootURL, title: rootSave.destination.title)
        try await index.reindex(note: rootURL)
        let immediate = try await index.search("immediateunique")
        try require(immediate.first?.captureID == appendedID, "reindex should make a newly appended capture immediately searchable")
        let countAfterAppend = try await index.captureCount(notePath: rootPath)
        try require(countAfterAppend == 3, "reindex should replace blocks without duplicating captures")
        let ownHit = try await index.capture(id: appendedID)
        let postReindex = try await index.sync()
        let afterOwnSync = try await index.capture(id: appendedID)
        try require(postReindex.unchanged == 7 && postReindex.updated == 0 && ownHit?.blockID == afterOwnSync?.blockID,
                    "sync after our own indexed append must leave rows intact without reindexing")
        try FileManager.default.removeItem(at: manualURL)
        let deleted = try await index.sync()
        let gone = try await index.search("deletedterm")
        let goneKeys = try await index.hits(forEmbeddingKeys: ["Manual.md#loose-0"])
        let remainingBlocks = try await index.embeddableBlocks()
        try require(goneKeys.isEmpty && !remainingBlocks.contains { $0.key.hasPrefix("Manual.md#") }, "deleted blocks should disappear from semantic enumeration and resolution")
        try require(deleted.removed == 1 && deleted.unchanged == 6 && gone.isEmpty, "deleted notes and their FTS rows must disappear")

        let assetURL = vault.root.appendingPathComponent(imagePath)
        try Data([1, 2, 3, 4, 5]).write(to: assetURL)
        let stale = try await index.assetsMissingText()
        try require(stale == [imagePath], "changed asset size should invalidate OCR")
        try await index.setImageText(assetPath: imagePath, text: "replacementocr", fingerprint: SearchIndex.imageFingerprint(try Data(contentsOf: vault.root.appendingPathComponent(imagePath))))
        let replaced = try await index.search("replacementocr")
        let oldOCR = try await index.search("diagramocr")
        try require(replaced.count == 1 && oldOCR.isEmpty, "upserting OCR should replace FTS text")
        try FileManager.default.setAttributes([.modificationDate: latest], ofItemAtPath: assetURL.path)
        let staleMtime = try await index.assetsMissingText()
        try require(staleMtime == [imagePath], "changed asset mtime alone should invalidate OCR")
        try await index.setImageText(assetPath: imagePath, text: "persistedocr", fingerprint: SearchIndex.imageFingerprint(try Data(contentsOf: vault.root.appendingPathComponent(imagePath))))
        // Invalid paths cannot access files outside the vault.
        do {
            try await index.setImageText(assetPath: "../outside.png", text: "bad", fingerprint: SearchIndex.imageFingerprint(Data()))
            throw CheckFailure.failed("setImageText should reject paths outside the vault")
        } catch is CheckFailure { throw CheckFailure.failed("setImageText accepted an outside path") }
        catch {}
    }

    do {
        let reopened = try SearchIndex(vault: vault, databaseURL: databaseURL, calendar: calendar)
        let stats = try await reopened.sync()
        let persisted = try await reopened.search("persistedocr")
        try require(stats.unchanged == 6 && persisted.count == 1, "a valid cache should reopen with OCR intact")
    }
    try removeIndexDatabase(databaseURL)
    do {
        let rebuilt = try SearchIndex(vault: vault, databaseURL: databaseURL, calendar: calendar)
        let stats = try await rebuilt.sync()
        let missing = try await rebuilt.assetsMissingText()
        let lostOCR = try await rebuilt.search("persistedocr")
        try require(stats.added == 6 && missing == [imagePath] && lostOCR.isEmpty, "a deleted cache must rebuild from Markdown and request fresh OCR")
        try await rebuilt.setImageText(assetPath: imagePath, text: "rebuiltocr", fingerprint: SearchIndex.imageFingerprint(try Data(contentsOf: vault.root.appendingPathComponent(imagePath))))
        let filled = try await rebuilt.assetsMissingText()
        try require(filled.isEmpty, "backfilled OCR should be current after rebuilding")
    }
    try removeIndexDatabase(databaseURL)
    try Data("not a SQLite database".utf8).write(to: databaseURL)
    do {
        let recovered = try SearchIndex(vault: vault, databaseURL: databaseURL, calendar: calendar)
        let stats = try await recovered.sync()
        try require(stats.added == 6, "corrupt files should be replaced with a fresh cache")
    }
    try setIndexVersion(databaseURL, version: 77)
    do {
        let migrated = try SearchIndex(vault: vault, databaseURL: databaseURL, calendar: calendar)
        let stats = try await migrated.sync()
        try require(stats.added == 6, "unknown schema versions should cause a rebuild")
    }
    try await checkIndexRankingAndSharedAssets()
    try await checkOCRFingerprintRace()
    try await checkIndexRejectsLinkedManagedReads()
    try await checkIndexSkipsUnreadableNote()
    print("SearchIndex checks passed.")
}

private func checkIndexSkipsUnreadableNote() async throws {
    // Root can read mode-000 files, so this filesystem behavior check only applies
    // to the normal non-root test account used by local and CI runs.
    guard getuid() != 0 else { return }

    let base = try checkMakeDirectory("index-unreadable-note")
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    let note = vault.root.appendingPathComponent("Unreadable.md")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: note.path)
        checkRemoveDirectory(base)
    }

    try vault.prepare()
    try checkWrite("# Unreadable\n\nunreadablecandidate\n", to: note)
    let index = try SearchIndex(vault: vault, databaseURL: base.appendingPathComponent("index.sqlite"), calendar: checkCalendar())
    let initial = try await index.sync()
    try require(initial.added == 2 && initial.removed == 0, "unreadable-note fixture should initially index Inbox and its note")
    let initialHits = try await index.search("unreadablecandidate")
    try require(initialHits.count == 1, "initially readable note should be searchable")

    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: note.path)
    let unreadable = try await index.sync()
    try require(unreadable.removed == 1 && unreadable.unchanged == 1,
                "unreadable note should be skipped like listNotes() and removed from the cache")
    let unreadableHits = try await index.search("unreadablecandidate")
    try require(unreadableHits.isEmpty, "a note skipped for unreadability should not remain searchable")

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: note.path)
    let restored = try await index.sync()
    try require(restored.added == 1 && restored.unchanged == 1 && restored.removed == 0,
                "a readable note should be indexed again after permissions are restored")
    let restoredHits = try await index.search("unreadablecandidate")
    try require(restoredHits.count == 1, "restored note should become searchable again")
}

private func checkIndexOperation<T>(_ label: String, operation: () async throws -> T) async throws -> T {
    do { return try await operation() }
    catch { throw CheckFailure.failed("\(label): \(error)") }
}

private func checkIndexRankingAndSharedAssets() async throws {
    let base = try checkMakeDirectory("index-ranking")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    let calendar = checkCalendar()
    let early = checkDate(2026, 10, 13, 10, 0)
    let later = early.addingTimeInterval(60)
    let writer = NoteWriter(vault: vault, calendar: calendar)
    try FileManager.default.createDirectory(at: vault.sessionsURL, withIntermediateDirectories: true)
    let titleID = UUID()
    let earlyID = UUID()
    let laterID = UUID()
    let titleURL = vault.root.appendingPathComponent("Title.md")
    try await writer.append(Capture(id: titleID, createdAt: early, content: .text("other words"), source: CaptureSource()), to: titleURL, title: "Needle")
    let bodyURL = vault.root.appendingPathComponent("Body.md")
    for (id, date) in [(earlyID, early), (laterID, later)] {
        try await writer.append(Capture(id: id, createdAt: date, content: .text("needle matching"), source: CaptureSource()), to: bodyURL, title: "Body")
    }
    let assetPath = "assets/shared image.png"
    try FileManager.default.createDirectory(at: vault.assetsURL, withIntermediateDirectories: true)
    try Data([1, 2]).write(to: vault.root.appendingPathComponent(assetPath))
    let rootImage = vault.root.appendingPathComponent("Images.md")
    let sessionImage = vault.sessionsURL.appendingPathComponent("Images.md")
    for note in [rootImage, sessionImage] {
        try await writer.append(Capture(id: UUID(), createdAt: early, content: .image(assetPath: assetPath), source: CaptureSource()), to: note, title: "Images")
    }
    let index = try SearchIndex(vault: vault, databaseURL: base.appendingPathComponent("index.sqlite"), calendar: calendar)
    _ = try await index.sync()
    let ranking = try await index.search("needle")
    try require(ranking.map(\.captureID) == [titleID, laterID, earlyID], "title weight should rank first; equal scores should favor newer captures")
    let one = try await index.search("needle", limit: 1)
    try require(one.first?.captureID == titleID && one.count == 1, "search should respect its limit after ranking")
    let missing = try await index.assetsMissingText()
    try require(missing == [assetPath], "shared asset backfill paths should be deduplicated")
    guard let imageSnapshot = try vault.fileSnapshot(relativePath: assetPath), let imageData = imageSnapshot.contents else {
        throw CheckFailure.failed("ranking fixture could not snapshot image bytes at \(assetPath)")
    }
    try await index.setImageText(assetPath: assetPath, text: "\u{02}café\u{03} sharedocr", fingerprint: SearchIndex.imageFingerprint(imageData))
    let shared = try await index.search("sharedocr")
    try require(shared.count == 2 && shared.allSatisfy { hit in hit.snippetMatches.map { String(hit.snippet[$0]) } == ["sharedocr"] }, "OCR should update every block referencing the same asset")
    let unicode = try await index.search("cafe")
    try require(unicode.count == 2 && unicode.allSatisfy { hit in hit.snippetMatches.map { String(hit.snippet[$0]) } == ["café"] }, "control characters in OCR must not corrupt highlight ranges")
    let bodyMatch = try await index.search("assets")
    try require(bodyMatch.count == 2 && bodyMatch.allSatisfy { $0.snippet.contains("![](") && !$0.snippetMatches.isEmpty }, "image body matches should use the body snippet")
    try await index.reindex(note: sessionImage)
    let afterReindex = try await index.search("cafe")
    try require(afterReindex.count == 2 && afterReindex.allSatisfy { hit in hit.snippetMatches.map { String(hit.snippet[$0]) } == ["café"] }, "reindexing should also sanitize reserved OCR snippet delimiters")
    try FileManager.default.removeItem(at: vault.root.appendingPathComponent(assetPath))
    let absent = try await index.assetsMissingText()
    try require(absent == [assetPath], "missing asset files should remain in the backfill list")
}

private func removeIndexDatabase(_ url: URL) throws {
    for suffix in ["", "-wal", "-shm"] {
        let path = url.path + suffix
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }
}

private func setIndexVersion(_ url: URL, version: Int) throws {
    var handle: OpaquePointer?
    let opened = sqlite3_open(url.path, &handle)
    defer { if let handle { sqlite3_close(handle) } }
    try require(opened == SQLITE_OK, "could not open check database to set schema version")
    try require(sqlite3_exec(handle, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK, "could not set check database version")
}

func checkSearchIndexPerformance() async throws {
    let base = try checkMakeDirectory("index-perf")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    try FileManager.default.createDirectory(at: vault.root, withIntermediateDirectories: true)
    let calendar = checkCalendar()
    // Construct the same exact on-disk capture grammar without timing formatter or fixture creation.
    for note in 0..<2_000 {
        var markdown = "# Synthetic \(note)\n\n"
        for capture in 0..<10 {
            let id = String(format: "00000000-0000-4000-8000-%012x", note * 10 + capture)
            markdown += "### 2026-10-13 10:\(String(format: "%02d", capture)) · Safari · Benchmark\n<!-- capture:\(id) -->\n\nA token bucket controls request rates with searchable text for note \(note), capture \(capture).\n\n"
        }
        try checkWrite(markdown, to: vault.root.appendingPathComponent("Synthetic \(note).md"))
    }
    let index = try SearchIndex(vault: vault, databaseURL: base.appendingPathComponent("Cache/search.sqlite"), calendar: calendar)
    let clock = ContinuousClock()
    var start = clock.now
    let coldStats = try await index.sync()
    let cold = indexSeconds(start.duration(to: clock.now))
    var warmSamples: [Double] = []
    for _ in 0..<5 {
        start = clock.now
        let warmStats = try await index.sync()
        warmSamples.append(indexSeconds(start.duration(to: clock.now)))
        try require(warmStats.added == 0 && warmStats.updated == 0 && warmStats.removed == 0 && warmStats.unchanged == 2_000,
                    "repeated no-change sync should leave all 2,000 notes unchanged")
    }
    let sortedWarmSamples = warmSamples.sorted()
    let warm = sortedWarmSamples[sortedWarmSamples.count / 2]
    var searches: [Double] = []
    for _ in 0..<20 {
        start = clock.now
        let hits = try await index.search("token bucket")
        searches.append(indexSeconds(start.duration(to: clock.now)))
        try require(hits.count == 40 && hits.allSatisfy { !$0.snippetMatches.isEmpty }, "benchmark query should return the default limit of highlighted hits")
    }
    searches.sort()
    let median = (searches[9] + searches[10]) / 2
    let warmSampleText = warmSamples.map { String(format: "%.1f", $0 * 1_000) }.joined(separator: ", ")
    print(String(format: "Index performance (2,000 notes × 10 captures): cold sync %.3f s; no-change sync samples [%@] ms, median %.1f ms; search median %.2f ms.", cold, warmSampleText, warm * 1_000, median * 1_000))
    try require(coldStats.added == 2_000, "performance fixture should index all notes")
    try require(cold < 6, "cold sync exceeded 6 seconds: \(cold)")
    try require(warm < 0.4, "no-change sync median exceeded 400 milliseconds: \(warm)")
    try require(median < 0.04, "search median exceeded 40 milliseconds: \(median)")
}

private func indexSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func checkOCRFingerprintRace() async throws {
    let base = try checkMakeDirectory("ocr-race")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    try vault.prepare()
    let calendar = checkCalendar()
    let path = "assets/race.png"
    let url = vault.root.appendingPathComponent(path)
    let original = Data([1, 2, 3, 4])
    let replacement = Data([4, 3, 2, 1])
    let modified = checkDate(2026, 10, 13, 10, 0)
    try original.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    guard let originalSnapshot = try vault.fileSnapshot(relativePath: path) else {
        throw CheckFailure.failed("OCR race fixture could not snapshot image A")
    }
    try require(originalSnapshot.contents == original, "OCR race fixture should begin with image A bytes")
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let capture = Capture(id: UUID(), createdAt: checkDate(2026, 10, 13, 10, 0), content: .image(assetPath: path), source: CaptureSource())
    try await writer.append(capture, to: vault.inboxURL, title: Vault.inboxTitle)
    let index = try SearchIndex(vault: vault, databaseURL: base.appendingPathComponent("index.sqlite"), calendar: calendar)
    _ = try await checkIndexOperation("OCR race sync") { try await index.sync() }
    let originalFingerprint = SearchIndex.imageFingerprint(original)
    _ = try await checkIndexOperation("OCR race initial store \(path)") {
        try await index.setImageText(assetPath: path, text: "originalocr", fingerprint: originalFingerprint)
    }
    // Replace during OCR, even preserving the old size and modification time.
    try replacement.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    guard let replacementSnapshot = try vault.fileSnapshot(relativePath: path) else {
        throw CheckFailure.failed("OCR race fixture could not snapshot replacement image B")
    }
    try require(replacementSnapshot.contents == replacement &&
                replacementSnapshot.size == originalSnapshot.size &&
                replacementSnapshot.modifiedSeconds == originalSnapshot.modifiedSeconds &&
                replacementSnapshot.modifiedNanoseconds == originalSnapshot.modifiedNanoseconds &&
                SearchIndex.imageFingerprint(replacement) != SearchIndex.imageFingerprint(original),
                "OCR race fixture must preserve exact descriptor mtime/size while changing its digest")
    let stored = try await checkIndexOperation("OCR race stale store \(path)") {
        try await index.setImageText(assetPath: path, text: "staleocr", fingerprint: originalFingerprint)
    }
    let staleHits = try await index.search("staleocr")
    let noteOnlyScan = try await checkIndexOperation("OCR race note-only scan \(path)") {
        try await index.assetsMissingText(recheckingAssetPaths: [])
    }
    let changedPathScan = try await checkIndexOperation("OCR race changed-path scan \(path)") {
        try await index.assetsMissingText(recheckingAssetPaths: [path])
    }
    let missing = try await checkIndexOperation("OCR race full scan \(path)") { try await index.assetsMissingText() }
    try require(!stored && staleHits.isEmpty && noteOnlyScan.isEmpty && changedPathScan == [path] && missing == [path],
                "Same-metadata replacement must be checked for changed paths and full scans, while note-only scans skip its digest (stored: \(stored), stale hits: \(staleHits.count), note-only: \(noteOnlyScan), changed paths: \(changedPathScan), full scan: \(missing))")
    let replacementStored = try await checkIndexOperation("OCR race replacement store \(path)") {
        try await index.setImageText(assetPath: path, text: "replacementocr", fingerprint: SearchIndex.imageFingerprint(replacement))
    }
    let currentHits = try await index.search("replacementocr")
    let currentChangedPathScan = try await checkIndexOperation("OCR race current changed-path scan \(path)") {
        try await index.assetsMissingText(recheckingAssetPaths: [path])
    }
    let currentMissing = try await checkIndexOperation("OCR race current full scan \(path)") { try await index.assetsMissingText() }
    try require(replacementStored && currentHits.count == 1 && currentChangedPathScan.isEmpty && currentMissing.isEmpty,
                "next OCR pass should store only image B's text")
}

private func checkIndexRejectsLinkedManagedReads() async throws {
    let base = try checkMakeDirectory("index-linked-reads")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    try vault.prepare()

    let outsideNote = base.appendingPathComponent("outside.md")
    try checkWrite("# External Note\noutside-note-secret\n", to: outsideNote)
    let symlinkNote = vault.root.appendingPathComponent("Outside symlink.md")
    let hardlinkNote = vault.root.appendingPathComponent("Outside hardlink.md")
    try FileManager.default.createSymbolicLink(at: symlinkNote, withDestinationURL: outsideNote)
    try FileManager.default.linkItem(at: outsideNote, to: hardlinkNote)
    let listed = try vault.listNotes().map(\.url.lastPathComponent)
    try require(!listed.contains(symlinkNote.lastPathComponent) && !listed.contains(hardlinkNote.lastPathComponent),
                "note listing must not expose linked outside content")

    let outsideAsset = base.appendingPathComponent("outside.png")
    let outsideAssetBytes = Data([9, 8, 7, 6])
    try outsideAssetBytes.write(to: outsideAsset)
    let symlinkAssetPath = "assets/outside-symlink.png"
    let hardlinkAssetPath = "assets/outside-hardlink.png"
    let assetPaths = [symlinkAssetPath, hardlinkAssetPath]
    let sharedModificationDate = checkDate(2026, 10, 13, 10, 0)
    for path in assetPaths {
        let url = vault.root.appendingPathComponent(path)
        try outsideAssetBytes.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: sharedModificationDate], ofItemAtPath: url.path)
    }
    let metadataOnly = try await checkIndexOperation("linked fixture metadata-only snapshot \(symlinkAssetPath)") {
        try vault.fileSnapshot(relativePath: symlinkAssetPath, includingContents: false)
    }
    let withContents = try await checkIndexOperation("linked fixture full snapshot \(symlinkAssetPath)") {
        try vault.fileSnapshot(relativePath: symlinkAssetPath)
    }
    try require(metadataOnly?.contents == nil && withContents?.contents == outsideAssetBytes,
                "vault snapshots must let metadata-only scans avoid returning image bytes")

    let writer = NoteWriter(vault: vault, calendar: checkCalendar())
    for path in assetPaths {
        try await writer.append(
            Capture(id: UUID(), createdAt: checkDate(2026, 10, 13, 10, 0),
                    content: .image(assetPath: path), source: CaptureSource()),
            to: vault.inboxURL, title: Vault.inboxTitle
        )
    }
    let index = try SearchIndex(vault: vault, databaseURL: base.appendingPathComponent("index.sqlite"), calendar: checkCalendar())
    _ = try await index.sync()
    for path in assetPaths {
        let stored = try await index.setImageText(
            assetPath: path, text: "validassetocr",
            fingerprint: SearchIndex.imageFingerprint(outsideAssetBytes)
        )
        try require(stored, "ordinary vault assets should accept OCR for their exact bytes")
        try FileManager.default.removeItem(at: vault.root.appendingPathComponent(path))
    }
    try FileManager.default.setAttributes([.modificationDate: sharedModificationDate], ofItemAtPath: outsideAsset.path)
    try FileManager.default.createSymbolicLink(
        at: vault.root.appendingPathComponent(symlinkAssetPath), withDestinationURL: outsideAsset
    )
    try FileManager.default.linkItem(at: outsideAsset, to: vault.root.appendingPathComponent(hardlinkAssetPath))

    let missing = try await checkIndexOperation("linked assets full OCR scan \(assetPaths)") {
        try await index.assetsMissingText()
    }
    let changedLink = try await checkIndexOperation("linked asset changed-path OCR scan \(hardlinkAssetPath)") {
        try await index.assetsMissingText(recheckingAssetPaths: [hardlinkAssetPath])
    }
    try require(Set(missing) == Set(assetPaths) && Set(changedLink) == Set(assetPaths),
                "full and changed-path scans must reject same-metadata linked assets (full: \(missing), changed: \(changedLink), expected: \(assetPaths))")

    for path in assetPaths {
        do {
            _ = try await index.setImageText(
                assetPath: path, text: "readoutsideafterlinksecret",
                fingerprint: SearchIndex.imageFingerprint(outsideAssetBytes)
            )
            throw CheckFailure.failed("setImageText read a linked outside asset at \(path)")
        } catch is CheckFailure {
            throw CheckFailure.failed("setImageText accepted a linked outside asset at \(path)")
        } catch {}
    }
    for note in [symlinkNote, hardlinkNote] {
        do {
            try await index.reindex(note: note)
            throw CheckFailure.failed("reindex read a linked outside note at \(note.lastPathComponent)")
        } catch is CheckFailure {
            throw CheckFailure.failed("reindex accepted a linked outside note at \(note.lastPathComponent)")
        } catch {}
    }

    let leakedNote = try await index.search("outside-note-secret")
    let leakedAsset = try await index.search("readoutsideafterlinksecret")
    try require(leakedNote.isEmpty && leakedAsset.isEmpty,
                "indexing linked notes or assets must not expose their outside contents")
}
