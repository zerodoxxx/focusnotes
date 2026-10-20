using System.Text;
using System.Text.Json;

namespace CaptureApp.Core;

public enum ExternalNoteRegistryError
{
    MalformedRegistry,
    UnsupportedVersion,
    UnreadableRegistry
}

public sealed class ExternalNoteRegistryException(ExternalNoteRegistryError kind, int? version = null, Exception? inner = null) : IOException(kind.ToString(), inner)
{
    public ExternalNoteRegistryError Kind { get; } = kind;
    public int? Version { get; } = version;
}

/// Contains only explicitly registered, profile-relative Markdown paths. Never scans HOME.
public sealed class ExternalNoteRegistry
{
    public sealed record Snapshot(ulong Generation, IReadOnlyList<string> Paths);
    private sealed record Store(int Version, string[] Paths);
    private readonly object gate = new();
    private readonly string directory;
    private readonly string name;
    private Snapshot? cached;
    private bool valid;
    public string Url { get; }

    public ExternalNoteRegistry(string url)
    {
        Url = Path.GetFullPath(url);
        directory = Path.GetDirectoryName(Url)!;
        name = Path.GetFileName(Url);
    }

    public void InvalidateCache()
    {
        lock (gate)
        {
            valid = false;
        }
    }

    public IReadOnlyList<string> Paths() => GetSnapshot().Paths;
    public Snapshot GetSnapshot()
    {
        lock (gate)
        {
            if (valid && cached is not null)
            {
                return cached;
            }

            return WithLock(() => Update(ReadStore().Paths, false));
        }
    }

    private Snapshot Update(string[] paths, bool added)
    {
        var generation = cached is null ? (added ? 1UL : 0UL) : cached.Generation + (cached.Paths.SequenceEqual(paths, StringComparer.Ordinal) ? 0UL : 1UL);
        cached = new(generation, Array.AsReadOnly(paths));
        valid = true;
        return cached;
    }

    public void Register(string path)
    {
        if (!IsSafeRelativeMarkdownPath(path))
        {
            throw new VaultFileException(VaultFileError.InvalidFileName);
        }

        lock (gate)
        {
            WithLock(() =>
            {
                var store = ReadStore();
                var paths = store.Paths.Append(path).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
                var added = paths.Length != store.Paths.Length;
                if (added)
                {
                    var bytes = JsonSerializer.SerializeToUtf8Bytes(new { version = 1, paths }, JsonOptions);
                    NoteFile.AtomicWrite(bytes, directory, name);
                }

                Update(paths, added);
                return true;
            });
        }
    }

    public VaultFileSnapshot? CurrentFingerprint()
    {
        try
        {
            return NoteFile.ReadManagedSnapshot(directory, name, false);
        }
        catch (IOException error)
        {
            throw new ExternalNoteRegistryException(ExternalNoteRegistryError.UnreadableRegistry, inner: error);
        }
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
    private Store ReadStore()
    {
        var snapshot = NoteFile.ReadManagedSnapshot(directory, name, false);
        if (snapshot is null)
        {
            return new(1, []);
        }

        const int limit = 8 * 1024 * 1024;
        if (snapshot.Size > limit)
        {
            throw new ExternalNoteRegistryException(ExternalNoteRegistryError.UnreadableRegistry);
        }

        var bytes = NoteFile.ReadManagedPrefix(limit + 1, directory, name) ?? throw new IOException("Registry changed during read.");
        var final = NoteFile.ReadManagedSnapshot(directory, name, false);
        if (bytes.Length > limit || snapshot != final)
        {
            throw new IOException("Registry changed during read.");
        }

        try
        {
            using var json = JsonDocument.Parse(bytes);
            var obj = json.RootElement;
            if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty("version", out var version) || !version.TryGetInt32(out var number) || !obj.TryGetProperty("paths", out var paths) || paths.ValueKind != JsonValueKind.Array)
            {
                throw new JsonException("Missing registry fields.");
            }

            var values = paths.EnumerateArray().Select(p => p.GetString() ?? throw new JsonException("Null registry path.")).ToArray();
            if (number != 1)
            {
                throw new ExternalNoteRegistryException(ExternalNoteRegistryError.UnsupportedVersion, number);
            }

            return new(1, values.Where(IsSafeRelativeMarkdownPath).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray());
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException)
        {
            throw new ExternalNoteRegistryException(ExternalNoteRegistryError.MalformedRegistry, inner: error);
        }
    }

    private T WithLock<T>(Func<T> action)
    {
        try
        {
            var lockPath = NoteFile.SafePath(directory, "." + name + ".lock", true);
            lock (NoteFile.Gate(lockPath))
            {
                using var stream = NoteFile.OpenExclusive(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite);
                return action();
            }
        }
        catch (ExternalNoteRegistryException)
        {
            throw;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            throw new ExternalNoteRegistryException(ExternalNoteRegistryError.UnreadableRegistry, inner: error);
        }
    }

    public static bool IsSafeRelativeMarkdownPath(string path) => path.Length > 0 && Encoding.UTF8.GetByteCount(path) <= 4096 && !Path.IsPathRooted(path) && Path.GetExtension(path).Equals(".md", StringComparison.OrdinalIgnoreCase) && !path.Contains('\\') && !NoteTitle.ContainsControlCharacters(path) && path.Split('/').All(p => p is not ("" or "." or ".."));
}
