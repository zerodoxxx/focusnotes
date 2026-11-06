using System.Diagnostics;

namespace CaptureApp.Platform.Shell;

public static class ExplorerShell
{
    public static Process? Reveal(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        return Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"/select,{ShellPath.Quote(path, nameof(path))}",
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
