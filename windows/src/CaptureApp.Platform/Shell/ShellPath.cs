namespace CaptureApp.Platform.Shell;

internal static class ShellPath
{
    /// <summary>Resolves a path and wraps it in quotes; Windows file names cannot contain a quote.</summary>
    internal static string Quote(string path, string paramName)
    {
        var fullPath = Path.GetFullPath(path);
        if (fullPath.Contains('"')) throw new ArgumentException("Windows paths cannot contain a quote character.", paramName);
        return $"\"{fullPath}\"";
    }
}
