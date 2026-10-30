namespace CaptureApp.Core;

/// Writes a file through a flushed hidden temporary and a move, retrying while a scanner holds it.
public static class DurableFile
{
    // Test seam: replaces the final move, scoped to the calling flow.
    internal static readonly AsyncLocal<Action<string, string>?> MoveHook = new();

    public static void Write(string path, byte[] contents)
    {
        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath)!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, "." + Path.GetFileName(fullPath) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                       4096, FileOptions.WriteThrough))
            {
                stream.Write(contents);
                stream.Flush(true);
            }

            RetryWhileLocked(() => (MoveHook.Value ?? ((source, target) => File.Move(source, target, true)))(temporary, fullPath));
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    // Antivirus scanners and indexers briefly open a file that was just written. Retry for up to 10 s like
    // NoteFile.OpenExclusive, so a journal record staged a moment earlier can still be replaced or removed.
    public static void RetryWhileLocked(Action change)
    {
        var until = Environment.TickCount64 + 10000;
        while (true)
        {
            try
            {
                change();
                return;
            }
            catch (Exception error) when (Environment.TickCount64 < until && IsTransient(error, OperatingSystem.IsWindows()))
            {
                Thread.Sleep(2);
            }
        }
    }

    // Sharing and lock violations (EAGAIN off Windows). On Windows, replacing or deleting a file that another
    // process holds open can report access denied instead, so that is retried too.
    internal static bool IsTransient(Exception error, bool windows) =>
        error is IOException && (error.HResult & 0xFFFF) is 11 or 32 or 33 || windows && error is UnauthorizedAccessException;
}
