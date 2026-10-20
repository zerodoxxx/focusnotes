using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace CaptureApp.Core.Index;

public sealed record SyncStats(int Added, int Updated, int Removed, int Unchanged);

public sealed record SearchHit(
    string EmbeddingKey,
    long BlockID,
    string Body,
    string NotePath,
    string NoteTitle,
    NoteKind NoteKind,
    Guid? CaptureID,
    BlockKind BlockKind,
    DateTimeOffset? CreatedAt,
    string? SourceApp,
    string? WindowTitle,
    string? AssetPath,
    string Snippet,
    IReadOnlyList<Range> SnippetMatches)
{
    public string Title => NoteTitle;
}

public sealed record EmbeddableBlock(string Key, string Body, string NoteTitle, BlockKind Kind, string? AssetPath, string OcrText);
public sealed record NoteSuggestion(string Title, NoteKind Kind, string Path, DateTimeOffset Modified);

public sealed class SearchIndex : IDisposable
{
    private readonly Vault vault;
    private readonly TimeZoneInfo timeZone;
    private readonly SQLiteDatabase database;

    public SearchIndex(Vault vault, string databasePath, TimeZoneInfo timeZone)
    {
        this.vault = vault;
        this.timeZone = timeZone;
        var fullPath = Path.GetFullPath(databasePath);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        SQLiteDatabase.ProbeFTS5();
        database = OpenCache(fullPath);
    }

    public static void ProbeFullTextSearch() => SQLiteDatabase.ProbeFTS5();

