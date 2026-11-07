namespace CaptureApp.AppCore.Tests;

internal sealed class TempDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(RealPath(System.IO.Path.GetTempPath()), "captureapp-appcore-tests-" + Guid.NewGuid().ToString("N"));

    public TempDirectory() => Directory.CreateDirectory(Path);

    public void Dispose()
    {
        if (!OperatingSystem.IsWindows())
        {
            foreach (var directory in Directory.EnumerateDirectories(Path, "*", SearchOption.AllDirectories).Prepend(Path))
            {
                if (new DirectoryInfo(directory).LinkTarget is null)
                {
                    File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                }
            }
        }

        Directory.Delete(Path, true);
    }

    private static string RealPath(string path)
    {
        var full = System.IO.Path.GetFullPath(path).TrimEnd(System.IO.Path.DirectorySeparatorChar);
        var root = System.IO.Path.GetPathRoot(full)!;
        var current = root;
        foreach (var part in full[root.Length..].Split(System.IO.Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = System.IO.Path.Combine(current, part);
            var target = new DirectoryInfo(current).ResolveLinkTarget(returnFinalTarget: true);
            if (target is not null) current = target.FullName;
        }

        return current;
    }
}
