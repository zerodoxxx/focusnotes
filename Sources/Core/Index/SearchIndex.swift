import CryptoKit
import Foundation

public struct SyncStats: Sendable, Equatable {
    public let added: Int
    public let updated: Int
    public let removed: Int
    public let unchanged: Int
    /// Notes that kept changing mid-read; their index rows are left for the next sync.
    public let skipped: Int
}

public struct SearchHit: Sendable {
    public let embeddingKey: String
    public let blockID: Int64
    public let body: String
    public let notePath: String
    public let noteTitle: String
    public let noteKind: NoteKind
    public let captureID: UUID?
    public let blockKind: BlockKind
    public let createdAt: Date?
    public let sourceApp: String?
    public let windowTitle: String?
    public let assetPath: String?
    public var title: String { noteTitle }
    public let snippet: String
    public let snippetMatches: [Range<String.Index>]
}

public struct EmbeddableBlock: Sendable {
    public let key: String
    public let body: String
    public let noteTitle: String
    public let kind: BlockKind
    public let assetPath: String?
    public let ocrText: String
}

public struct NoteSuggestion: Sendable, Equatable {
    public let title: String
    public let kind: NoteKind
    public let path: String
    public let modified: Date
}

/// A disposable local cache. Only Markdown and asset files supply persistent content.
public actor SearchIndex {
    private let vault: Vault
    private let calendar: Calendar
    private let database: SQLiteDatabase

    public nonisolated static func probeFullTextSearch() throws {
        try SQLiteDatabase.probeFTS5()
    }

    public init(vault: Vault, databaseURL: URL, calendar: Calendar) throws {
        self.vault = vault
        self.calendar = calendar
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.probeFullTextSearch()
        database = try Self.openCache(at: databaseURL)
    }

    public func sync() throws -> SyncStats {
        let refs = try vault.listNoteFiles() // Note IDs, kinds, and managed metadata; titles are read only for changed files.
        let rows = try database.prepare("SELECT path, mtime, size FROM notes")
        var previous: [String: Fingerprint] = [:]
        while try rows.step() {
            if let path = rows.text(0) { previous[path] = Fingerprint(mtime: rows.double(1), size: rows.int(2)) }
        }
        var added = 0
        var updated = 0
        var unchanged = 0
        var skipped = 0
        for ref in refs {
            let path = ref.id
            guard ref.snapshot != nil || ref.isChanging else { continue }
            let old = previous[path]
            if let metadata = ref.snapshot, old == Self.fingerprint(metadata) {
                previous.removeValue(forKey: path)
                unchanged += 1
            } else {
                // EAGAIN means the note is mid-change. Retry briefly, then keep its old row
                // and move on; the watcher's next sync picks it up once the write settles.
                var read: VaultFileSnapshot?
                var changing = true
                for _ in 0..<3 {
                    do {
                        read = try vault.fileSnapshot(noteID: path)
                        changing = false
                        break
                    } catch let error as POSIXError where error.code == .EAGAIN {
                        continue
                    }
                }
                if changing {
                    previous.removeValue(forKey: path)
                    skipped += 1
                    continue
                }
                guard let snapshot = read, let contents = snapshot.contents else { continue }
                let fingerprint = Self.fingerprint(snapshot)
                try index(contents: contents, path: path, kind: ref.kind,
                          titleFallback: ref.url.deletingPathExtension().lastPathComponent,
                          fingerprint: fingerprint)
                previous.removeValue(forKey: path)
                if old == nil { added += 1 } else { updated += 1 }
            }
        }
        for path in previous.keys {
            try database.transaction {
                try database.execute("DELETE FROM blocks_fts WHERE rowid IN (SELECT b.id FROM blocks b JOIN notes n ON n.id = b.note_id WHERE n.path = ?)", [.text(path)])
                try database.execute("DELETE FROM notes WHERE path = ?", [.text(path)])
            }
        }
        return SyncStats(added: added, updated: updated, removed: previous.count, unchanged: unchanged, skipped: skipped)
    }

    public func reindex(note: URL) throws {
        guard note.pathExtension.lowercased() == "md", let location = try? vault.managedLocation(of: note) else {
            throw IndexError.invalidNote
        }
        let path = location.note.id
        let kind: NoteKind
        if location.scope == .home {
            kind = .note
        } else {
            kind = path == Vault.inboxFileName ? .inbox : (path.hasPrefix("Sessions/") ? .session : .note)
        }
        guard let snapshot = try vault.fileSnapshot(noteID: path), let contents = snapshot.contents else {
            throw IndexError.invalidNote
        }
        try index(contents: contents, path: path, kind: kind,
                  titleFallback: location.url.deletingPathExtension().lastPathComponent,
                  fingerprint: Self.fingerprint(snapshot))
    }

    /// The fingerprint comes from the exact bytes OCR consumed, never a later file version.
    public nonisolated static func imageFingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public func setImageText(assetPath: String, text: String, fingerprint expected: String) throws -> Bool {
        guard let snapshot = try vault.fileSnapshot(relativePath: assetPath), let contents = snapshot.contents else {
            throw IndexError.invalidAsset
        }
        let fingerprint = Self.fingerprint(snapshot)
        guard Self.imageFingerprint(contents) == expected else { return false }
        try database.transaction {
            try database.execute("""
                INSERT INTO image_text(asset_path, mtime, size, fingerprint, text) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(asset_path) DO UPDATE SET mtime=excluded.mtime, size=excluded.size,
                    fingerprint=excluded.fingerprint, text=excluded.text
                """, [.text(assetPath), .double(fingerprint.mtime), .int(fingerprint.size), .text(expected), .text(text)])
            try database.execute("UPDATE blocks_fts SET ocr = ? WHERE rowid IN (SELECT id FROM blocks WHERE kind = 'image' AND asset_path = ?)", [.text(Self.ftsText(text)), .text(assetPath)])
        }
        return true
    }

    /// Returns assets that need OCR. Pass `[]` after a note-only edit to avoid
    /// hashing unchanged files; pass changed watcher paths to validate those
    /// assets even when size and modification time did not change. `nil` checks
    /// every content digest and is used for startup/full recovery scans.
    public func assetsMissingText(recheckingAssetPaths: Set<String>? = nil) throws -> [String] {
        let rows = try database.prepare("""
            SELECT DISTINCT b.asset_path, i.mtime, i.size, i.fingerprint FROM blocks b
            LEFT JOIN image_text i ON i.asset_path = b.asset_path
            WHERE b.kind = 'image' AND b.asset_path IS NOT NULL ORDER BY b.asset_path
            """)
        var missing: [String] = []
        while try rows.step() {
            guard let path = rows.text(0) else { continue }
            if rows.isNull(1) {
                missing.append(path)
                continue
            }
            let shouldRecheckDigest = recheckingAssetPaths.map { $0.contains(path) } ?? true
            let current = try? vault.fileSnapshot(relativePath: path, includingContents: shouldRecheckDigest)
            let currentFingerprint = current.map(Self.fingerprint)
            if currentFingerprint == nil || currentFingerprint != Fingerprint(mtime: rows.double(1), size: rows.int(2)) {
                missing.append(path)
            } else if shouldRecheckDigest {
                let digest = current?.contents.map(Self.imageFingerprint)
                if digest == nil || digest != rows.text(3) { missing.append(path) }
            }
        }
        return missing
    }

    public func search(_ query: String, limit: Int = 40) throws -> [SearchHit] {
        let match = Self.matchQuery(query)
        guard !match.isEmpty, limit > 0 else { return [] }
        let rows = try database.prepare("""
            WITH ranked AS MATERIALIZED (
                SELECT blocks_fts.rowid AS id, bm25(blocks_fts, 5.0, 1.0, 0.8) AS score, b.created_at AS stamp
                FROM blocks_fts JOIN blocks b ON b.id = blocks_fts.rowid
                WHERE blocks_fts MATCH ?
                ORDER BY score, stamp DESC, b.id DESC LIMIT ?
            )
            SELECT \(Self.hitColumns),
                CASE WHEN b.kind = 'image' AND instr(highlight(blocks_fts, 1, char(2), char(3)), char(2)) = 0
                    THEN CASE WHEN instr(highlight(blocks_fts, 2, char(2), char(3)), char(2)) > 0
                        THEN snippet(blocks_fts, 2, char(2), char(3), '…', 12) ELSE 'Image' END
                    ELSE snippet(blocks_fts, 1, char(2), char(3), '…', 12) END
            FROM blocks_fts CROSS JOIN ranked r
            JOIN blocks b ON b.id = blocks_fts.rowid JOIN notes n ON n.id = b.note_id
            WHERE blocks_fts MATCH ? AND blocks_fts.rowid >= (SELECT min(id) FROM ranked)
                AND blocks_fts.rowid <= (SELECT max(id) FROM ranked) AND blocks_fts.rowid = r.id
            ORDER BY r.score, r.stamp DESC, b.id DESC
            """)
        try rows.bind([.text(match), .int(Int64(limit)), .text(match)])
        var hits: [SearchHit] = []
        while try rows.step() {
            let snippet = Self.unmark(rows.text(12) ?? "")
            hits.append(Self.hit(rows, snippet: snippet.text, matches: snippet.matches))
        }
        return hits
    }

    public func recent(limit: Int = 20) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        let rows = try database.prepare("""
            SELECT \(Self.hitColumns) FROM blocks b JOIN notes n ON n.id = b.note_id
            WHERE b.capture_id IS NOT NULL AND b.created_at IS NOT NULL
            ORDER BY b.created_at DESC, b.id DESC LIMIT ?
            """)
        try rows.bind([.int(Int64(limit))])
        var hits: [SearchHit] = []
        while try rows.step() {
            hits.append(Self.hit(rows, snippet: String((rows.text(10) ?? "").prefix(140)), matches: []))
        }
        return hits
    }

    /// Looks up a just-written capture, including its resolved vault-relative asset path.
    public func capture(id: UUID) throws -> SearchHit? {
        let row = try database.prepare("SELECT \(Self.hitColumns) FROM blocks b JOIN notes n ON n.id = b.note_id WHERE b.capture_id = ? LIMIT 1")
        try row.bind([.text(id.uuidString.lowercased())])
        guard try row.step() else { return nil }
        return Self.hit(row, snippet: String((row.text(10) ?? "").prefix(140)), matches: [])
    }

    /// Stable across cache rebuilds; loose ordinals follow the parser's block order.
    public func embeddableBlocks() throws -> [EmbeddableBlock] {
        let rows = try database.prepare("""
            SELECT \(Self.hitColumns), coalesce(i.text, '') FROM blocks b
            JOIN notes n ON n.id = b.note_id LEFT JOIN image_text i ON i.asset_path = b.asset_path
            WHERE length(trim(b.body)) > 0 ORDER BY n.path, b.ord
            """)
        var blocks: [EmbeddableBlock] = []
        while try rows.step() {
            blocks.append(EmbeddableBlock(key: Self.embeddingKey(rows), body: rows.text(10) ?? "",
                                          noteTitle: rows.text(1) ?? "",
                                          kind: BlockKind(rawValue: rows.text(4) ?? "") ?? .loose,
                                          assetPath: rows.text(8), ocrText: rows.text(12) ?? ""))
        }
        return blocks
    }

    /// Unknown/deleted keys are omitted. The caller supplies block keys, without #ocr.
    public func hits(forEmbeddingKeys keys: [String]) throws -> [String: SearchHit] {
        let row = try database.prepare("""
            SELECT \(Self.hitColumns), coalesce(i.text, '') FROM blocks b
            JOIN notes n ON n.id = b.note_id LEFT JOIN image_text i ON i.asset_path = b.asset_path
            WHERE n.path = ? AND (b.capture_id = ? OR (b.capture_id IS NULL AND b.ord = ?))
            LIMIT 1
            """)
        var hits: [String: SearchHit] = [:]
        for key in Set(keys) {
            guard let separator = key.lastIndex(of: "#") else { continue }
            let path = String(key[..<separator])
            let identity = String(key[key.index(after: separator)...])
            let ordinal = identity.hasPrefix("loose-") ? Int64(identity.dropFirst(6)) : nil
            guard ordinal != nil || UUID(uuidString: identity) != nil else { continue }
            try row.bind([.text(path), .text(identity.lowercased()), ordinal.map(SQLiteValue.int) ?? .null])
            if try row.step(), Self.embeddingKey(row) == key {
                let ocr = row.text(12) ?? ""
                let body = row.text(10) ?? ""
                let snippet = row.text(4) == "image" && !ocr.isEmpty ? ocr : body
                hits[key] = Self.hit(row, snippet: String(snippet.prefix(140)), matches: [])
            }
        }
        return hits
    }

    public func titleSuggestions(prefix: String, limit: Int = 8) throws -> [NoteSuggestion] {
        guard limit > 0 else { return [] }
        let key = NoteTitle.matchKey(prefix)
        // The lower bound uses title_key's index; the prefix check treats wildcards literally.
        let filter = key.isEmpty ? "" : "AND title_key >= ? AND substr(title_key, 1, length(?)) = ?"
        let rows = try database.prepare("SELECT title, kind, path, mtime FROM notes WHERE kind != 'inbox' \(filter) ORDER BY mtime DESC, path LIMIT ?")
        var values: [SQLiteValue] = []
        if !key.isEmpty { values = [.text(key), .text(key), .text(key)] }
        values.append(.int(Int64(limit)))
        try rows.bind(values)
        var suggestions: [NoteSuggestion] = []
        while try rows.step() {
            suggestions.append(NoteSuggestion(
                title: rows.text(0) ?? "", kind: Self.noteKind(rows.text(1)), path: rows.text(2) ?? "",
                modified: Date(timeIntervalSince1970: rows.double(3))
            ))
        }
        return suggestions
    }

    public func captureCount(notePath: String) throws -> Int {
        let row = try database.prepare("SELECT count(*) FROM blocks b JOIN notes n ON n.id = b.note_id WHERE n.path = ? AND b.capture_id IS NOT NULL AND b.kind != 'note'")
        try row.bind([.text(notePath)])
        return try row.step() ? Int(row.int(0)) : 0
    }

    private struct Fingerprint: Equatable {
        let mtime: Double
        let size: Int64
    }

    private enum IndexError: Error {
        case invalidNote, invalidAsset, invalidCache
    }

    private static func fingerprint(_ snapshot: VaultFileSnapshot) -> Fingerprint {
        Fingerprint(mtime: snapshot.modifiedAt.timeIntervalSince1970, size: snapshot.size)
    }

    private func index(contents: Data, path: String, kind: NoteKind, titleFallback: String,
                       fingerprint: Fingerprint) throws {
        let parsed = NoteParser.parse(
            contents: String(decoding: contents, as: UTF8.self), notePath: path,
            titleFallback: titleFallback, calendar: calendar, assetRootURL: vault.assetsURL
        )
        try database.transaction {
            try database.execute("""
                INSERT INTO notes(path, title, title_key, kind, mtime, size) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET title=excluded.title, title_key=excluded.title_key,
                    kind=excluded.kind, mtime=excluded.mtime, size=excluded.size
                """, [.text(path), .text(parsed.title), .text(NoteTitle.matchKey(parsed.title)), .text(Self.kindName(kind)), .double(fingerprint.mtime), .int(fingerprint.size)])
            let row = try database.prepare("SELECT id FROM notes WHERE path = ?")
            try row.bind([.text(path)])
            guard try row.step() else { throw IndexError.invalidCache }
            let noteID = row.int(0)
            try database.execute("DELETE FROM blocks_fts WHERE rowid IN (SELECT id FROM blocks WHERE note_id = ?)", [.int(noteID)])
            try database.execute("DELETE FROM blocks WHERE note_id = ?", [.int(noteID)])
            let insert = try database.prepare("""
                INSERT INTO blocks(note_id, ord, capture_id, kind, created_at, source_app, window_title, body, asset_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let fts = try database.prepare("""
                INSERT INTO blocks_fts(rowid, title, body, ocr)
                VALUES (?, ?, ?, coalesce((SELECT replace(replace(text, char(2), ''), char(3), '') FROM image_text WHERE asset_path = ?), ''))
                """)
            let title = Self.ftsText(parsed.title)
            for (ord, block) in parsed.blocks.enumerated() {
                try insert.run([
                    .int(noteID), .int(Int64(ord)), Self.value(block.captureID?.uuidString.lowercased()),
                    .text(block.kind.rawValue), block.createdAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    Self.value(block.sourceApp), Self.value(block.windowTitle), .text(block.body), Self.value(block.assetPath)
                ])
                try fts.run([.int(database.lastInsertedID), .text(title), .text(Self.ftsText(block.body)), Self.value(block.assetPath)])
            }
        }
    }

    private static func value(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }

    private static func kindName(_ kind: NoteKind) -> String {
        switch kind {
        case .inbox: "inbox"
        case .session: "session"
        case .note: "note"
        }
    }

    private static func noteKind(_ name: String?) -> NoteKind {
        switch name {
        case "inbox": .inbox
        case "session": .session
        default: .note
        }
    }

    private static let hitColumns = "n.path, n.title, n.kind, b.capture_id, b.kind, b.created_at, b.source_app, b.window_title, b.asset_path, b.id, b.body, b.ord"

    private static func embeddingKey(_ row: SQLiteStatement) -> String {
        (row.text(0) ?? "") + "#" + (row.text(3) ?? "loose-\(row.int(11))")
    }

    private static func hit(_ row: SQLiteStatement, snippet: String, matches: [Range<String.Index>]) -> SearchHit {
        SearchHit(
            embeddingKey: embeddingKey(row),
            blockID: row.int(9), body: row.text(10) ?? "",
            notePath: row.text(0) ?? "", noteTitle: row.text(1) ?? "", noteKind: noteKind(row.text(2)),
            captureID: row.text(3).flatMap(UUID.init(uuidString:)), blockKind: BlockKind(rawValue: row.text(4) ?? "") ?? .loose,
            createdAt: row.isNull(5) ? nil : Date(timeIntervalSince1970: row.double(5)), sourceApp: row.text(6),
            windowTitle: row.text(7), assetPath: row.text(8), snippet: snippet, snippetMatches: matches
        )
    }

    private static func matchQuery(_ query: String) -> String {
        let syntax = Set("\"*^:(){}+\u{00}".unicodeScalars)
        var tokens: [String] = []
        for part in query.split(whereSeparator: \.isWhitespace) {
            // Strip scalars so a quote with a combining mark cannot escape its quoted token.
            let scalars = part.unicodeScalars.filter { !syntax.contains($0) }.drop(while: { $0 == "-" })
            let token = String(String.UnicodeScalarView(scalars))
            guard !token.isEmpty, !["AND", "OR", "NOT", "NEAR"].contains(token.uppercased()) else { continue }
            // FTS expressions consisting entirely of punctuation are valid, but match nothing.
            tokens.append(token)
        }
        return tokens.enumerated().map { index, token in
            "\"" + token + "\"" + (index == tokens.count - 1 && token.count >= 2 ? "*" : "")
        }.joined(separator: " ")
    }

    private static func ftsText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{02}", with: "").replacingOccurrences(of: "\u{03}", with: "")
    }

    private static func unmark(_ marked: String) -> (text: String, matches: [Range<String.Index>]) {
        var bytes: [UInt8] = []
        var offsets: [Range<Int>] = []
        var start: Int?
        for byte in marked.utf8 {
            if byte == 2 { start = bytes.count }
            else if byte == 3 {
                if let lower = start, lower < bytes.count { offsets.append(lower..<bytes.count) }
                start = nil
            } else { bytes.append(byte) }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let matches = offsets.map {
            text.utf8.index(text.utf8.startIndex, offsetBy: $0.lowerBound)..<text.utf8.index(text.utf8.startIndex, offsetBy: $0.upperBound)
        }
        return (text, matches)
    }

    private static func openCache(at url: URL) throws -> SQLiteDatabase {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw CocoaError(.fileReadUnknown)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let candidate = try SQLiteDatabase(url: url)
                let version = try candidate.prepare("PRAGMA user_version")
                guard try version.step(), version.int(0) == 4 else { throw IndexError.invalidCache }
                let integrity = try candidate.prepare("PRAGMA quick_check")
                guard try integrity.step(), integrity.text(0) == "ok" else { throw IndexError.invalidCache }
                // Catch incomplete schemas even if the version number claims compatibility.
                _ = try candidate.prepare("SELECT n.title_key, b.ord, i.text, i.fingerprint FROM notes n, blocks b, image_text i LIMIT 0")
                _ = try candidate.prepare("SELECT title, body, ocr FROM blocks_fts LIMIT 0")
                return candidate
            } catch {
                // The candidate and its statements have closed before deleting the disposable cache.
            }
        }
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else { throw CocoaError(.fileReadUnknown) }
                try FileManager.default.removeItem(atPath: path)
            }
        }
        let fresh = try SQLiteDatabase(url: url)
        try fresh.exec(schema)
        return fresh
    }

    private static let schema = """
        BEGIN IMMEDIATE;
        CREATE TABLE notes (
            id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL, title_key TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('inbox', 'session', 'note')), mtime REAL NOT NULL, size INTEGER NOT NULL
        );
        CREATE INDEX notes_title_key ON notes(title_key);
        CREATE TABLE blocks (
            id INTEGER PRIMARY KEY, note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            ord INTEGER NOT NULL, capture_id TEXT, kind TEXT NOT NULL CHECK(kind IN ('text', 'image', 'loose', 'note')),
            created_at REAL, source_app TEXT, window_title TEXT, body TEXT NOT NULL, asset_path TEXT
        );
        CREATE INDEX blocks_note ON blocks(note_id);
        CREATE INDEX blocks_asset ON blocks(asset_path) WHERE kind = 'image';
        CREATE INDEX blocks_recent ON blocks(created_at DESC) WHERE capture_id IS NOT NULL;
        CREATE TABLE image_text (asset_path TEXT PRIMARY KEY, mtime REAL NOT NULL, size INTEGER NOT NULL, fingerprint TEXT NOT NULL, text TEXT NOT NULL);
        CREATE VIRTUAL TABLE blocks_fts USING fts5(title, body, ocr, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3');
        PRAGMA user_version = 4;
        COMMIT;
        """
}
