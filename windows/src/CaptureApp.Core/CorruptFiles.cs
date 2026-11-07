namespace CaptureApp.Core;

/// Shared layout for moving unreadable state files into a sibling "corrupt" folder.
public static class CorruptFiles
{
    public const string DirectoryName = "corrupt";

    public static string CreateDirectory(string parent)
    {
        var directory = Path.Combine(parent, DirectoryName);
        Directory.CreateDirectory(directory);
        return directory;
    }

    // A GUID suffix keeps earlier quarantined copies; `alwaysUnique` adds it even without a collision.
    public static string Stem(string corruptDirectory, string stem, string extension, bool alwaysUnique = false) =>
        alwaysUnique || File.Exists(Path.Combine(corruptDirectory, stem + extension)) ? stem + "-" + Guid.NewGuid().ToString("N") : stem;
}
