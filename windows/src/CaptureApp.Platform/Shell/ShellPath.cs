namespace CaptureApp.Platform.Shell;

internal static class ShellPath
{
    /// <summary>Windows file names cannot contain a quote; each caller keeps its own error message.</summary>
    internal static string Quote(string path, string paramName, string quoteMessage)
    {
        var fullPath = Path.GetFullPath(path);
        if (fullPath.Contains('"')) throw new ArgumentException(quoteMessage, paramName);
        return $"\"{fullPath}\"";
    }
}
