namespace CaptureApp.AppCore.Shell;

/// Exception filters shared by the Setup and Settings windows.
public static class SettingsFailures
{
    /// A settings or shortcut save that failed for an expected reason: the file is locked, denied, or holds data that can't be replaced.
    public static bool IsSaveError(Exception error) => error is IOException or UnauthorizedAccessException or InvalidDataException;
}
