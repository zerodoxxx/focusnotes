using System.Runtime.InteropServices;
using System.Windows;

namespace CaptureApp.Overlay.Interop;

internal readonly record struct MonitorGeometry(Rect WorkArea, double Scale)
{
    internal static MonitorGeometry UnderPointer()
    {
        NativeMethods.GetCursorPos(out var point);
        var monitor = NativeMethods.MonitorFromPoint(point, 2); // MONITOR_DEFAULTTONEAREST
        var info = new NativeMethods.MonitorInfo { Size = (uint)Marshal.SizeOf<NativeMethods.MonitorInfo>() };
        if (!NativeMethods.GetMonitorInfo(monitor, ref info)) throw new InvalidOperationException("Cannot read monitor work area.");
        var scale = NativeMethods.GetDpiForMonitor(monitor, 0, out var x, out _) >= 0 ? x / Tokens.RenderDpi : Tokens.One;
        return new(new Rect(info.Work.Left / scale, info.Work.Top / scale, (info.Work.Right - info.Work.Left) / scale, (info.Work.Bottom - info.Work.Top) / scale), scale);
    }
}
