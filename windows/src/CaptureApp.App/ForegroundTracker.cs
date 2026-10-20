using System.Runtime.InteropServices;
using System.Text;

namespace CaptureApp.App;

/// Remembers the last foreground window that is neither ours nor the shell, so a tray-menu capture can go back to it.
internal sealed class ForegroundTracker : IDisposable
{
    private const uint EventSystemForeground = 3;
    private const uint WinEventOutOfContext = 0;
    private static readonly string[] ShellClasses =
    [
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland", "Progman", "WorkerW"
    ];

    private readonly WinEventCallback callback;
    private readonly nint hook;
    private long last;

    public ForegroundTracker(Action<string>? log = null)
    {
        callback = OnEvent;
        hook = SetWinEventHook(EventSystemForeground, EventSystemForeground, 0, callback, 0, 0, WinEventOutOfContext);
        if (hook == 0) { log?.Invoke("The foreground window hook could not be installed; tray Capture Selection has no target."); }
    }

    private static readonly string[] DesktopClasses = ["Progman", "WorkerW"];

    /// Track: remember it. Keep: ignore (our own windows and the tray windows the menu opens). Clear: the user went to the desktop.
    public static Decision Decide(uint processId, uint ownProcessId, string? className)
    {
        if (className is not null && DesktopClasses.Contains(className, StringComparer.Ordinal)) { return Decision.Clear; }
        if (processId == 0 || processId == ownProcessId || IsShellClass(className)) { return Decision.Keep; }
        return Decision.Track;
    }

    public enum Decision { Track, Keep, Clear }

    /// Our own windows and the shell are never targets.
    public static bool ShouldTrack(uint processId, uint ownProcessId, string? className) =>
        Decide(processId, ownProcessId, className) == Decision.Track;

    /// The last tracked window, or 0.
    public nint Last => (nint)Interlocked.Read(ref last);

    /// True for the taskbar, tray overflow and desktop windows that must never become a capture target.
    public static bool IsShellClass(string? className) =>
        className is not null && ShellClasses.Contains(className, StringComparer.Ordinal);

    public static nint Foreground() => GetForegroundWindow();

    public static bool BringToForeground(nint window) => SetForegroundWindow(window);

    private void OnEvent(nint hookHandle, uint eventType, nint window, int objectId, int childId, uint thread, uint time)
    {
        if (window == 0 || objectId != 0) { return; }
        _ = GetWindowThreadProcessId(window, out var pid);
        var name = new StringBuilder(256);
        var className = GetClassName(window, name, name.Capacity) > 0 ? name.ToString() : null;
        switch (Decide(pid, (uint)Environment.ProcessId, className))
        {
            case Decision.Track: Interlocked.Exchange(ref last, window); break;
            case Decision.Clear: Interlocked.Exchange(ref last, 0); break;
        }
    }

    public void Dispose()
    {
        if (hook != 0) { _ = UnhookWinEvent(hook); }
    }

    private delegate void WinEventCallback(nint hook, uint eventType, nint window, int objectId, int childId, uint thread, uint time);

    [DllImport("user32.dll")] private static extern nint SetWinEventHook(uint min, uint max, nint module, WinEventCallback callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, StringBuilder name, int count);
}
