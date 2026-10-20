using System.Diagnostics;
using System.IO;
using CaptureApp.Core;
using CaptureApp.Platform.Selection;

namespace CaptureApp.Platform.Context;

/// <summary>A hotkey-time identity. Capture synchronously before opening any application UI.</summary>
public sealed record FrontmostContext(nint WindowHandle, uint ProcessIdentifier, string? AppName = null,
    string? ExecutablePath = null, string? WindowTitle = null)
{
    // SourceHeading in Core owns the Swift browser-suffix stripping and Unknown source fallback.
    public CaptureSource Source => new(AppName, WindowTitle);
    public string SourceHeading => CaptureFormat.SourceHeading(Source);

    public static FrontmostContext Capture()
    {
        var window = NativeMethods.GetForegroundWindow();
        _ = NativeMethods.GetWindowThreadProcessId(window, out var pid);
        string? path = null;
        string? name = null;
        if (pid != 0)
        {
            var process = NativeMethods.OpenProcess(0x1000, false, pid);
            if (process != 0)
            {
                try
                {
                    var buffer = new char[32768];
                    uint length = (uint)buffer.Length;
                    if (NativeMethods.QueryFullProcessImageName(process, 0, buffer, ref length))
                    {
                        path = new string(buffer, 0, (int)length);
                        name = FileVersionInfo.GetVersionInfo(path).FileDescription;
                        if (string.IsNullOrWhiteSpace(name)) name = Path.GetFileNameWithoutExtension(path);
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { }
                finally { _ = NativeMethods.CloseHandle(process); }
            }
        }
        var title = new char[32768];
        var count = NativeMethods.GetWindowText(window, title, title.Length);
        return new(window, pid, name, path, count > 0 ? new string(title, 0, count) : null);
    }

    internal bool IsStillFrontmost()
    {
        var window = NativeMethods.GetForegroundWindow();
        _ = NativeMethods.GetWindowThreadProcessId(window, out var pid);
        return window != 0 && window == WindowHandle && pid != 0 && pid == ProcessIdentifier;
    }
}
