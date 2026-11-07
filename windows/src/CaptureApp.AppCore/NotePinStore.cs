using System.Collections.Frozen;
using System.Text.Encodings.Web;
using System.Text.Json;
using CaptureApp.Core;

namespace CaptureApp.AppCore;

/// Pinned note identities live in app state, outside the Markdown vault.
public sealed class NotePinStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly object gate = new();
    public string Url { get; }

    public NotePinStore(string stateDirectory) => Url = Path.Combine(Path.GetFullPath(stateDirectory), "pinned-notes.json");

    public bool IsPinned(string path)
    {
        lock (gate) { return Read(tolerateUnreadable: true).Contains(path); }
    }

    public IReadOnlySet<string> Paths()
    {
        lock (gate) { return Read(tolerateUnreadable: true).ToFrozenSet(StringComparer.Ordinal); }
    }

    public bool Toggle(string path)
    {
        lock (gate)
        {
            var current = Read(tolerateUnreadable: false);
            var pinned = !current.Contains(path);
            if (pinned) { current.Add(path); }
            else { current.Remove(path); }
            Write(current);
            return pinned;
        }
    }

    public void Set(string path, bool pinned)
    {
        lock (gate)
        {
            var current = Read(tolerateUnreadable: false);
            if (current.Contains(path) == pinned) { return; }
            if (pinned) { current.Add(path); }
            else { current.Remove(path); }
            Write(current);
        }
    }

    public void Move(string oldPath, string newPath)
    {
        lock (gate)
        {
            if (oldPath == newPath) { return; }
            var current = Read(tolerateUnreadable: false);
            if (!current.Remove(oldPath)) { return; }
            current.Add(newPath);
            Write(current);
        }
    }

    private HashSet<string> Read(bool tolerateUnreadable)
    {
        try
        {
            var paths = JsonSerializer.Deserialize<string[]>(File.ReadAllBytes(Url), JsonOptions);
            return paths is null ? new(StringComparer.Ordinal) : new(paths, StringComparer.Ordinal);
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException or JsonException or NotSupportedException
            || (tolerateUnreadable && error is IOException or UnauthorizedAccessException))
        {
            // A missing or malformed store follows the normal empty-store policy. Other I/O errors
            // propagate from mutations so an unreadable store is never overwritten with an empty set,
            // and a rename can retry.
            return new(StringComparer.Ordinal);
        }
    }

    private void Write(IEnumerable<string> paths)
    {
        var sorted = paths.Order(StringComparer.Ordinal).ToArray();
        DurableFile.Write(Url, JsonSerializer.SerializeToUtf8Bytes(sorted, JsonOptions));
    }
}