    public static string ImageFingerprint(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    public SyncStats Sync()
    {
        var refs = vault.ListNoteFiles();
        using var rows = database.Prepare("SELECT path, mtime, size FROM notes");
        var previous = new Dictionary<string, Fingerprint>(StringComparer.Ordinal);
        while (rows.Step())
        {
            if (rows.Text(0) is { } path)
            {
                previous[path] = new(rows.Double(1), rows.Int(2));
            }
        }

        var added = 0;
        var updated = 0;
        var unchanged = 0;
        foreach (var note in refs)
        {
            if (note.Snapshot is null)
            {
                continue;
            }

            // A note absent from the index is read in full below, so skip the redundant metadata-only open.
            // Windows compares the listing's snapshot like the Swift index (a changed note is fully re-read and
            // re-verified below); per-note re-opens are too slow there. POSIX keeps the readability re-check.
            var old = previous.GetValueOrDefault(note.Id);
            VaultFileSnapshot? currentMetadata = note.Snapshot;
            if (old is not null && !OperatingSystem.IsWindows())
            {
                try
                {
                    currentMetadata = vault.FileSnapshotForNoteId(note.Id, includingContents: false);
                }
                catch (Exception error) when (IsUnreadableFileError(error))
                {
                    currentMetadata = null;
                }

                if (currentMetadata is null)
                {
                    continue;
                }
            }

            if (old is not null && old == FingerprintOf(currentMetadata!))
            {
                previous.Remove(note.Id);
                unchanged++;
                continue;
            }

            VaultFileSnapshot? snapshot;
            var readFailed = false;
            try
            {
                snapshot = vault.FileSnapshotForNoteId(note.Id);
            }
            catch (Exception error) when (IsUnreadableFileError(error))
            {
                snapshot = null;
                readFailed = true;
            }

            if (snapshot?.Contents is not { } contents)
            {
                if (readFailed) { previous.Remove(note.Id); } // A failed read keeps the stale row; a vanished note is deleted.
                continue;
            }

            Index(contents, note.Id, note.Kind, Path.GetFileNameWithoutExtension(note.Url), FingerprintOf(snapshot));
            previous.Remove(note.Id);
            if (old is null)
            {
                added++;
            }
            else
            {
                updated++;
            }
        }

        foreach (var path in previous.Keys)
        {
            database.Transaction(() =>
            {
                database.Execute("DELETE FROM blocks_fts WHERE rowid IN (SELECT b.id FROM blocks b JOIN notes n ON n.id = b.note_id WHERE n.path = ?)", SQLiteValue.Text(path));
                database.Execute("DELETE FROM notes WHERE path = ?", SQLiteValue.Text(path));
            });
        }

        return new(added, updated, previous.Count, unchanged);
    }

    public void Reindex(string noteUrl)
    {
        VaultManagedLocation location;
        try
        {
            if (!Path.GetExtension(Vault.DecodeFilePath(noteUrl)).Equals(".md", StringComparison.OrdinalIgnoreCase))
            {
                throw new SearchIndexException("The note must be a managed Markdown file.");
            }

            location = vault.ManagedLocation(noteUrl);
        }
        catch (SearchIndexException)
        {
            throw;
        }
        catch (Exception error) when (error is ArgumentException or VaultFileException)
        {
            throw new SearchIndexException("The note must be a managed Markdown file.", error);
        }

        var path = location.Note.Id;
        var kind = location.Scope == NotePathScope.Home
            ? NoteKind.Note
            : path == Vault.InboxFileName ? NoteKind.Inbox
            : path.StartsWith(Vault.SessionsDirectoryName + "/", StringComparison.Ordinal) ? NoteKind.Session : NoteKind.Note;
        var snapshot = vault.FileSnapshotForNoteId(path);
        if (snapshot?.Contents is not { } contents)
        {
            throw new SearchIndexException("The note could not be read.");
        }

        Index(contents, path, kind, Path.GetFileNameWithoutExtension(location.Url), FingerprintOf(snapshot));
    }

    public bool SetImageText(string assetPath, string text, string expectedFingerprint)
    {
        VaultFileSnapshot? snapshot;
        try
        {
            snapshot = vault.FileSnapshot(assetPath);
        }
        catch (Exception error) when (IsUnreadableFileError(error))
        {
            throw new SearchIndexException("The image asset is not accessible.", error);
        }

        if (snapshot?.Contents is not { } contents)
        {
            throw new SearchIndexException("The image asset is not accessible.");
        }

        var fingerprint = FingerprintOf(snapshot);
        if (!string.Equals(ImageFingerprint(contents), expectedFingerprint, StringComparison.Ordinal))
        {
            return false;
        }

        database.Transaction(() =>
        {
            database.Execute("""
                INSERT INTO image_text(asset_path, mtime, size, fingerprint, text) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(asset_path) DO UPDATE SET mtime=excluded.mtime, size=excluded.size,
                    fingerprint=excluded.fingerprint, text=excluded.text
                """, SQLiteValue.Text(assetPath), SQLiteValue.Double(fingerprint.Mtime), SQLiteValue.Int(fingerprint.Size), SQLiteValue.Text(expectedFingerprint), SQLiteValue.Text(text));
            database.Execute("UPDATE blocks_fts SET ocr = ? WHERE rowid IN (SELECT id FROM blocks WHERE kind = 'image' AND asset_path = ?)", SQLiteValue.Text(FtsText(text)), SQLiteValue.Text(assetPath));
        });
        return true;
    }

    public IReadOnlyList<string> AssetsMissingText(IReadOnlySet<string>? recheckingAssetPaths = null)
    {
        using var rows = database.Prepare("""
            SELECT DISTINCT b.asset_path, i.mtime, i.size, i.fingerprint FROM blocks b
            LEFT JOIN image_text i ON i.asset_path = b.asset_path
            WHERE b.kind = 'image' AND b.asset_path IS NOT NULL ORDER BY b.asset_path
            """);
        var missing = new List<string>();
        while (rows.Step())
        {
            if (rows.Text(0) is not { } path)
            {
                continue;
            }

            if (rows.IsNull(1))
            {
                missing.Add(path);
                continue;
            }

            var shouldRecheckDigest = recheckingAssetPaths?.Contains(path) ?? true;
            VaultFileSnapshot? current;
            try
            {
                current = vault.FileSnapshot(path, includingContents: shouldRecheckDigest);
            }
            catch (Exception error) when (IsUnreadableFileError(error))
            {
                current = null;
            }

            var currentFingerprint = current is null ? null : FingerprintOf(current);
            if (current is null || currentFingerprint != new Fingerprint(rows.Double(1), rows.Int(2)))
            {
                missing.Add(path);
            }
            else if (shouldRecheckDigest)
            {
                var digest = current.Contents is { } bytes ? ImageFingerprint(bytes) : null;
                if (digest is null || !string.Equals(digest, rows.Text(3), StringComparison.Ordinal))
                {
                    missing.Add(path);
                }
            }
        }

        return missing;
    }

    public IReadOnlyList<SearchHit> Search(string query, int limit = 40)
    {
        var match = MatchQuery(query);
        if (match.Length == 0 || limit <= 0)
        {
            return [];
        }

        using var rows = database.Prepare($"""
            WITH ranked AS MATERIALIZED (
                SELECT blocks_fts.rowid AS id, bm25(blocks_fts, 5.0, 1.0, 0.8) AS score, b.created_at AS stamp
                FROM blocks_fts JOIN blocks b ON b.id = blocks_fts.rowid
                WHERE blocks_fts MATCH ?
                ORDER BY score, stamp DESC, b.id DESC LIMIT ?
            )
            SELECT {HitColumns},
                CASE WHEN b.kind = 'image' AND instr(highlight(blocks_fts, 1, char(2), char(3)), char(2)) = 0
                    THEN CASE WHEN instr(highlight(blocks_fts, 2, char(2), char(3)), char(2)) > 0
                        THEN snippet(blocks_fts, 2, char(2), char(3), '…', 12) ELSE 'Image' END
                    ELSE snippet(blocks_fts, 1, char(2), char(3), '…', 12) END
            FROM blocks_fts CROSS JOIN ranked r
            JOIN blocks b ON b.id = blocks_fts.rowid JOIN notes n ON n.id = b.note_id
            WHERE blocks_fts MATCH ? AND blocks_fts.rowid >= (SELECT min(id) FROM ranked)
                AND blocks_fts.rowid <= (SELECT max(id) FROM ranked) AND blocks_fts.rowid = r.id
            ORDER BY r.score, r.stamp DESC, b.id DESC
            """);
        rows.Bind([SQLiteValue.Text(match), SQLiteValue.Int(limit), SQLiteValue.Text(match)]);
        var hits = new List<SearchHit>();
        while (rows.Step())
        {
            var unmarked = Unmark(rows.Text(12) ?? "");
            hits.Add(Hit(rows, unmarked.Text, unmarked.Matches));
        }

        return hits;
    }

    public IReadOnlyList<SearchHit> Recent(int limit = 20)
    {
        if (limit <= 0)
        {
            return [];
        }

        using var rows = database.Prepare($"""
            SELECT {HitColumns} FROM blocks b JOIN notes n ON n.id = b.note_id
            WHERE b.capture_id IS NOT NULL AND b.created_at IS NOT NULL
            ORDER BY b.created_at DESC, b.id DESC LIMIT ?
            """);
        rows.Bind([SQLiteValue.Int(limit)]);
        var hits = new List<SearchHit>();
        while (rows.Step())
        {
            hits.Add(Hit(rows, TruncateGraphemes(rows.Text(10) ?? "", 140), []));
        }

        return hits;
    }

    public SearchHit? Capture(Guid id)
    {
        using var row = database.Prepare($"SELECT {HitColumns} FROM blocks b JOIN notes n ON n.id = b.note_id WHERE b.capture_id = ? LIMIT 1");
        row.Bind([SQLiteValue.Text(id.ToString("D").ToLowerInvariant())]);
        return row.Step() ? Hit(row, TruncateGraphemes(row.Text(10) ?? "", 140), []) : null;
    }

    public IReadOnlyList<EmbeddableBlock> EmbeddableBlocks()
    {
        using var rows = database.Prepare($"""
            SELECT {HitColumns}, coalesce(i.text, '') FROM blocks b
            JOIN notes n ON n.id = b.note_id LEFT JOIN image_text i ON i.asset_path = b.asset_path
            WHERE length(trim(b.body)) > 0 ORDER BY n.path, b.ord
            """);
        var blocks = new List<EmbeddableBlock>();
        while (rows.Step())
        {
            blocks.Add(new(EmbeddingKey(rows), rows.Text(10) ?? "", rows.Text(1) ?? "", BlockKindOf(rows.Text(4)), rows.Text(8), rows.Text(12) ?? ""));
        }

        return blocks;
    }

    public IReadOnlyDictionary<string, SearchHit> Hits(IEnumerable<string> keys)
    {
        using var row = database.Prepare($"""
            SELECT {HitColumns}, coalesce(i.text, '') FROM blocks b
            JOIN notes n ON n.id = b.note_id LEFT JOIN image_text i ON i.asset_path = b.asset_path
            WHERE n.path = ? AND (b.capture_id = ? OR (b.capture_id IS NULL AND b.ord = ?))
            LIMIT 1
            """);
        var hits = new Dictionary<string, SearchHit>(StringComparer.Ordinal);
        foreach (var key in keys.Distinct(StringComparer.Ordinal))
        {
            var separator = key.LastIndexOf('#');
            if (separator < 0)
            {
                continue;
            }

            var path = key[..separator];
            var identity = key[(separator + 1)..];
            long? ordinal = identity.StartsWith("loose-", StringComparison.Ordinal) && long.TryParse(identity.AsSpan(6), NumberStyles.None, CultureInfo.InvariantCulture, out var parsedOrdinal) ? parsedOrdinal : null;
            if (ordinal is null && !Guid.TryParse(identity, out _))
            {
                continue;
            }

            row.Bind([SQLiteValue.Text(path), SQLiteValue.Text(Guid.TryParse(identity, out var id) ? id.ToString("D").ToLowerInvariant() : identity), ordinal is { } value ? SQLiteValue.Int(value) : SQLiteValue.Null]);
            if (row.Step() && string.Equals(EmbeddingKey(row), key, StringComparison.Ordinal))
            {
                var ocr = row.Text(12) ?? "";
                var body = row.Text(10) ?? "";
                var snippet = row.Text(4) == "image" && ocr.Length > 0 ? ocr : body;
                hits[key] = Hit(row, TruncateGraphemes(snippet, 140), []);
            }
        }

        return hits;
    }

    public IReadOnlyList<NoteSuggestion> TitleSuggestions(string prefix, int limit = 8)
    {
        if (limit <= 0)
        {
            return [];
        }

        var key = NoteTitle.MatchKey(prefix);
        var filter = key.Length == 0 ? "" : "AND title_key >= ? AND substr(title_key, 1, length(?)) = ?";
        using var rows = database.Prepare($"SELECT title, kind, path, mtime FROM notes WHERE kind != 'inbox' {filter} ORDER BY mtime DESC, path LIMIT ?");
        var values = new List<SQLiteValue>();
        if (key.Length > 0)
        {
            values.Add(SQLiteValue.Text(key));
            values.Add(SQLiteValue.Text(key));
            values.Add(SQLiteValue.Text(key));
        }

        values.Add(SQLiteValue.Int(limit));
        rows.Bind(values);
        var suggestions = new List<NoteSuggestion>();
        while (rows.Step())
        {
            suggestions.Add(new(rows.Text(0) ?? "", NoteKindOf(rows.Text(1)), rows.Text(2) ?? "", FromUnixSeconds(rows.Double(3))));
        }

        return suggestions;
    }

    public int CaptureCount(string notePath)
    {
        using var row = database.Prepare("SELECT count(*) FROM blocks b JOIN notes n ON n.id = b.note_id WHERE n.path = ? AND b.capture_id IS NOT NULL AND b.kind != 'note'");
        row.Bind([SQLiteValue.Text(notePath)]);
        return row.Step() ? checked((int)row.Int(0)) : 0;
    }

    // Like Swift's String(decoding:as:): invalid bytes become U+FFFD instead of failing the sync.
    private static readonly System.Text.Encoding LenientUtf8 = new System.Text.UTF8Encoding(false, false);

    private void Index(byte[] contents, string path, NoteKind kind, string titleFallback, Fingerprint fingerprint)
    {
        var parsed = NoteParser.Parse(LenientUtf8.GetString(contents), path, titleFallback, timeZone, vault.AssetsUrl);
        database.Transaction(() =>
        {
            database.Execute("""
                INSERT INTO notes(path, title, title_key, kind, mtime, size) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET title=excluded.title, title_key=excluded.title_key,
                    kind=excluded.kind, mtime=excluded.mtime, size=excluded.size
                """, SQLiteValue.Text(path), SQLiteValue.Text(parsed.Title), SQLiteValue.Text(NoteTitle.MatchKey(parsed.Title)), SQLiteValue.Text(KindName(kind)), SQLiteValue.Double(fingerprint.Mtime), SQLiteValue.Int(fingerprint.Size));
            using var row = database.Prepare("SELECT id FROM notes WHERE path = ?");
            row.Bind([SQLiteValue.Text(path)]);
            if (!row.Step())
            {
                throw new SearchIndexException("The note index row disappeared during indexing.");
            }

            var noteId = row.Int(0);
            database.Execute("DELETE FROM blocks_fts WHERE rowid IN (SELECT id FROM blocks WHERE note_id = ?)", SQLiteValue.Int(noteId));
            database.Execute("DELETE FROM blocks WHERE note_id = ?", SQLiteValue.Int(noteId));
            using var insert = database.Prepare("""
                INSERT INTO blocks(note_id, ord, capture_id, kind, created_at, source_app, window_title, body, asset_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """);
            using var fts = database.Prepare("""
                INSERT INTO blocks_fts(rowid, title, body, ocr)
                VALUES (last_insert_rowid(), ?, ?, coalesce((SELECT replace(replace(text, char(2), ''), char(3), '') FROM image_text WHERE asset_path = ?), ''))
                """);
            var title = FtsText(parsed.Title);
            for (var ordinal = 0; ordinal < parsed.Blocks.Count; ordinal++)
            {
                var block = parsed.Blocks[ordinal];
                insert.Run(
                    SQLiteValue.Int(noteId), SQLiteValue.Int(ordinal), block.CaptureId is { } captureId ? SQLiteValue.Text(captureId.ToString("D").ToLowerInvariant()) : SQLiteValue.Null,
                    SQLiteValue.Text(BlockKindName(block.Kind)), block.CreatedAt is { } date ? SQLiteValue.Double(ToUnixSeconds(date)) : SQLiteValue.Null,
                    SQLiteValue.Text(block.SourceApp), SQLiteValue.Text(block.WindowTitle), SQLiteValue.Text(block.Body), SQLiteValue.Text(block.AssetPath));
                fts.Run(SQLiteValue.Text(title), SQLiteValue.Text(FtsText(block.Body)), SQLiteValue.Text(block.AssetPath));
            }
        });
    }

    private static SearchHit Hit(SQLiteStatement row, string snippet, IReadOnlyList<Range> matches) => new(
        EmbeddingKey(row), row.Int(9), row.Text(10) ?? "", row.Text(0) ?? "", row.Text(1) ?? "", NoteKindOf(row.Text(2)),
        row.Text(3) is { } id && Guid.TryParse(id, out var captureId) ? captureId : null,
        BlockKindOf(row.Text(4)), row.IsNull(5) ? null : FromUnixSeconds(row.Double(5)), row.Text(6), row.Text(7), row.Text(8), snippet, matches);

    private static string EmbeddingKey(SQLiteStatement row) => (row.Text(0) ?? "") + "#" + (row.Text(3) ?? "loose-" + row.Int(11).ToString(CultureInfo.InvariantCulture));

    private static NoteKind NoteKindOf(string? name) => name switch
    {
        "inbox" => NoteKind.Inbox,
        "session" => NoteKind.Session,
        _ => NoteKind.Note
    };

    private static BlockKind BlockKindOf(string? name) => name switch
    {
        "text" => BlockKind.Text,
        "image" => BlockKind.Image,
        "note" => BlockKind.Note,
        _ => BlockKind.Loose
    };

    private static string KindName(NoteKind kind) => kind switch
    {
        NoteKind.Inbox => "inbox",
        NoteKind.Session => "session",
        _ => "note"
    };

    private static string BlockKindName(BlockKind kind) => kind switch
    {
        BlockKind.Text => "text",
        BlockKind.Image => "image",
        BlockKind.Note => "note",
        _ => "loose"
    };

    private static string MatchQuery(string query)
    {
        var syntax = new HashSet<int>([0, '"', '*', '^', ':', '(', ')', '{', '}', '+']);
        var tokens = new List<string>();
        foreach (var part in Regex.Split(query, @"\s+").Where(x => x.Length > 0))
        {
            var builder = new StringBuilder(part.Length);
            foreach (var rune in part.EnumerateRunes())
            {
                if (!syntax.Contains(rune.Value))
                {
                    builder.Append(rune.ToString());
                }
            }

            var token = builder.ToString();
            token = token.TrimStart('-');
            if (token.Length == 0 || token.Equals("AND", StringComparison.OrdinalIgnoreCase) || token.Equals("OR", StringComparison.OrdinalIgnoreCase) || token.Equals("NOT", StringComparison.OrdinalIgnoreCase) || token.Equals("NEAR", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            tokens.Add(token);
        }

        return string.Join(' ', tokens.Select((token, index) => "\"" + token + "\"" + (index == tokens.Count - 1 && GraphemeCount(token) >= 2 ? "*" : "")));
    }

    private static string FtsText(string text) => text.Replace("\u0002", "", StringComparison.Ordinal).Replace("\u0003", "", StringComparison.Ordinal);

    private static (string Text, IReadOnlyList<Range> Matches) Unmark(string marked)
    {
        var text = new StringBuilder(marked.Length);
        var matches = new List<Range>();
        var start = -1;
        foreach (var character in marked)
        {
            if (character == '\u0002')
            {
                start = text.Length;
            }
            else if (character == '\u0003')
            {
                if (start >= 0 && start < text.Length)
                {
                    matches.Add(new Range(start, text.Length));
                }

                start = -1;
            }
            else
            {
                text.Append(character);
            }
        }

        return (text.ToString(), matches);
    }

    private static string TruncateGraphemes(string text, int count)
    {
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        var end = 0;
        var consumed = 0;
        while (consumed < count && enumerator.MoveNext())
        {
            end = enumerator.ElementIndex + enumerator.GetTextElement().Length;
            consumed++;
        }

        return consumed < count ? text : text[..end];
    }

    private static int GraphemeCount(string text)
    {
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        var count = 0;
        while (enumerator.MoveNext())
        {
            count++;
        }

        return count;
    }

    private static Fingerprint FingerprintOf(VaultFileSnapshot snapshot) => new(snapshot.ModifiedSeconds + snapshot.ModifiedNanoseconds / 1_000_000_000.0, snapshot.Size);
    private static double ToUnixSeconds(DateTimeOffset date) => (date - DateTimeOffset.UnixEpoch).TotalSeconds;
    private static DateTimeOffset FromUnixSeconds(double seconds) => DateTimeOffset.UnixEpoch.AddTicks(checked((long)Math.Round(seconds * TimeSpan.TicksPerSecond)));

    private static bool IsUnreadableFileError(Exception error) => error is IOException or UnauthorizedAccessException or VaultFileException or ArgumentException;

    private static SQLiteDatabase OpenCache(string path)
    {
        if (Directory.Exists(path))
        {
            throw new IOException("The search index cache path is a directory.");
        }

        if (File.Exists(path))
        {
            SQLiteDatabase? candidate = null;
            try
            {
                candidate = new SQLiteDatabase(path);
                using (var version = candidate.Prepare("PRAGMA user_version"))
                {
                    if (!version.Step() || version.Int(0) != 4)
                    {
                        throw new SearchIndexException("The search index cache schema is not supported.");
                    }
                }

                using (var integrity = candidate.Prepare("PRAGMA quick_check"))
                {
                    if (!integrity.Step() || integrity.Text(0) != "ok")
                    {
                        throw new SearchIndexException("The search index cache is corrupt.");
                    }
                }

                using (var schema = candidate.Prepare("SELECT n.title_key, b.ord, i.text, i.fingerprint FROM notes n, blocks b, image_text i LIMIT 0"))
                {
                    _ = schema.Step();
                }

                using (var fts = candidate.Prepare("SELECT title, body, ocr FROM blocks_fts LIMIT 0"))
                {
                    _ = fts.Step();
                }

                return candidate;
            }
            catch
            {
                candidate?.Dispose();
            }
        }

        foreach (var suffix in new[] { "", "-wal", "-shm" })
        {
            var cachePath = path + suffix;
            if (File.Exists(cachePath))
            {
                File.Delete(cachePath);
            }
            else if (Directory.Exists(cachePath))
            {
                throw new IOException("A search index cache sidecar path is a directory.");
            }
        }

        var fresh = new SQLiteDatabase(path);
        try
        {
            fresh.Exec(Schema);
            return fresh;
        }
        catch
        {
            fresh.Dispose();
            throw;
        }
    }

    private const string HitColumns = "n.path, n.title, n.kind, b.capture_id, b.kind, b.created_at, b.source_app, b.window_title, b.asset_path, b.id, b.body, b.ord";

    private const string Schema = """
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
        """;

    public void Dispose() => database.Dispose();

    private sealed record Fingerprint(double Mtime, long Size);
}

public sealed class SearchIndexException(string message, Exception? innerException = null) : Exception(message, innerException);
