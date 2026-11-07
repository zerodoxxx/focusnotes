namespace CaptureApp.Platform.Interop;

internal static class SafeWndProc
{
    /// <summary>Runs a user event handler from a window procedure; exceptions must not unwind into unmanaged code.</summary>
    internal static void Invoke<T>(Action<T>? handler, T argument)
    {
        if (handler is null) return;
        try
        {
            handler(argument);
        }
        catch
        {
            // Must not unwind through the window procedure.
        }
    }
}
