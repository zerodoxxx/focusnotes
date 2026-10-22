using System.Collections.Frozen;
using System.Text.Encodings.Web;
using System.Text.Json;

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
        lock (gate) { return Read().Contains(path); }
    }

    public IReadOnlySet<string> Paths()
    {
        lock (gate) { return Read().ToFrozenSet(StringComparer.Ordinal); }
    }

    public bool Toggle(string path)
    {
        lock (gate)
        {
            var current = Read();
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
            var current = Read();
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
            var current = ReadForRename();
            if (!current.Remove(oldPath)) { return; }
            current.Add(newPath);
            Write(current);
        }
    }

    private HashSet<string> ReadForRename()
    {
        try
        {
            var paths = JsonSerializer.Deserialize<string[]>(File.ReadAllBytes(Url), JsonOptions);
            return paths is null ? new(StringComparer.Ordinal) : new(paths, StringComparer.Ordinal);
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException or JsonException or NotSupportedException)
        {
            // A missing or malformed store follows the normal empty-store policy. Other I/O
            // errors must retain the rename intent so an unreadable pin can migrate on retry.
            return new(StringComparer.Ordinal);
        }
    }

    private HashSet<string> Read()
    {
        try
        {
            var paths = JsonSerializer.Deserialize<string[]>(File.ReadAllBytes(Url), JsonOptions);
            return paths is null ? new(StringComparer.Ordinal) : new(paths, StringComparer.Ordinal);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
        {
            return new(StringComparer.Ordinal);
        }
    }

    private void Write(IEnumerable<string> paths)
    {
        var sorted = paths.Order(StringComparer.Ordinal).ToArray();
        AtomicJsonFile.Write(Url, JsonSerializer.SerializeToUtf8Bytes(sorted, JsonOptions));
    }
}
