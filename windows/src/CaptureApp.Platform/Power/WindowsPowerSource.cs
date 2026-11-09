using System.ComponentModel;
using System.Runtime.InteropServices;
using CaptureApp.Platform.Interop;

namespace CaptureApp.Platform.Power;

/// <summary>Reads Windows AC/battery-saver state and listens for power-setting and suspend/resume broadcasts.</summary>
public sealed class WindowsPowerSource : IPowerSource
{
    private const uint WmPowerBroadcast = 0x0218;
    private const uint WmClose = 0x0010;
    private const uint WmDestroy = 0x0002;
    private const uint WmNcDestroy = 0x0082;
    private const uint DeviceNotifyWindowHandle = 0;
    private const uint PbtApmSuspend = 0x0004;
    private const uint PbtApmResumeCritical = 0x0006;
    private const uint PbtApmResumeSuspend = 0x0007;
    private const uint PbtApmResumeAutomatic = 0x0012;
    private const uint PbtPowerSettingChange = 0x8013;

    public static readonly Guid AcDcPowerSourceSetting = new("5D3E9A59-E9D5-4B00-A6BD-FF34FF516548");
    public static readonly Guid PowerSavingStatusSetting = new("E00958C0-C213-4ACE-AC77-FECCED2EEEA5");

    private readonly object _sync = new();
    private readonly ManualResetEventSlim _ready = new();
    private readonly Thread _thread;
    private readonly WindowNativeMethods.WindowProcedure _windowProcedure;
    private readonly string _className = $"PlatformPowerMonitorWindow.{Guid.NewGuid():N}";
    private IntPtr _windowHandle;
    private IntPtr _acNotification;
    private IntPtr _batterySaverNotification;
    private Exception? _startupFailure;
    private PowerSnapshot _power = new(IsOnAc: false, IsBatterySaverOn: true);
    private bool _disposed;

    public WindowsPowerSource()
    {
        _windowProcedure = WindowProcedure;
        _thread = new Thread(MessageLoop)
        {
            IsBackground = true,
            Name = "Power monitor notifications"
        };
        _thread.Start();
        _ready.Wait();
        if (_startupFailure is not null)
        {
            _thread.Join();
            throw new InvalidOperationException("Could not initialize Windows power notifications.", _startupFailure);
        }

        Refresh();
    }

    public bool IsOnAC
    {
        get { lock (_sync) return _power.IsOnAc; }
    }

    public bool IsBatterySaverOn
    {
        get { lock (_sync) return _power.IsBatterySaverOn; }
    }

    public event EventHandler? Changed;

    public event EventHandler? Suspending;

    public event EventHandler? Resumed;

    private void MessageLoop()
    {
        try
        {
            var instance = WindowNativeMethods.GetModuleHandle(null);
            var classNamePointer = Marshal.StringToHGlobalUni(_className);
            try
            {
                var windowClass = new WindowNativeMethods.WindowClassEx
                {
                    Size = (uint)Marshal.SizeOf<WindowNativeMethods.WindowClassEx>(),
                    WindowProcedure = Marshal.GetFunctionPointerForDelegate(_windowProcedure),
                    Instance = instance,
                    ClassName = classNamePointer
                };
                if (WindowNativeMethods.RegisterClassEx(ref windowClass) == 0)
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError(), "RegisterClassEx failed for the power monitor.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(classNamePointer);
            }

            _windowHandle = WindowNativeMethods.CreateWindowEx(0, _className, null, 0, 0, 0, 0, 0,
                IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
            if (_windowHandle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not create the power notification window.");
            }

            _acNotification = RegisterSetting(AcDcPowerSourceSetting);
            _batterySaverNotification = RegisterSetting(PowerSavingStatusSetting);
        }
        catch (Exception exception)
        {
            _startupFailure = exception;
            _ready.Set();
            return;
        }

        _ready.Set();
        while (true)
        {
            var result = WindowNativeMethods.GetMessage(out var message, IntPtr.Zero, 0, 0);
            if (result <= 0)
            {
                break;
            }

            WindowNativeMethods.TranslateMessage(ref message);
            WindowNativeMethods.DispatchMessage(ref message);
        }

        if (_acNotification != IntPtr.Zero) PowerNativeMethods.UnregisterPowerSettingNotification(_acNotification);
        if (_batterySaverNotification != IntPtr.Zero) PowerNativeMethods.UnregisterPowerSettingNotification(_batterySaverNotification);
        WindowNativeMethods.UnregisterClass(_className, WindowNativeMethods.GetModuleHandle(null));
    }

    private IntPtr RegisterSetting(Guid setting)
    {
        var registered = PowerNativeMethods.RegisterPowerSettingNotification(_windowHandle, ref setting, DeviceNotifyWindowHandle);
        if (registered == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), $"Could not subscribe to Windows power setting {setting}.");
        }

