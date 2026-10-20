using System.Diagnostics;
using CaptureApp.Overlay.Interop;
using CaptureApp.Platform.Context;

namespace CaptureApp.App;

/// The window operations the tray capture needs, injectable for tests.
internal interface IForegroundProbe
{
    nint Last { get; }
    bool CanRestore(nint window);
    void BringToForeground(nint window);
    nint Foreground();
    FrontmostContext CaptureContext();
}

internal sealed class WindowsForegroundProbe(ForegroundTracker tracker, FocusReturnTracker restore) : IForegroundProbe
{
    public nint Last => tracker.Last;
    public bool CanRestore(nint window) => restore.CanRestore(window);
    public void BringToForeground(nint window) => ForegroundTracker.BringToForeground(window);
    public nint Foreground() => ForegroundTracker.Foreground();
    public FrontmostContext CaptureContext() => FrontmostContext.Capture();
}

/// Returns to the app the user was in before the tray menu took the foreground, then hands its context to the capture.
internal sealed class MenuCaptureFlow(IForegroundProbe probe)
{
    public static readonly TimeSpan Deadline = TimeSpan.FromMilliseconds(300);

    /// Calls <paramref name="capture"/> only when the remembered window is foreground and still the frontmost context.
    /// <param name="refuse">Called with true when a remembered window existed but could not be used.</param>
    public async Task RunAsync(Action<bool> refuse, Action<FrontmostContext> capture, TimeSpan? deadline = null)
    {
        var target = probe.Last;
        if (target == 0) { refuse(false); return; }
        if (!probe.CanRestore(target)) { refuse(true); return; }

        // The menu click was the last input, so Windows lets us hand the foreground back.
        probe.BringToForeground(target);
        var clock = Stopwatch.StartNew();
        while (probe.Foreground() != target && clock.Elapsed < (deadline ?? Deadline)) { await Task.Delay(10); }
        if (probe.Foreground() != target) { refuse(true); return; }

        var context = probe.CaptureContext();
        if (context.WindowHandle != target) { refuse(true); return; }
        capture(context);
    }
}
