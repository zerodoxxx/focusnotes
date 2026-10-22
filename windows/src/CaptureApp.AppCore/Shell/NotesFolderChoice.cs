namespace CaptureApp.AppCore.Shell;

/// Validates a folder before it can become the saved notes destination.
public static class NotesFolderChoice
{
    /// Returns an absolute path after checking that the folder can be written to.
    /// Existing notes are never moved or opened by this check.
    public static string Probe(string folder)
    {
        var value = folder.Trim();
        if (!Path.IsPathFullyQualified(value))
        {
            throw new ArgumentException("Choose an absolute folder path.");
        }

        var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
        Directory.CreateDirectory(path);
        var probe = Path.Combine(path, ".probe-" + Guid.NewGuid().ToString("N") + ".tmp");
        using (var stream = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                   1, FileOptions.DeleteOnClose))
        {
            stream.WriteByte(0);
        }

        return path;
    }

    public static bool SameFolder(string first, string second) => string.Equals(
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(first)),
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(second)),
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
}
