using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CaptureApp.EmbedHelper;

/// Windows only: runs the helper as low-impact background work (EcoQoS, below-normal priority and
/// background resource mode). Each flag reports whether the call succeeded.
internal static class BackgroundMode
{
    internal readonly record struct Status(bool EcoQos, bool BelowNormal, bool BackgroundMode);

    private const int ProcessPowerThrottling = 4;
    private const uint ProcessPowerThrottlingCurrentVersion = 1;
    private const uint ProcessPowerThrottlingExecutionSpeed = 1;
    private const uint BelowNormalPriorityClass = 0x4000;
    private const uint ProcessModeBackgroundBegin = 0x00100000;

    /// Null on platforms without these controls.
    public static Status? Apply()
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        var process = Process.GetCurrentProcess().Handle;
        var state = new PowerThrottlingState
        {
            Version = ProcessPowerThrottlingCurrentVersion,
            ControlMask = ProcessPowerThrottlingExecutionSpeed,
            StateMask = ProcessPowerThrottlingExecutionSpeed
        };
        var ecoQos = SetProcessInformation(process, ProcessPowerThrottling, ref state, (uint)Marshal.SizeOf<PowerThrottlingState>());
        var belowNormal = SetPriorityClass(process, BelowNormalPriorityClass);
        var background = SetPriorityClass(process, ProcessModeBackgroundBegin);
        return new Status(ecoQos, belowNormal, background);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PowerThrottlingState
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessInformation(IntPtr process, int informationClass, ref PowerThrottlingState information, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetPriorityClass(IntPtr process, uint priorityClass);
}
