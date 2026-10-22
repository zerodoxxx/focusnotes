using System.Collections.Concurrent;
using System.Text;

namespace CaptureApp.Core;
/// Safe reads and durable, exclusive writes for both vault and registered HOME files.
public static partial class NoteFile
{
    public static readonly Encoding Utf8 = new UTF8Encoding(false, true);
    private static readonly ConcurrentDictionary<string, object> Gates = new(StringComparer.Ordinal);
    internal static object Gate(string path) => Gates.GetOrAdd(path, _ => new());
    public static string[] PathComponents(string path)
    {
        var parts = path.Split('/');
        if (path.Length == 0 || Path.IsPathRooted(path) || path.Contains('\\') || NoteTitle.ContainsControlCharacters(path) || parts.Any(p => p is "" or "." or ".."))
        {
            throw new VaultFileException(VaultFileError.PermissionDenied);
        }

        return parts;
    }

    public static string ResolveSelectedRoot(string path)
    {
        var full = Path.GetFullPath(path);
        var current = Path.GetPathRoot(full)!;
        foreach (var part in full[current.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            var info = new DirectoryInfo(current);
            if (info.LinkTarget is not null)
            {
                current = info.ResolveLinkTarget(true)?.FullName ?? throw new IOException("Broken selected-root link.");
            }
        }

        return Path.TrimEndingDirectorySeparator(current);
    }

    public static string SafePath(string root, string relativePath, bool createParents = false)
    {
        var parts = PathComponents(relativePath);
        var current = root;
        ValidateDirectory(current, createParents);
        for (var i = 0; i < parts.Length; i++)
        {
            current = Path.Combine(current, parts[i]);
            var metadata = FileMetadata.At(current);
            if (metadata?.IsLink == true || metadata is null && (File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                throw new VaultFileException(VaultFileError.PermissionDenied, "Managed paths cannot contain links.");
            }

            if (i < parts.Length - 1)
            {
                ValidateDirectory(current, createParents);
            }
        }

        return current;
    }

    private static void ValidateDirectory(string path, bool create)
    {
        var value = FileMetadata.At(path);
        if (value is null && create)
        {
            var parent = Path.GetDirectoryName(path);
            if (parent is not null && parent != path)
            {
                ValidateDirectory(parent, true);
            }

            if (OperatingSystem.IsWindows())
            {
                Directory.CreateDirectory(path);
            }
            else
            {
                Directory.CreateDirectory(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            }

            value = FileMetadata.At(path);
        }

        if (value is null)
        {
            throw new DirectoryNotFoundException(path);
        }

        // The selected root's ancestors may be system-owned; the managed root/children are owned.
        value.Validate(directory: true);
    }

    public static void PrepareRoot(string root)
    {
        ValidateDirectory(root, true);
        if (SweptRoots.TryAdd(root, true)) { _ = Task.Run(() => SweepStaleTemporaries(root)); }
    }

    private static readonly ConcurrentDictionary<string, bool> SweptRoots = new(StringComparer.Ordinal);
    private static readonly System.Text.RegularExpressions.Regex PendingName = new(@"^\.pending-[0-9a-f]{32}$");

    // Best effort: remove ".pending-<guid>" files that a crashed write left behind. Skips dot-directories,
    // links and cloud placeholders (same attributes WatchSnapshot treats as online-only).
    internal static void SweepStaleTemporaries(string root, TimeSpan? olderThan = null)
    {
        var cutoff = DateTime.UtcNow - (olderThan ?? TimeSpan.FromHours(1));
        const FileAttributes skip = FileAttributes.ReparsePoint | FileAttributes.Offline | (FileAttributes)(0x400000 | 0x40000);
        var options = new EnumerationOptions { AttributesToSkip = skip };
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.TryPop(out var directory))
        {
            try
            {
                foreach (var path in Directory.EnumerateFileSystemEntries(directory, "*", options))
                {
                    var name = Path.GetFileName(path);
                    try
                    {
                        if (Directory.Exists(path)) { if (!name.StartsWith('.')) { pending.Push(path); } }
                        else if (PendingName.IsMatch(name) && File.GetLastWriteTimeUtc(path) < cutoff) { File.Delete(path); }
                    }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    public static void PrepareManagedDirectory(string root, string relativePath)
    {
        var path = SafePath(root, relativePath + "/.directory-check", true);
        _ = path;
    }

    internal static FileStream OpenExclusive(string path, FileMode mode, FileAccess access)
    {
        var until = Environment.TickCount64 + 10000;
        while (true)
        {
            var metadata = FileMetadata.At(path);
            metadata?.Validate();
            try
            {
                var options = new FileStreamOptions
                {
                    Mode = mode,
                    Access = access,
                    Share = FileShare.None,
                    BufferSize = 4096
                };
                if (!OperatingSystem.IsWindows() && mode is FileMode.CreateNew or FileMode.OpenOrCreate)
                {
                    options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
                }

                var stream = new FileStream(path, options);
                try
                {
                    var opened = FileMetadata.Of(stream);
                    opened.Validate();
                    if (metadata is not null && !metadata.SameFile(opened))
                    {
                        throw new VaultFileException(VaultFileError.Changed);
                    }

                    return stream;
                }
                catch
                {
                    stream.Dispose();
                    throw;
                }
            }
            catch (IOException error) when (error is not VaultFileException && Environment.TickCount64 < until && ((error.HResult & 0xFFFF) is 11 or 32 or 33))
            {
                Thread.Sleep(2);
            }
        }
    }

    public static VaultFileSnapshot? ReadManagedSnapshot(string root, string relativePath, bool includingContents = true)
    {
        string path;
        try
        {
            path = SafePath(root, relativePath);
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }

        lock (Gate(path))
        {
            if (FileMetadata.At(path) is null)
            {
                return null;
            }

            using var stream = OpenExclusive(path, FileMode.Open, FileAccess.Read);
            var initial = FileMetadata.Of(stream);
            byte[]? contents = null;
            if (includingContents)
            {
                using var buffer = new MemoryStream();
                stream.CopyTo(buffer);
                contents = buffer.ToArray();
            }

            var final = FileMetadata.Of(stream);
            if (initial != final || FileMetadata.At(SafePath(root, relativePath)) is not { } named || !initial.SameFile(named))
            {
                throw new VaultFileException(VaultFileError.Changed);
            }

            return VaultFileSnapshot.From(final, contents);
        }
    }

    public static byte[]? ReadManagedPrefix(int count, string root, string relativePath)
    {
        string path;
        try
        {
            path = SafePath(root, relativePath);
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }

        lock (Gate(path))
        {
            if (FileMetadata.At(path) is null)
            {
                return null;
            }

            using var stream = OpenExclusive(path, FileMode.Open, FileAccess.Read);
            var before = FileMetadata.Of(stream);
            var bytes = new byte[(int)Math.Min(count, stream.Length)];
            stream.ReadExactly(bytes);
            if (FileMetadata.At(SafePath(root, relativePath)) is not { } named || !before.SameFile(named))
            {
                return null;
            }

            return bytes;
        }
    }

    /// Atomically installs a fresh file, returning false for an existing safe target.
    public static bool TryCreateNew(byte[] data, string root, string relativePath)
    {
        var path = SafePath(root, relativePath);
        lock (Gate(path))
        {
            if (FileMetadata.At(path) is not null) return false;
            try { AtomicWrite(data, root, relativePath, overwrite: false); }
            catch (IOException) when (FileMetadata.At(path) is not null)
            {
                // Validate again so a collision cannot hide a newly inserted link.
                _ = SafePath(root, relativePath);
                return false;
            }
            return true;
        }
    }

    public static void Create(byte[] data, string root, string relativePath)
    {
        var path = SafePath(root, relativePath);
        lock (Gate(path))
        {
            if (FileMetadata.At(path) is not null)
            {
                using var existing = OpenExclusive(path, FileMode.Open, FileAccess.Read);
                return;
            }

            try
            {
                AtomicWrite(data, root, relativePath, overwrite: false);
            }
            catch (IOException) when (FileMetadata.At(path) is not null)
            {
                using var existing = OpenExclusive(path, FileMode.Open, FileAccess.Read);
            }
        }
    }

    public static void PrepareInbox(string root)
    {
        Create(Utf8.GetBytes(CaptureFormat.NoteHeader(Vault.InboxTitle)), root, Vault.InboxFileName);
        var path = SafePath(root, Vault.InboxFileName);
        if (!OperatingSystem.IsWindows())
        {
            using var stream = OpenExclusive(path, FileMode.Open, FileAccess.Read);
            File.SetUnixFileMode(stream.SafeFileHandle, File.GetUnixFileMode(stream.SafeFileHandle) & (UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute));
        }
    }

    public static void AtomicWrite(byte[] bytes, string root, string relativePath, bool overwrite = true)
    {
        var target = SafePath(root, relativePath, true);
        var existing = FileMetadata.At(target);
        existing?.Validate();
        var temporary = Path.Combine(Path.GetDirectoryName(target)!, ".pending-" + Guid.NewGuid().ToString("N"));
        try
        {
            using (var stream = OpenExclusive(temporary, FileMode.CreateNew, FileAccess.ReadWrite))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }

            _ = SafePath(root, relativePath);
            var current = FileMetadata.At(target);
            if (existing is not null && (current is null || !existing.SameFile(current)))
            {
                throw new VaultFileException(VaultFileError.Changed);
            }

            current?.Validate();
            if (overwrite && current is not null && OperatingSystem.IsWindows())
            {
                File.Replace(temporary, target, null);
            }
            else
            {
                File.Move(temporary, target, overwrite);
            }
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    public static bool CreateAsset(byte[] data, string root, string relativePath)
    {
        var components = PathComponents(relativePath);
        var parent = string.Join('/', components.SkipLast(1));
        _ = SafePath(root, parent.Length == 0 ? ".asset-check" : parent + "/.asset-check", true);
        var path = Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));
        lock (Gate(path))
        {
            if (FileMetadata.At(path) is not null)
            {
                return false;
            }

            try
            {
                AtomicWrite(data, root, relativePath, false);
                return true;
            }
            catch (IOException) when (FileMetadata.At(path) is not null)
            {
                return false;
            }
        }
    }

    public static void EnsureAsset(byte[] bytes, string root, string relativePath)
    {
        var path = SafePath(root, relativePath, true);
        lock (Gate(path))
        {
            var snapshot = ReadManagedSnapshot(root, relativePath);
            if (snapshot?.Contents?.AsSpan().SequenceEqual(bytes) == true)
            {
                return;
            }

            AtomicWrite(bytes, root, relativePath);
        }
    }
}
