using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CaptureApp.Core;

public static partial class NoteFile
{
    // The callback persists the rename intent after validation and before either name changes.
    internal static void RenameSession(string root, string oldPath, string newPath, string title,
        Action<VaultFileSnapshot, byte[], SessionRenameStage>? beforeRename = null, Action? beforeReplace = null)
    {
        var oldParts = PathComponents(oldPath);
        var newParts = PathComponents(newPath);
        if (!oldParts.SkipLast(1).SequenceEqual(newParts.SkipLast(1)))
        {
            throw new VaultFileException(VaultFileError.InvalidFileName);
        }

        var source = SafePath(root, oldPath);
        var target = SafePath(root, newPath);
        lock (Gate(source))
        lock (Gate(target))
        using (var ancestors = RenameAncestors.Lock(root, oldParts))
        {
            var expected = FileMetadata.At(source) ?? throw new FileNotFoundException(source);
            expected.Validate();
            EnsureRenameTarget(source, target);
            using var original = OpenRenameSource(source);
            var opened = FileMetadata.Of(original);
            opened.Validate();
            if (!expected.SameFile(opened)) { throw new VaultFileException(VaultFileError.Changed); }
            using var buffer = new MemoryStream();
            original.CopyTo(buffer);
            if (FileMetadata.Of(original) != opened) { throw new VaultFileException(VaultFileError.Changed); }
            var bytes = buffer.ToArray();
            var rewritten = RewriteHeading(bytes, title);
            var snapshot = VaultFileSnapshot.From(opened, bytes);
            var temporaryName = ".pending-" + Guid.NewGuid().ToString("N");
            var temporary = Path.Combine(Path.GetDirectoryName(source)!, temporaryName);
            var moved = false;
            var replaced = false;
            var targetLost = false;
            var published = opened;
            try
            {
                using (var output = OpenExclusive(temporary, FileMode.CreateNew, FileAccess.ReadWrite))
                {
                    output.Write(rewritten);
                    output.Flush(flushToDisk: true);
                }

                var temporaryIdentity = FileMetadata.At(temporary)!;
                beforeRename?.Invoke(snapshot, rewritten, new(new(temporaryIdentity.Device, temporaryIdentity.Inode),
                    string.Join('/', oldParts.SkipLast(1).Append(temporaryName))));
                ancestors.Validate();
                EnsureOriginal(source, opened);
                EnsureRenameTarget(source, target);
                if (!string.Equals(source, target, StringComparison.Ordinal))
                {
                    if (OperatingSystem.IsWindows()) { RenameByHandle(original.SafeFileHandle, target); }
                    else { File.Move(source, target, false); }
                    moved = true;
                    published = FileMetadata.Of(original);
                }

                beforeReplace?.Invoke();
                ancestors.Validate();
                EnsureOriginal(target, published);
                EnsureOriginal(temporary, temporaryIdentity);
                // Replacement is atomic: the live note is never truncated. The original handle
                // still denies writers, and every ancestor remains pinned until replacement.
                replaced = true;
                if (OperatingSystem.IsWindows() || ReplaceHook.Value is not null) { ReplaceFile(temporary, target, ref targetLost); }
                else { File.Move(temporary, target, true); }
            }
            catch (Exception error)
            {
                if (moved)
                {
                    // Roll back only our original inode and only into an unoccupied old name.
                    // If an unrelated file appeared, retain both files and let the durable intent
                    // resolve the rename; never replace that file during error recovery.
                    try
                    {
                        ancestors.Validate();
                        EnsureOriginal(target, published);
                        if (FileMetadata.At(source) is null)
                        {
                            if (OperatingSystem.IsWindows()) { RenameByHandle(original.SafeFileHandle, source); }
                            else { File.Move(target, source, false); }
                        }
                        else { throw new IOException("The old session name is occupied; rollback cannot replace it."); }
                    }
                    catch (Exception rollback) when (rollback is IOException or UnauthorizedAccessException)
                    {
                        throw new SessionRenamePendingException(error, rollback);
                    }
                }
                throw;
            }
            finally
            {
                try { CleanupTemporary(temporary, target, replaced, targetLost); }
                catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException)
                {
                    // The durable staging identity allows later cleanup. Preserve the transaction's real error.
                    System.Diagnostics.Trace.TraceError($"Session staging cleanup failed: {cleanup}");
                }
            }
        }
    }

    internal static byte[] RewriteHeading(byte[] contents, string title)
    {
        var newline = Array.IndexOf(contents, (byte)'\n');
        var length = newline < 0 ? contents.Length : newline;
        var bom = contents.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF });
        var offset = bom ? 3 : 0;
        var hasHeading = contents.AsSpan(offset).StartsWith(new byte[] { (byte)'#', (byte)' ' });
        var ending = hasHeading
            ? (length > offset && contents[length - 1] == '\r' ? "\r" : "") + (newline < 0 ? "" : "\n")
            : contents.AsSpan().IndexOf(new byte[] { (byte)'\r', (byte)'\n' }) >= 0 ? "\r\n" : "\n";
        var header = Utf8.GetBytes("# " + title + (hasHeading ? ending : ending + ending));
        var tail = hasHeading ? (newline < 0 ? contents.Length : newline + 1) : offset;
        return [.. contents.AsSpan(0, offset), .. header, .. contents.AsSpan(tail)];
    }

    private static void EnsureRenameTarget(string source, string target)
    {
        if (string.Equals(source, target, StringComparison.Ordinal)) { return; }
        if (source.Normalize().Equals(target.Normalize(), StringComparison.OrdinalIgnoreCase))
            throw new SessionStoreException(SessionStoreError.CaseOnlyRename, path: target);
        var wanted = Path.GetFileName(target).Normalize();
        if (Directory.EnumerateFileSystemEntries(Path.GetDirectoryName(source)!).Any(path =>
            Path.GetFileName(path).Normalize().Equals(wanted, StringComparison.OrdinalIgnoreCase)))
        {
            throw new SessionStoreException(SessionStoreError.NameAlreadyExists, path: target);
        }
    }

    internal static void RemoveSessionTemporary(string root, SessionRenameStage stage)
    {
        var parts = PathComponents(stage.TemporaryPath);
        if (!System.Text.RegularExpressions.Regex.IsMatch(parts[^1], @"^\.pending-[0-9a-f]{32}$"))
            throw new VaultFileException(VaultFileError.InvalidFileName);
        using var ancestors = RenameAncestors.Lock(root, parts);
        var path = SafePath(root, stage.TemporaryPath);
        if (FileMetadata.At(path) is null) return;
        using var stream = OpenRenameSource(path);
        var current = FileMetadata.Of(stream);
        current.Validate();
        if (current.Device != stage.Identity.Device || current.Inode != stage.Identity.Inode) return;
        ancestors.Validate();
        if (!OperatingSystem.IsWindows()) { File.Delete(path); return; }
        var disposition = Marshal.AllocHGlobal(1);
        try
        {
            Marshal.WriteByte(disposition, 1);
            if (!RenameNative.SetInformation(stream.SafeFileHandle, 4, disposition, 1)) throw RenameError();
        }
        finally { Marshal.FreeHGlobal(disposition); }
    }

    // Installs a verified ".recovered-" copy of a staged temporary at a missing session target; never overwrites.
    internal static void InstallSessionTemporary(string root, SessionRenameStage stage, string targetPath)
    {
        var parts = PathComponents(stage.TemporaryPath);
        if (!PendingName.IsMatch(parts[^1]))
            throw new VaultFileException(VaultFileError.InvalidFileName);
        var targetParts = PathComponents(targetPath);
        if (!parts.SkipLast(1).SequenceEqual(targetParts.SkipLast(1)))
            throw new VaultFileException(VaultFileError.InvalidFileName);
        lock (Gate(SafePath(root, targetPath)))
        using (var ancestors = RenameAncestors.Lock(root, parts))
        {
            var path = SafePath(root, stage.TemporaryPath);
            var target = SafePath(root, targetPath);
            if (FileMetadata.At(target) is not null) return;
            // Only the ".recovered-" sibling marks a replace that removed the target; a bare ".pending-" may predate it.
            path = Path.Combine(Path.GetDirectoryName(path)!, RecoveredName(parts[^1], targetParts[^1]));
            if (FileMetadata.At(path) is null) return;
            using (var stream = OpenRenameSource(path))
            {
                var current = FileMetadata.Of(stream);
                current.Validate();
                if (current.Device != stage.Identity.Device || current.Inode != stage.Identity.Inode) return;
                ancestors.Validate();
                if (OperatingSystem.IsWindows()) { RenameByHandle(stream.SafeFileHandle, target); }
                else { File.Move(path, target, false); }
            }
        }
    }

    private static void EnsureOriginal(string path, FileMetadata expected)
    {
        var current = FileMetadata.At(path);
        current?.Validate();
        if (current is null || current != expected)
        {
            throw new VaultFileException(VaultFileError.Changed);
        }
    }

    private static FileStream OpenRenameSource(string path)
    {
        if (!OperatingSystem.IsWindows()) { return OpenExclusive(path, FileMode.Open, FileAccess.Read); }
        var handle = RenameNative.CreateFile(FileMetadata.ExtendedPath(path), 0x80010000, 5, 0, 3, 0x00200000, 0);
        if (handle.IsInvalid) { handle.Dispose(); throw RenameError(); }
        return new FileStream(handle, FileAccess.Read);
    }

    private static void RenameByHandle(SafeFileHandle handle, string target)
    {
        var name = System.Text.Encoding.Unicode.GetBytes(FileMetadata.ExtendedPath(target));
        var rootOffset = IntPtr.Size == 8 ? 8 : 4;
        var lengthOffset = rootOffset + IntPtr.Size;
        var nameOffset = lengthOffset + 4;
        var memory = Marshal.AllocHGlobal(nameOffset + name.Length + 2);
        try
        {
            for (var i = 0; i < nameOffset; i++) { Marshal.WriteByte(memory, i, 0); }
            Marshal.WriteInt32(memory, lengthOffset, name.Length);
            Marshal.Copy(name, 0, memory + nameOffset, name.Length);
            Marshal.WriteInt16(memory, nameOffset + name.Length, 0);
            // ReplaceIfExists is FALSE. The kernel, rather than a check-then-overwrite,
            // arbitrates a racing destination creation.
            if (!RenameNative.SetInformation(handle, 3, memory, (uint)(nameOffset + name.Length + 2))) { throw RenameError(); }
        }
        finally { Marshal.FreeHGlobal(memory); }
    }

    private static IOException RenameError() => new(new Win32Exception(Marshal.GetLastPInvokeError()).Message);

    private sealed class RenameAncestors : IDisposable
    {
        private readonly List<(string Path, FileMetadata Identity, SafeFileHandle? Handle)> ancestors = [];
        internal static RenameAncestors Lock(string root, string[] parts)
        {
            var result = new RenameAncestors();
            try
            {
                var current = root;
                result.Add(current);
                foreach (var part in parts.SkipLast(1)) { current = Path.Combine(current, part); result.Add(current); }
                result.Validate();
                return result;
            }
            catch { result.Dispose(); throw; }
        }

        private void Add(string path)
        {
            var identity = FileMetadata.At(path) ?? throw new DirectoryNotFoundException(path);
            identity.Validate(directory: true);
            SafeFileHandle? handle = null;
            if (OperatingSystem.IsWindows())
            {
                // Denying FILE_SHARE_DELETE pins the root and every managed directory
                // against rename/reparse replacement throughout the complete transaction.
                handle = RenameNative.CreateFile(FileMetadata.ExtendedPath(path), 0, 3, 0, 3, 0x02200000, 0);
                if (handle.IsInvalid) { handle.Dispose(); throw RenameError(); }
            }
            ancestors.Add((path, identity, handle));
        }

        internal void Validate()
        {
            foreach (var entry in ancestors)
            {
                var current = FileMetadata.At(entry.Path);
                current?.Validate(directory: true);
                if (current is null || !entry.Identity.SameFile(current)) { throw new VaultFileException(VaultFileError.Changed); }
            }
        }
        public void Dispose() { foreach (var entry in ancestors) { entry.Handle?.Dispose(); } }
    }

    private static class RenameNative
    {
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateFile(string name, uint access, uint share, nint security, uint disposition, uint flags, nint template);
        [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformation(SafeFileHandle handle, int kind, nint information, uint size);
    }
}
