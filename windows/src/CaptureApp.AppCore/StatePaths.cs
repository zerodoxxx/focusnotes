using CaptureApp.Core;

namespace CaptureApp.AppCore;

public static class StatePaths
{
    public static string DefaultDirectory()
    {
        var parent = OperatingSystem.IsWindows()
            ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support");
        if (string.IsNullOrWhiteSpace(parent))
        {
            throw new InvalidOperationException("The current user's application data directory could not be resolved.");
        }

        return Path.GetFullPath(Path.Combine(parent, AppInfo.BundleId));
    }
}
