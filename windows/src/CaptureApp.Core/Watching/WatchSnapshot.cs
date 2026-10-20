using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("CaptureApp.Core.Tests")]

namespace CaptureApp.Core.Watching;

// No content handles: even a metadata-only ReadManagedSnapshot opens the file.
internal sealed record WatchSnapshot(FileAttributes Attributes, long Size, long Written, long Created, FileMetadata? Metadata)
{
    private const FileAttributes Recall = (FileAttributes)(0x400000 | 0x40000);
    internal bool IsDirectory => (Attributes & FileAttributes.Directory) != 0;
    internal bool IsLink => (Attributes & FileAttributes.ReparsePoint) != 0 && !IsPlaceholder && Metadata is { IsLink: true };
    internal bool IsPlaceholder => IsOnlineOnly(Attributes);
    internal static bool IsOnlineOnly(FileAttributes attributes) => (attributes & (FileAttributes.Offline | Recall)) != 0;

    internal static WatchSnapshot? At(string path)
    {
        try
        {
            var info = new FileInfo(path);
            info.Refresh();
            if (info.Attributes == (FileAttributes)(-1))
            {
                // FileInfo.Exists also returns false for directories and access failures.
                _ = File.GetAttributes(path);
                info.Refresh();
            }

            var attributes = info.Attributes;
            var directory = (attributes & FileAttributes.Directory) != 0;
            // Attribute queries do not open or recall the placeholder. In particular,
            // do not call FileMetadata.At (CreateFile on Windows) in this branch.
            if (IsOnlineOnly(attributes))
            {
                return new(attributes, directory ? 0 : info.Length, info.LastWriteTimeUtc.Ticks, info.CreationTimeUtc.Ticks, null);
            }

            var metadata = FileMetadata.At(path);
            return metadata is null ? null : new(attributes, metadata.Size, 0, 0, metadata);
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    internal static WatchSnapshot? Managed(string root, string relative, bool directory = false)
    {
        var current = root;
        var parts = NoteFile.PathComponents(relative);
        for (var i = 0; i <= parts.Length; i++)
        {
            var value = At(current);
            if (value is null)
            {
                return null;
            }

            if (value.IsLink)
            {
                throw new VaultFileException(VaultFileError.PermissionDenied, "Watch paths cannot contain links.");
            }

            value.Metadata?.Validate(directory: i < parts.Length || directory);

            if (i == parts.Length)
            {
                return value;
            }

            if (!value.IsDirectory || value.IsPlaceholder)
            {
                return null;
            }

            current = Path.Combine(current, parts[i]);
        }

        return null;
    }

    internal bool SameDirectory(WatchSnapshot other) => Metadata is { } a && other.Metadata is { } b
        ? a.Device == b.Device && a.Inode == b.Inode
        : this == other;
}
