using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CaptureApp.Core;

/// A JSON object file whose top-level sections belong to different components (settings.json).
/// Every change is a read-modify-write of one section under a process-wide lock per path, written
/// through a GUID temp file, so a writer can never drop another section. A corrupt file is moved to
/// a sibling corrupt directory (like the capture journal) and the file starts empty.
public static class SectionedJsonFile
{
    private static readonly ConcurrentDictionary<string, object> Gates = new(
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);

    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    /// A deep copy of one section, or null when the file or section is absent.
    public static JsonNode? ReadSection(string path, string section)
    {
        var full = Path.GetFullPath(path);
        lock (GateFor(full)) { return ReadRoot(full, strict: false)[section]?.DeepClone(); }
    }

    public static T? ReadSection<T>(string path, string section, JsonSerializerOptions? options = null)
    {
        var node = ReadSection(path, section);
        return node is null ? default : node.Deserialize<T>(options);
    }

    /// Replaces one section with the result of <paramref name="change"/> (null removes it).
    public static void Update(string path, string section, Func<JsonNode?, JsonNode?> change)
    {
        var full = Path.GetFullPath(path);
        lock (GateFor(full))
        {
            var root = ReadRoot(full, strict: true); // Throws when unreadable: never overwrite what was not read.
            var next = change(root[section]?.DeepClone());
            root.Remove(section);
            if (next is not null) { root[section] = next; }
            Write(full, root);
        }
    }

    public static void WriteSection(string path, string section, JsonNode? value) =>
        Update(path, section, _ => value?.DeepClone());

    public static void WriteSection<T>(string path, string section, T value, JsonSerializerOptions? options = null) =>
        WriteSection(path, section, JsonSerializer.SerializeToNode(value, options));

    /// True when the file exists (a corrupt file is quarantined first, so it then reports false).
    public static bool Exists(string path)
    {
        var full = Path.GetFullPath(path);
        lock (GateFor(full))
        {
            _ = ReadRoot(full, strict: false);
            return File.Exists(full);
        }
    }

    private static object GateFor(string fullPath) => Gates.GetOrAdd(fullPath, _ => new object());

    /// An empty root only when the file is absent or was quarantined as corrupt. A file that stays
    /// unreadable after a few retries yields an empty root for readers and throws for writers.
    private static JsonObject ReadRoot(string fullPath, bool strict)
    {
        string text;
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                text = File.ReadAllText(fullPath, Encoding.UTF8);
                break;
            }
            catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
            {
                return [];
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                if (attempt < 4) { Thread.Sleep(20); continue; }
                if (strict) { throw; }
                return [];
            }
        }

        try
        {
            if (JsonNode.Parse(text) is JsonObject root) { return root; }
        }
        catch (JsonException)
        {
        }

        Quarantine(fullPath);
        return [];
    }

    private static void Quarantine(string fullPath)
    {
        try
        {
            var directory = Path.Combine(Path.GetDirectoryName(fullPath)!, "corrupt");
            Directory.CreateDirectory(directory);
            var target = Path.Combine(directory,
                Path.GetFileNameWithoutExtension(fullPath) + "-" + Guid.NewGuid().ToString("N") + Path.GetExtension(fullPath));
            File.Move(fullPath, target);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // The next atomic write replaces the unreadable file.
        }
    }

    private static void Write(string fullPath, JsonObject root)
    {
        var directory = Path.GetDirectoryName(fullPath)!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, "." + Path.GetFileName(fullPath) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                       4096, FileOptions.WriteThrough))
            {
                stream.Write(new UTF8Encoding(false).GetBytes(root.ToJsonString(WriteOptions)));
                stream.Flush(true);
            }

            File.Move(temporary, fullPath, true);
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}
