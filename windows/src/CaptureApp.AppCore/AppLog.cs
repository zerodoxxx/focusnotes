using System.Collections.Concurrent;
using System.Globalization;
using System.Text;

namespace CaptureApp.AppCore;

public enum AppLogLevel
{
    Debug,
    Info,
    Notice,
    Error
}

/// A small local file logger with one category per app component.
public sealed class AppLog
{
    private static readonly ConcurrentDictionary<string, object> Gates = new(StringComparer.Ordinal);
    private readonly string directory;
    private readonly string category;
    private readonly object gate;

    public AppLog(string stateDirectory, string category)
    {
        directory = Path.Combine(Path.GetFullPath(stateDirectory), "logs");
        this.category = category;
        gate = Gates.GetOrAdd(directory, _ => new object());
    }

    public void Debug(string message) => Write(AppLogLevel.Debug, message);
    public void Info(string message) => Write(AppLogLevel.Info, message);
    public void Notice(string message) => Write(AppLogLevel.Notice, message);
    public void Error(string message) => Write(AppLogLevel.Error, message);

    private void Write(AppLogLevel level, string message)
    {
        var now = DateTimeOffset.Now;
        var file = Path.Combine(directory, now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + ".log");
        var line = $"{now:O} [{level.ToString().ToLowerInvariant()}] [{category}] {message}{Environment.NewLine}";
        lock (gate)
        {
            try
            {
                Directory.CreateDirectory(directory);
                File.AppendAllText(file, line, new UTF8Encoding(false));
                RetainRecentFiles();
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private void RetainRecentFiles()
    {
        var files = Directory.EnumerateFiles(directory, "*.log")
            .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
            .Skip(7);
        foreach (var path in files)
        {
            try { File.Delete(path); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
