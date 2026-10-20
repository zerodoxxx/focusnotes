namespace CaptureApp.Platform;

/// <summary>Shared by the platform results and the application's string table.</summary>
public static class PlatformStrings
{
    public const string NoTextSelected = "No text selected";
    public const string FallbackOffHint = "This app doesn't share its selection; turn on the clipboard fallback in Settings";
    public const string SecureField = "Can't capture from secure fields";
    public const string ReleaseShortcutKeys = "Release the shortcut keys and try again";
    public const string ElevatedTarget = "Can't capture from apps running as administrator";
    public const string CouldNotCapture = "Couldn't capture selection";
    public const string ClipboardTooLarge = "Your clipboard is too large to restore safely";
    public const string UnknownSource = "Unknown source";
    public static string CaptureAreaHint(string binding) => $"Use Capture Area ({binding}) instead";
}
