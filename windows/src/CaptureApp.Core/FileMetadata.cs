using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CaptureApp.Core;

public enum VaultFileError
{
    InvalidFileName,
    PermissionDenied,
    Changed,
    Unavailable
}

public sealed class VaultFileException(VaultFileError kind, string? message = null) : IOException(message ?? kind.ToString())
{
    public VaultFileError Kind { get; } = kind;
}

internal sealed record FileMetadata(ulong Device, ulong Inode, long Size, long ModifiedSeconds, long ModifiedNanoseconds, long ChangedSeconds, long ChangedNanoseconds, uint Mode, uint Links, uint Owner)
{
    internal bool IsDirectory => (Mode & 0xF000) == 0x4000;
    internal bool IsRegular => (Mode & 0xF000) == 0x8000;
    internal bool IsLink => (Mode & 0xF000) == 0xA000;

    internal bool SameFile(FileMetadata other) => Device == other.Device && Inode == other.Inode;
    internal void Validate(bool directory = false)
    {
        if ((directory ? !IsDirectory : !IsRegular || Links != 1) || (!OperatingSystem.IsWindows() && Owner != Native.GetEUid()))
        {
            throw new VaultFileException(VaultFileError.PermissionDenied, "Not an owned, unlinked managed file or directory.");
        }
    }

    internal static FileMetadata? At(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            if (Native.LStat(path, out var value) != 0)
            {
                var error = Marshal.GetLastPInvokeError();
                if (error is 2 or 20)
                {
                    return null;
                }

                if (error is 5 or 6 or 19)
                {
                    throw new VaultFileException(VaultFileError.Unavailable, new Win32Exception(error).Message);
                }
                throw new IOException(new Win32Exception(error).Message);
            }

            return FromUnix(value, Native.LinkCount(path, null));
        }

        using var handle = Native.CreateFile(ExtendedPath(path), 0, 7, 0, 3, 0x02200000, 0);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastPInvokeError();
            if (error is 2 or 3)
            {
                return null;
            }

            if (error is 21 or 55 or 1117 or 1167)
            {
                throw new VaultFileException(VaultFileError.Unavailable, new Win32Exception(error).Message);
            }
            throw new IOException(new Win32Exception(error).Message);
        }

        return FromWindows(handle);
    }

    // Raw Win32 calls honour MAX_PATH unless the path is \\?\-prefixed (the .NET file APIs do this themselves).
    internal static string ExtendedPath(string path)
    {
        if (path.Length < 240 || path.StartsWith(@"\\?\", StringComparison.Ordinal))
        {
            return path;
        }

        var full = Path.GetFullPath(path);
        return full.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + full[2..] : @"\\?\" + full;
    }

    internal static FileMetadata Of(FileStream stream)
    {
        if (OperatingSystem.IsWindows())
        {
            return FromWindows(stream.SafeFileHandle);
        }

        if (Native.FStat(stream.SafeFileHandle.DangerousGetHandle(), out var value) != 0)
        {
            throw new IOException("Could not inspect the opened file.");
        }

        return FromUnix(value, Native.LinkCount(null, stream.SafeFileHandle));
    }

    private static FileMetadata FromUnix(Native.FileStatus s, uint links) => new(unchecked((ulong)s.Device), unchecked((ulong)s.Inode), s.Size, s.Modified, s.ModifiedNanos, s.Changed, s.ChangedNanos, unchecked((uint)s.Mode), links, s.Owner);
    private static FileMetadata FromWindows(SafeFileHandle handle)
    {
        if (!Native.GetFileInformationByHandle(handle, out var s) || !Native.GetFileInformationByHandleEx(handle, 0, out var basic, (uint)Marshal.SizeOf<Native.BasicInfo>()))
        {
            throw new IOException(new Win32Exception(Marshal.GetLastPInvokeError()).Message);
        }

        var modified = basic.LastWriteTime - 116444736000000000L;
        var changed = basic.ChangeTime - 116444736000000000L;
        // Only name-surrogate reparse points are links; other reparse points (OneDrive placeholders) are plain files.
        uint mode = (s.Attributes & 0x400) != 0 && IsLinkReparse(handle) ? 0xA000u : (s.Attributes & 0x10) != 0 ? 0x4000u : 0x8000u;
        return new(s.Volume, ((ulong)s.IndexHigh << 32) | s.IndexLow, ((long)s.SizeHigh << 32) | s.SizeLow, modified / 10000000, modified % 10000000 * 100, changed / 10000000, changed % 10000000 * 100, mode, s.Links, 0);
    }

    private static bool IsLinkReparse(SafeFileHandle handle)
    {
        // Name-surrogate tags (symlink, junction, LX symlink) redirect elsewhere; cloud tags do not.
        // A failed query fails closed and counts as a link.
        return !Native.GetFileTagInfo(handle, 9, out var tag, (uint)Marshal.SizeOf<Native.TagInfo>())
            || (tag.ReparseTag & 0x20000000) != 0;
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct TagInfo
        {
            internal uint Attributes, ReparseTag;
        }

        // Stable .NET Unix PAL layout; metadata only. Content/locking uses FileStream.
        [StructLayout(LayoutKind.Sequential)]
        internal struct FileStatus
        {
            internal int Flags, Mode;
            internal uint Owner, Group;
            internal long Size, Access, AccessNanos, Modified, ModifiedNanos, Changed, ChangedNanos, Birth, BirthNanos, Device, RDevice, Inode;
            internal uint UserFlags, Padding;
        }

        [DllImport("System.Native", EntryPoint = "SystemNative_LStat", SetLastError = true)]
        internal static extern int LStat([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out FileStatus value);
        [DllImport("System.Native", EntryPoint = "SystemNative_FStat", SetLastError = true)]
        internal static extern int FStat(nint fd, out FileStatus value);
        [DllImport("System.Native", EntryPoint = "SystemNative_GetEUid")]
        internal static extern uint GetEUid();
        // The .NET 10 PAL does not expose nlink. Read only this native stat field.
        internal static uint LinkCount(string? path, SafeFileHandle? handle)
        {
            var buffer = Marshal.AllocHGlobal(512);
            try
            {
                var result = path is null ? FStatNative(handle!.DangerousGetHandle().ToInt32(), buffer) : LStatNative(path, buffer);
                if (result != 0)
                {
                    throw new IOException("Could not inspect hard-link count.");
                }

                return OperatingSystem.IsMacOS() ? (uint)(ushort)Marshal.ReadInt16(buffer, 6) : RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? unchecked((uint)Marshal.ReadInt32(buffer, 20)) : checked((uint)Marshal.ReadInt64(buffer, 16));
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        [DllImport("libc", EntryPoint = "lstat", SetLastError = true)]
        private static extern int LStatNative([MarshalAs(UnmanagedType.LPUTF8Str)] string path, nint buffer);
        [DllImport("libc", EntryPoint = "fstat", SetLastError = true)]
        private static extern int FStatNative(int fd, nint buffer);
        [StructLayout(LayoutKind.Sequential)]
        internal struct HandleInfo
        {
            internal uint Attributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct BasicInfo
        {
            internal long CreationTime, LastAccessTime, LastWriteTime, ChangeTime;
            internal uint Attributes;
        }

        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateFile(string name, uint access, uint share, nint security, uint disposition, uint flags, nint template);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetFileInformationByHandle(SafeFileHandle handle, out HandleInfo info);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out BasicInfo info, uint size);
        [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetFileTagInfo(SafeFileHandle handle, int kind, out TagInfo info, uint size);
    }
}
