using System.ComponentModel;
using System.Runtime.InteropServices;

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
    private readonly PowerNativeMethods.WindowProcedure _windowProcedure;
    private readonly string _className = $"PlatformPowerMonitorWindow.{Guid.NewGuid():N}";
    private IntPtr _windowHandle;
    private IntPtr _acNotification;
    private IntPtr _batterySaverNotification;
    private Exception? _startupFailure;
    private bool _isOnAc;
    private bool _isBatterySaverOn = true;
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
        get { lock (_sync) return _isOnAc; }
    }

    public bool IsBatterySaverOn
    {
        get { lock (_sync) return _isBatterySaverOn; }
    }

    public event EventHandler? Changed;

    public event EventHandler? Suspending;

    public event EventHandler? Resumed;

    private void MessageLoop()
    {
        try
        {
            var instance = PowerNativeMethods.GetModuleHandle(null);
            var classNamePointer = Marshal.StringToHGlobalUni(_className);
            try
            {
                var windowClass = new PowerNativeMethods.WindowClassEx
                {
                    Size = (uint)Marshal.SizeOf<PowerNativeMethods.WindowClassEx>(),
                    WindowProcedure = Marshal.GetFunctionPointerForDelegate(_windowProcedure),
                    Instance = instance,
                    ClassName = classNamePointer
                };
                if (PowerNativeMethods.RegisterClassEx(ref windowClass) == 0)
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError(), "RegisterClassEx failed for the power monitor.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(classNamePointer);
            }

            _windowHandle = PowerNativeMethods.CreateWindowEx(0, _className, null, 0, 0, 0, 0, 0,
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
            var result = PowerNativeMethods.GetMessage(out var message, IntPtr.Zero, 0, 0);
            if (result <= 0)
            {
                break;
            }

            PowerNativeMethods.TranslateMessage(ref message);
            PowerNativeMethods.DispatchMessage(ref message);
        }

        if (_acNotification != IntPtr.Zero) PowerNativeMethods.UnregisterPowerSettingNotification(_acNotification);
        if (_batterySaverNotification != IntPtr.Zero) PowerNativeMethods.UnregisterPowerSettingNotification(_batterySaverNotification);
        PowerNativeMethods.UnregisterClass(_className, PowerNativeMethods.GetModuleHandle(null));
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
            PowerNativeMethods.DestroyWindow(window);
            return IntPtr.Zero;
        }

        if (message == WmDestroy)
        {
            PowerNativeMethods.PostQuitMessage(0);
            return IntPtr.Zero;
        }

        if (message == WmNcDestroy)
        {
            _windowHandle = IntPtr.Zero;
        }

        return PowerNativeMethods.DefWindowProc(window, message, wParam, lParam);
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
            changed = _isOnAc != isOnAc || _isBatterySaverOn != isBatterySaverOn;
            _isOnAc = isOnAc;
            _isBatterySaverOn = isBatterySaverOn;
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
            PowerNativeMethods.PostMessage(_windowHandle, WmClose, 0, 0);
            _thread.Join();
        }

        _ready.Dispose();
        GC.KeepAlive(_windowProcedure);
    }
}

internal static partial class PowerNativeMethods
{
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    internal delegate IntPtr WindowProcedure(IntPtr window, uint message, nuint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    internal struct WindowClassEx
    {
        public uint Size;
        public uint Style;
        public IntPtr WindowProcedure;
        public int ClassExtra;
        public int WindowExtra;
        public IntPtr Instance;
        public IntPtr Icon;
        public IntPtr Cursor;
        public IntPtr Background;
        public IntPtr MenuName;
        public IntPtr ClassName;
        public IntPtr SmallIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Message
    {
        public IntPtr Window;
        public uint Id;
        public nuint WParam;
        public nint LParam;
        public uint Time;
        public int PointX;
        public int PointY;
        public uint Private;
    }

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

    [LibraryImport("user32.dll", EntryPoint = "RegisterClassExW", SetLastError = true)]
    internal static partial ushort RegisterClassEx(ref WindowClassEx windowClass);

    [LibraryImport("user32.dll", EntryPoint = "CreateWindowExW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    internal static partial IntPtr CreateWindowEx(uint extendedStyle, string className, string? windowName, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);

    [LibraryImport("user32.dll", EntryPoint = "DefWindowProcW")]
    internal static partial IntPtr DefWindowProc(IntPtr window, uint message, nuint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "GetMessageW", SetLastError = true)]
    internal static partial int GetMessage(out Message message, IntPtr window, uint minimum, uint maximum);

    [LibraryImport("user32.dll", EntryPoint = "TranslateMessage")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool TranslateMessage(ref Message message);

    [LibraryImport("user32.dll", EntryPoint = "DispatchMessageW")]
    internal static partial IntPtr DispatchMessage(ref Message message);

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool PostMessage(IntPtr window, uint message, nuint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "DestroyWindow", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyWindow(IntPtr window);

    [LibraryImport("user32.dll", EntryPoint = "RegisterPowerSettingNotification", SetLastError = true)]
    internal static partial IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "UnregisterPowerSettingNotification", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterPowerSettingNotification(IntPtr notification);

    [LibraryImport("user32.dll", EntryPoint = "UnregisterClassW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterClass(string className, IntPtr instance);

    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial IntPtr GetModuleHandle(string? moduleName);

    [LibraryImport("kernel32.dll", EntryPoint = "GetSystemPowerStatus", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetSystemPowerStatus(out SystemPowerStatus status);

    [LibraryImport("user32.dll", EntryPoint = "PostQuitMessage")]
    internal static partial void PostQuitMessage(int exitCode);
}
