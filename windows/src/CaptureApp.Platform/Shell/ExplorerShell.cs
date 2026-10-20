using System.Diagnostics;

namespace CaptureApp.Platform.Shell;

public static class ExplorerShell
{
    public static Process? Reveal(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var fullPath = Path.GetFullPath(path);
        if (fullPath.Contains('"'))
        {
            throw new ArgumentException("Windows paths cannot contain a quote character.", nameof(path));
        }

        return Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"/select,\"{fullPath}\"",
            UseShellExecute = true
        });
    }

    public static Process? Open(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        return Process.Start(new ProcessStartInfo
        {
            FileName = Path.GetFullPath(path),
            UseShellExecute = true
        });
    }
}