        return registered;
    }

    private IntPtr WindowProcedure(IntPtr window, uint message, nuint wParam, nint lParam)
    {
        if (message == WmPowerBroadcast)
        {
            var powerEvent = (uint)wParam;
            if (powerEvent == PbtPowerSettingChange)
            {
                if (lParam != 0)
                {
                    var setting = Marshal.PtrToStructure<PowerNativeMethods.PowerBroadcastSettingHeader>(lParam).PowerSetting;
                    if (setting == AcDcPowerSourceSetting || setting == PowerSavingStatusSetting)
                    {
                        Refresh();
                    }
                }

                return new IntPtr(1);
            }

            if (powerEvent == PbtApmSuspend)
            {
                Suspending?.Invoke(this, EventArgs.Empty);
                return new IntPtr(1);
            }

            if (powerEvent is PbtApmResumeCritical or PbtApmResumeSuspend or PbtApmResumeAutomatic)
            {
                Refresh();
                Resumed?.Invoke(this, EventArgs.Empty);
                return new IntPtr(1);
            }
        }

        if (message == WmClose)
        {
            WindowNativeMethods.DestroyWindow(window);
            return IntPtr.Zero;
        }

        if (message == WmDestroy)
        {
            WindowNativeMethods.PostQuitMessage(0);
            return IntPtr.Zero;
        }

        if (message == WmNcDestroy)
        {
            _windowHandle = IntPtr.Zero;
        }

        return WindowNativeMethods.DefWindowProc(window, message, wParam, lParam);
    }

    private void Refresh()
    {
        var succeeded = PowerNativeMethods.GetSystemPowerStatus(out var status);
        var isOnAc = succeeded && status.AcLineStatus == 1;
        // If status cannot be read, fail closed for image embedding.
        var isBatterySaverOn = !succeeded || (status.SystemStatusFlag & 0x01) != 0;
        var changed = false;
        lock (_sync)
        {
            var next = new PowerSnapshot(isOnAc, isBatterySaverOn);
            changed = _power != next;
            _power = next;
        }

        if (changed)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_windowHandle != IntPtr.Zero)
        {
            WindowNativeMethods.PostMessage(_windowHandle, WmClose, 0, 0);
            _thread.Join();
        }

        _ready.Dispose();
        GC.KeepAlive(_windowProcedure);
    }
}

internal static partial class PowerNativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct SystemPowerStatus
    {
        public byte AcLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PowerBroadcastSettingHeader
    {
        public Guid PowerSetting;
        public uint DataLength;
    }

    [LibraryImport("user32.dll", EntryPoint = "RegisterPowerSettingNotification", SetLastError = true)]
    internal static partial IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "UnregisterPowerSettingNotification", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterPowerSettingNotification(IntPtr notification);

    [LibraryImport("kernel32.dll", EntryPoint = "GetSystemPowerStatus", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetSystemPowerStatus(out SystemPowerStatus status);
}
