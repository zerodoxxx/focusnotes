using System.Runtime.InteropServices;

namespace CaptureApp.Overlay.Interop;

/// <summary>Tracks external foreground changes even while a sticky panel is inactive.</summary>
public sealed class FocusReturnTracker : IDisposable
{
    private readonly NativeMethods.WinEventCallback callback;
    private readonly nint hook;
    private readonly IVirtualDesktopManager? desktops;
    private nint lastExternal;
    private bool disposed;
    internal static FocusReturnTracker Shared { get; } = new();
    public FocusReturnTracker()
    {
        try { desktops = (IVirtualDesktopManager?)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A"), throwOnError: true)!); }
        catch (Exception e) when (e is COMException or TypeLoadException) { }
        callback = (_, _, window, _, _, _, _) => Observe(window);
        hook = NativeMethods.SetWinEventHook(NativeMethods.EventSystemForeground, NativeMethods.EventSystemForeground, 0, callback, 0, 0, NativeMethods.WinEventOutOfContext);
        Observe(NativeMethods.GetForegroundWindow());
    }
    private static bool IsOurs(nint window)
    {
        NativeMethods.GetWindowThreadProcessId(window, out var processId);
        return processId == Environment.ProcessId;
    }
    private void Observe(nint window) { if (window != 0 && !IsOurs(window)) lastExternal = window; }
    /// <summary>Call immediately before hotkey/text-field activation; refresh on every reactivation.</summary>
    public nint BeforeActivation()
    {
        Observe(NativeMethods.GetForegroundWindow());
        return lastExternal;
    }
    public bool IsOnCurrentDesktop(nint window)
    {
        if (desktops is null) return false; // An unknown desktop is never a valid restoration target.
        try { return desktops.IsWindowOnCurrentVirtualDesktop(window, out var current) >= 0 && current != 0; }
        catch (COMException) { return false; }
    }
    public bool CanRestore(nint window) => window != 0 && !IsOurs(window) && NativeMethods.IsWindow(window) && !NativeMethods.IsIconic(window) && NativeMethods.IsWindowVisible(window) && IsOnCurrentDesktop(window);
    internal void RestoreExplicit(nint window) { if (CanRestore(window)) NativeMethods.SetForegroundWindow(window); }
    internal bool DesktopAvailable => desktops is not null;
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (hook != 0) NativeMethods.UnhookWinEvent(hook);
        if (desktops is not null) Marshal.ReleaseComObject(desktops);
        GC.KeepAlive(callback);
    }
    [ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IVirtualDesktopManager
    {
        [PreserveSig] int IsWindowOnCurrentVirtualDesktop(nint window, out int current);
        [PreserveSig] int GetWindowDesktopId(nint window, out Guid desktop);
        [PreserveSig] int MoveWindowToDesktop(nint window, in Guid desktop);
    }
}
