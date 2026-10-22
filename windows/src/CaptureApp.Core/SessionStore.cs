using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Security.Cryptography;

namespace CaptureApp.Core;

public sealed record Session(string Name, string NotePath, DateTimeOffset StartedAt, [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? Resumed = null);
public sealed record SessionCandidate(string Name, string NotePath, DateTimeOffset ModifiedAt);
public sealed record SessionRenamePlan(string OldPath, Session Target, ulong SourceDevice, ulong SourceInode, string OriginalSha256, string RenamedSha256);
public enum SessionStoreError
{
    Ambiguous,
    CandidateNoLongerExists,
    NameAlreadyExists
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

    public Session RenameAndResume(SessionCandidate candidate, string newName, Action<SessionRenamePlan>? beforeRename = null)
    {
        lock (gate)
        {
            vault.Prepare();
            _ = Existing().FirstOrDefault(n => vault.NoteId(n.Url) == candidate.NotePath)
                ?? throw new SessionStoreException(SessionStoreError.CandidateNoLongerExists, path: candidate.NotePath);
            var title = RenameTitle(newName);
            var parts = NoteFile.PathComponents(candidate.NotePath);
            if (parts.Length < 2 || parts[0] != Vault.SessionsDirectoryName)
            {
                throw new NotePathNameException(NotePathNameError.InvalidComponent);
            }
            var components = parts.SkipLast(1).Append(NoteTitle.FileStem(title)).ToArray();
            var name = NotePathName.Validated(NotePathScope.Vault, components, vault.NamingRules);
            var newPath = name.RelativePath + ".md";
            var target = new Session(title, newPath, clock.GetUtcNow(), true);
            NoteFile.RenameSession(vault.Root, candidate.NotePath, newPath, title, (snapshot, rewritten) =>
            {
                beforeRename?.Invoke(new(candidate.NotePath, target, snapshot.Device, snapshot.Inode,
                    Hash(snapshot.Contents!), Hash(rewritten)));
            });
            session = target;
            return Persist(target);
        }
    }

    // A pending intent survives a crash between the exclusive move, heading rewrite and
    // state migration. Only the original inode or the exact prepared replacement may finish it.
    public Session CompleteRename(SessionRenamePlan plan)
    {
        lock (gate)
        {
            vault.Prepare();
            var parts = NoteFile.PathComponents(plan.Target.NotePath);
            var old = NoteFile.PathComponents(plan.OldPath);
            if (parts.Length < 2 || parts[0] != Vault.SessionsDirectoryName ||
                !parts.SkipLast(1).SequenceEqual(old.SkipLast(1)) || RenameTitle(plan.Target.Name) != plan.Target.Name ||
                parts[^1] != NoteTitle.FileStem(plan.Target.Name) + ".md")
            {
                throw new VaultFileException(VaultFileError.InvalidFileName);
            }
            _ = NotePathName.Validated(NotePathScope.Vault, parts.SkipLast(1).Append(NoteTitle.FileStem(plan.Target.Name)), vault.NamingRules);
            if (plan.OldPath != plan.Target.NotePath && vault.FileSnapshot(plan.OldPath, false) is not null)
            {
                throw new VaultFileException(VaultFileError.Changed);
            }
            var snapshot = vault.FileSnapshot(plan.Target.NotePath) ?? throw new FileNotFoundException(plan.Target.NotePath);
            var hash = Hash(snapshot.Contents!);
            if (hash != plan.RenamedSha256)
            {
                if (snapshot.Device != plan.SourceDevice || snapshot.Inode != plan.SourceInode || hash != plan.OriginalSha256)
                {
                    throw new VaultFileException(VaultFileError.Changed);
                }
                NoteFile.RenameSession(vault.Root, plan.Target.NotePath, plan.Target.NotePath, plan.Target.Name,
                    (current, rewritten) =>
                    {
                        if (current.Device != plan.SourceDevice || current.Inode != plan.SourceInode ||
                            Hash(current.Contents!) != plan.OriginalSha256 || Hash(rewritten) != plan.RenamedSha256)
                        {
                            throw new VaultFileException(VaultFileError.Changed);
                        }
                    });
            }
            session = plan.Target;
            return Persist(plan.Target);
        }
    }

    private string RenameTitle(string raw)
    {
        if (raw.IndexOfAny(['/', '\\', '\0']) >= 0)
        {
            throw new NotePathNameException(NotePathNameError.InvalidComponent);
        }
        if (vault.NamingRules.WindowsRules) { vault.NamingRules.ValidateComponent(raw); }
        var title = NoteTitle.CleanTitle(raw);
        if (title is "" or "." or ".." || NoteTitle.FileStem(title).StartsWith("~$", StringComparison.Ordinal))
        {
            throw new NotePathNameException(NotePathNameError.InvalidComponent);
        }
        vault.NamingRules.ValidateComponent(title);
        return title;
    }

    private static string Hash(byte[] contents) => Convert.ToHexString(SHA256.HashData(contents));

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
        return Persist(started);
    }

    private Session Persist(Session started)
    {
        // Swift's persisted ISO-8601 representation has whole seconds and UTC Z.
        var persisted = new SortedDictionary<string, object?>(StringComparer.Ordinal)
        {
            ["name"] = started.Name,
            ["notePath"] = started.NotePath,
            ["resumed"] = started.Resumed,
            ["startedAt"] = started.StartedAt.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture)
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
