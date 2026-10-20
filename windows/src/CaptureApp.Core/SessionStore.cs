using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace CaptureApp.Core;

public sealed record Session(string Name, string NotePath, DateTimeOffset StartedAt, [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Resumed = null);
public sealed record SessionCandidate(string Name, string NotePath, DateTimeOffset ModifiedAt);
public enum SessionStoreError
{
    Ambiguous,
    CandidateNoLongerExists
}

public sealed class SessionStoreException(SessionStoreError kind, IReadOnlyList<SessionCandidate>? candidates = null, string? path = null) : IOException(kind.ToString())
{
    public SessionStoreError Kind { get; } = kind;
    public IReadOnlyList<SessionCandidate> Candidates { get; } = candidates ?? [];
    public string? Path { get; } = path;
}

public sealed class SessionStore
{
    private readonly object gate = new();
    private readonly string stateDirectory;
    private readonly Vault vault;
    private readonly TimeProvider clock;
    private readonly Action<string>? beforeNoteWrite;
    private Session? session;
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };
    public string StateFileUrl => System.IO.Path.Combine(stateDirectory, "session.json");

    public SessionStore(string stateDirectory, Vault vault, TimeZoneInfo timeZone, TimeProvider? timeProvider = null, Action<string>? beforeNoteWrite = null)
    {
        _ = timeZone;
        this.stateDirectory = System.IO.Path.GetFullPath(stateDirectory);
        this.vault = vault;
        clock = timeProvider ?? TimeProvider.System;
        this.beforeNoteWrite = beforeNoteWrite;
        try
        {
            using var json = JsonDocument.Parse(File.ReadAllBytes(StateFileUrl));
            var value = json.RootElement;
            if (value.GetProperty("name").ValueKind == JsonValueKind.String && value.GetProperty("notePath").ValueKind == JsonValueKind.String && value.GetProperty("startedAt").TryGetDateTimeOffset(out var date))
            {
                bool? resumedValue = null;
                if (value.TryGetProperty("resumed", out var resumed) && resumed.ValueKind != JsonValueKind.Null)
                {
                    resumedValue = resumed.GetBoolean();
                }
                session = new(value.GetProperty("name").GetString()!, value.GetProperty("notePath").GetString()!, date, resumedValue);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
        }
    }

    public Session? Current()
    {
        lock (gate)
        {
            return session;
        }
    }

    public Session Start(string name)
    {
        lock (gate)
        {
            vault.Prepare();
            var raw = vault.NamingRules.WindowsRules ? name.Replace('\\', '/') : name;
            var cleaned = NoteTitle.CleanTitle(raw);
            if (cleaned.Contains('/'))
            {
                NotePathName? parsed = null;
                NotePathNameError? error = null;
                try
                {
                    parsed = NoteTitle.PathName(raw, vault.NamingRules);
                }
                catch (NotePathNameException failure)
                {
                    error = failure.Kind;
                }

                if (NoteTitle.CanFallBackToFlatName(raw, error))
                {
                    return StartFlat(cleaned);
                }

                if (parsed is null)
                {
                    throw new NotePathNameException(error ?? NotePathNameError.InvalidComponent);
                }

                if (parsed.Scope != NotePathScope.Vault)
                {
                    throw new NotePathNameException(NotePathNameError.InvalidComponent);
                }

                var nested = NotePathName.Validated(NotePathScope.Vault, new[] { Vault.SessionsDirectoryName }.Concat(parsed.Components), vault.NamingRules);
                var location = vault.ResolveNoteName(nested);
                return StartAt(parsed.LeafName, location.RelativePath, Existing().FirstOrDefault(n => vault.NoteId(n.Url) == location.RelativePath));
            }

            if (vault.NamingRules.WindowsRules && name.Length > 0)
            {
                vault.NamingRules.ValidateComponent(name);
            }

            return StartFlat(cleaned);
        }
    }

    private IReadOnlyList<NoteRef> Existing() => vault.ListNotes().Where(n => n.Kind == NoteKind.Session).ToArray();
    private Session StartFlat(string rawTitle)
    {
        var title = rawTitle.Length == 0 ? "Session" : rawTitle;
        vault.NamingRules.ValidateComponent(title);
        var stem = NoteTitle.FileStem(title);
        var matches = Existing().Where(n =>
        {
            var existing = System.IO.Path.GetFileNameWithoutExtension(n.Url);
            return existing.Equals(stem, StringComparison.OrdinalIgnoreCase) || Regex.IsMatch(existing, @"^[0-9]{4}-[0-9]{2}-[0-9]{2} ") && existing[11..].Equals(stem, StringComparison.OrdinalIgnoreCase);
        }).ToArray();
        if (matches.Length > 1)
        {
            var candidates = matches.Select(n =>
            {
                var path = vault.NoteId(n.Url);
                return new SessionCandidate(n.Title, path, vault.FileSnapshot(path, false)?.ModifiedAt ?? DateTimeOffset.MinValue);
            }).OrderByDescending(n => n.ModifiedAt).ThenBy(n => n.NotePath, StringComparer.Ordinal).ToArray();
            throw new SessionStoreException(SessionStoreError.Ambiguous, candidates);
        }

        var existing = matches.FirstOrDefault();
        return StartAt(existing?.Title ?? title, existing is null ? Vault.SessionsDirectoryName + "/" + stem + ".md" : vault.NoteId(existing.Url), existing);
    }

    public Session Resume(SessionCandidate candidate)
    {
        lock (gate)
        {
            vault.Prepare();
            var existing = Existing().FirstOrDefault(n => vault.NoteId(n.Url) == candidate.NotePath) ?? throw new SessionStoreException(SessionStoreError.CandidateNoLongerExists, path: candidate.NotePath);
            return StartAt(existing.Title, candidate.NotePath, existing);
        }
    }

    private Session StartAt(string title, string notePath, NoteRef? existing)
    {
        var now = clock.GetUtcNow();
        var display = title;
        if (existing is not null)
        {
            var data = NoteFile.ReadManagedPrefix(4096, vault.Root, notePath);
            var first = data is null ? "" : System.Text.Encoding.UTF8.GetString(data).Split('\n')[0].TrimStart('\uFEFF');
            var cleaned = first.StartsWith("# ", StringComparison.Ordinal) ? NoteTitle.CleanTitle(first[2..]) : "";
            display = cleaned.Length > 0 ? cleaned : existing.Title;
        }

        var parent = string.Join('/', notePath.Split('/').SkipLast(1));
        if (parent != Vault.SessionsDirectoryName)
        {
            NoteFile.PrepareManagedDirectory(vault.Root, parent);
        }

        beforeNoteWrite?.Invoke(notePath);
        NoteFile.Create(NoteFile.Utf8.GetBytes(CaptureFormat.NoteHeader(title)), vault.Root, notePath);
        var started = new Session(display, notePath, now, existing is not null);
        // Swift's persisted ISO-8601 representation has whole seconds and UTC Z.
        var persisted = new SortedDictionary<string, object?>(StringComparer.Ordinal)
        {
            ["name"] = started.Name,
            ["notePath"] = started.NotePath,
            ["resumed"] = started.Resumed,
            ["startedAt"] = now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture)
        };
        NoteFile.AtomicWrite(JsonSerializer.SerializeToUtf8Bytes(persisted, Options), stateDirectory, "session.json");
        session = started;
        return started;
    }

    public void End()
    {
        lock (gate)
        {
            File.Delete(StateFileUrl);
            session = null;
        }
    }
}
