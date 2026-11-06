namespace CaptureApp.AppCore.Shell;

/// Exception filters for settings saves made from the UI.
public static class SettingsFailures
{
    /// A settings or shortcut save that failed for an expected reason: the file is locked, denied, or holds data that can't be replaced.
    public static bool IsSaveError(Exception error) => error is IOException or UnauthorizedAccessException or InvalidDataException;

    /// Start-at-login (Run key) failures the windows report instead of crashing.
    public static bool IsLoginItemError(Exception error) => error is InvalidOperationException or UnauthorizedAccessException or System.Security.SecurityException or ArgumentException;
}
