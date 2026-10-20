using System.ComponentModel;
using System.Runtime.InteropServices;
using CaptureApp.Core;
using Microsoft.Win32;

namespace CaptureApp.Platform.Tray;

/// <summary>Native Shell_NotifyIcon host that can live on the App's UI thread without a WinForms project reference.</summary>
public sealed class TrayIcon : IDisposable
{
    private const uint NimAdd = 0x00000000;
    private const uint NimModify = 0x00000001;
    private const uint NimDelete = 0x00000002;
    private const uint NimSetVersion = 0x00000004;
    private const uint NifMessage = 0x00000001;
    private const uint NifIcon = 0x00000002;
    private const uint NifTip = 0x00000004;
    private const uint WmSettingChange = 0x001A;
    private const uint WmSysColorChange = 0x0015;
    private const uint WmThemeChanged = 0x031A;
    private const uint WmContextMenu = 0x007B;
    private const uint WmRButtonUp = 0x0205;
    private const uint WmLButtonUp = 0x0202;
    private const uint WmCancelMode = 0x001F;
    private const uint WmNull = 0x0000;
    private const uint WmAppNotifyIcon = 0x8002;
    private const uint NinSelect = 0x0400;
    private const uint NinKeySelect = 0x0401;
    private const uint TrayIconId = 1;
    private const uint TpmRightButton = 0x0002;
    private const uint TpmNoNotify = 0x0080;
    private const uint TpmReturnCommand = 0x0100;
    private const uint TpmNoAnimation = 0x4000;
    private const uint MfGray = 0x0001;
    private const uint MfChecked = 0x0008;
    private const uint MfPopup = 0x0010;
    private const uint MfSeparator = 0x0800;
    private const uint MfString = 0x0000;
    private const int ImageIcon = 1;
    private const uint LoadFromFile = 0x0010;
    private const uint LoadDefaultSize = 0x0040;
    private const uint DeviceIconApplication = 32512;

    private readonly Action<string> _onItemInvoked;
    private readonly TrayNativeMethods.WindowProcedure _windowProcedure;
    private readonly string _className = $"PlatformTrayOwner.{Guid.NewGuid():N}";
    private readonly IntPtr _instance;
    private readonly IntPtr _lightIcon;
    private readonly IntPtr _darkIcon;
    private readonly IntPtr _attentionLightIcon;
    private readonly IntPtr _attentionDarkIcon;
    private readonly bool _ownsLightIcon;
    private readonly bool _ownsDarkIcon;
    private readonly bool _ownsAttentionLightIcon;
    private readonly bool _ownsAttentionDarkIcon;
    private readonly uint _taskbarCreatedMessage;
    private readonly Func<TrayNativeMethods.Point?, bool>? _menuPresenterForTesting;
    private readonly Func<uint, bool>? _postTrackMessageForTesting;
    private IntPtr _windowHandle;
    private TrayMenuModel _menu = new(Array.Empty<TrayMenuItem>());
    private bool _registered;
    private bool _version4Callbacks;
    private bool _attention;
    private bool _disposed;
    private bool _showingMenu;

    public TrayIcon(Action<string> onItemInvoked, TrayIconAssets? assets = null)
        : this(onItemInvoked, assets, registerShellIcon: true, version4Callbacks: false, menuPresenterForTesting: null)
    {
    }

    internal TrayIcon(
        Action<string> onItemInvoked,
        TrayIconAssets? assets,
        bool registerShellIcon,
        bool version4Callbacks,
        Func<TrayNativeMethods.Point?, bool>? menuPresenterForTesting,
        Func<uint, bool>? postTrackMessageForTesting = null)
    {
        ArgumentNullException.ThrowIfNull(onItemInvoked);
        _onItemInvoked = onItemInvoked;
        _version4Callbacks = version4Callbacks;
        _menuPresenterForTesting = menuPresenterForTesting;
        _postTrackMessageForTesting = postTrackMessageForTesting;
        assets ??= TrayIconAssets.FindDefault();
        _windowProcedure = WindowProcedure;
        _instance = TrayNativeMethods.GetModuleHandle(null);
        _taskbarCreatedMessage = TrayNativeMethods.RegisterWindowMessage("TaskbarCreated");

        (_lightIcon, _ownsLightIcon) = LoadIcon(assets.Light);
        (_darkIcon, _ownsDarkIcon) = LoadIcon(assets.Dark);
        (_attentionLightIcon, _ownsAttentionLightIcon) = LoadIcon(assets.AttentionLight);
        (_attentionDarkIcon, _ownsAttentionDarkIcon) = LoadIcon(assets.AttentionDark);

        var classNamePointer = Marshal.StringToHGlobalUni(_className);
        try
        {
            var windowClass = new TrayNativeMethods.WindowClassEx
            {
                Size = (uint)Marshal.SizeOf<TrayNativeMethods.WindowClassEx>(),
                WindowProcedure = Marshal.GetFunctionPointerForDelegate(_windowProcedure),
                Instance = _instance,
                ClassName = classNamePointer
            };
            if (TrayNativeMethods.RegisterClassEx(ref windowClass) == 0)
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not register the tray owner window class.");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(classNamePointer);
        }

        _windowHandle = TrayNativeMethods.CreateWindowEx(0, _className, null, 0, 0, 0, 0, 0,
            IntPtr.Zero, IntPtr.Zero, _instance, IntPtr.Zero);
        if (_windowHandle == IntPtr.Zero)
        {
            TrayNativeMethods.UnregisterClass(_className, _instance);
            DestroyLoadedIcons();
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not create the hidden tray owner window.");
        }

        if (registerShellIcon)
        {
            AddIcon();
        }
    }

    public event Action<Exception>? MenuDispatchFailed;

    public TrayMenuModel Menu
    {
        get => _menu;
        set => _menu = value ?? throw new ArgumentNullException(nameof(value));
    }

    public bool IsRegistered => _registered;

    internal IntPtr NativeWindowHandleForTesting => _windowHandle;

    internal const uint NotifyCallbackMessageForTesting = WmAppNotifyIcon;

    public bool IsAttention => _attention;

    public void SetAttention(bool attention)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_attention == attention)
        {
            return;
        }

        _attention = attention;
        ModifyIcon();
    }

    /// <summary>Shows the current menu; false means Windows did not allow this window to take foreground ownership.</summary>
    public bool TryShowMenu()
        => TryShowMenu(position: null);

    private bool TryShowMenu(TrayNativeMethods.Point? position)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_showingMenu)
        {
            return true;
        }

        _showingMenu = true;
        try
        {
            return TryShowMenuCore(position);
        }
        finally
        {
            _showingMenu = false;
        }
    }

    private bool TryShowMenuCore(TrayNativeMethods.Point? position)
    {
        if (_menuPresenterForTesting is not null)
        {
            var shown = _menuPresenterForTesting(position);
            if (shown)
            {
                PostBenignMessageAfterTrackPopup();
            }

            return shown;
        }

        var foregrounded = TrayNativeMethods.SetForegroundWindow(_windowHandle);
        if (!foregrounded)
        {
            return false;
        }

        var commandIds = new Dictionary<uint, string>();
        var nextId = 100u;
        var root = BuildMenu(_menu.Items, commandIds, ref nextId);
        try
        {
            TrayNativeMethods.Point point;
            if (position is { } callbackPosition)
            {
                point = callbackPosition;
            }
            else if (!TrayNativeMethods.GetCursorPos(out point))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not read the pointer position for the tray menu.");
            }

            var selected = TrayNativeMethods.TrackPopupMenuEx(root,
                TpmRightButton | TpmNoNotify | TpmReturnCommand | TpmNoAnimation,
                point.X, point.Y, _windowHandle, IntPtr.Zero);
            if (commandIds.TryGetValue(selected, out var id))
            {
                DispatchItem(id);
            }

            // TrackPopupMenuEx requires a benign message to follow the menu loop. WM_CANCELMODE
            // can dismiss a subsequent menu if the queued message is dispatched after it opens.
            PostBenignMessageAfterTrackPopup();
            return true;
        }
        finally
        {
            TrayNativeMethods.DestroyMenu(root);
        }
    }

    private bool PostBenignMessageAfterTrackPopup()
        => _postTrackMessageForTesting is not null
            ? _postTrackMessageForTesting(WmNull)
            : TrayNativeMethods.PostMessage(_windowHandle, WmNull, 0, 0);

    /// <summary>Allows a host or interactive test to dismiss an open native menu.</summary>
    public void CancelCurrentMenu()
    {
        if (!_disposed)
        {
            TrayNativeMethods.PostMessage(_windowHandle, WmCancelMode, 0, 0);
        }
    }

    private void AddIcon()
    {
        _version4Callbacks = false;
        var data = CreateNotifyIconData(CurrentIcon());
        if (!CallShell(NimAdd, data))
        {
            _registered = false;
            return;
        }

        _registered = true;
        data.Version = 4;
        _version4Callbacks = CallShell(NimSetVersion, data);
    }

    private void ModifyIcon()
    {
        if (!_registered)
        {
            AddIcon();
            return;
        }

        var data = CreateNotifyIconData(CurrentIcon());
        if (!CallShell(NimModify, data))
        {
            _registered = false;
        }
    }

    private void RemoveIcon()
    {
        if (!_registered)
        {
            return;
        }

        CallShell(NimDelete, CreateNotifyIconData(CurrentIcon()));
        _registered = false;
    }

    private bool CallShell(uint operation, TrayNativeMethods.NotifyIconData data)
    {
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<TrayNativeMethods.NotifyIconData>());
        try
        {
            Marshal.StructureToPtr(data, pointer, fDeleteOld: false);
            return TrayNativeMethods.ShellNotifyIcon(operation, pointer);
        }
        finally
        {
            Marshal.DestroyStructure<TrayNativeMethods.NotifyIconData>(pointer);
            Marshal.FreeHGlobal(pointer);
        }
    }

    private TrayNativeMethods.NotifyIconData CreateNotifyIconData(IntPtr icon) => new()
    {
        Size = (uint)Marshal.SizeOf<TrayNativeMethods.NotifyIconData>(),
        Window = _windowHandle,
        Id = 1,
        Flags = NifIcon | NifMessage | NifTip,
        CallbackMessage = WmAppNotifyIcon,
        Icon = icon,
        Tip = AppInfo.Name
    };

    private IntPtr CurrentIcon() => IsLightTheme()
        ? (_attention ? _attentionLightIcon : _lightIcon)
        : (_attention ? _attentionDarkIcon : _darkIcon);

    private static bool IsLightTheme()
    {
        try
        {
            var value = Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1);
            return value is not int lightTheme || lightTheme != 0;
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
            return true;
        }
    }

    private (IntPtr Handle, bool Owned) LoadIcon(string path)
    {
        if (File.Exists(path))
        {
            var loaded = TrayNativeMethods.LoadImage(IntPtr.Zero, path, ImageIcon, 0, 0, LoadFromFile | LoadDefaultSize);
            if (loaded != IntPtr.Zero)
            {
                return (loaded, true);
            }
        }

        return (TrayNativeMethods.LoadIcon(IntPtr.Zero, new IntPtr(DeviceIconApplication)), false);
    }

    private IntPtr BuildMenu(IReadOnlyList<TrayMenuItem> items, Dictionary<uint, string> commandIds, ref uint nextId)
    {
        var menu = TrayNativeMethods.CreatePopupMenu();
        if (menu == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not create a tray popup menu.");
        }

        foreach (var item in items)
        {
            if (item.IsSeparator)
            {
                AppendMenu(menu, MfSeparator, 0, null);
                continue;
            }

            var title = string.IsNullOrWhiteSpace(item.ShortcutText) ? item.Title : $"{item.Title}\t{item.ShortcutText}";
            if (item.Children is { Count: > 0 })
            {
                var childMenu = BuildMenu(item.Children, commandIds, ref nextId);
                AppendMenu(menu, MfPopup | MfString | (item.Enabled ? 0u : MfGray), (nuint)childMenu, title);
                continue;
            }

            var flags = MfString | (item.Enabled ? 0u : MfGray) | (item.Checked ? MfChecked : 0u);
            var id = nextId++;
            commandIds.Add(id, item.Id);
            AppendMenu(menu, flags, id, title);
        }

        return menu;
    }

    private static void AppendMenu(IntPtr menu, uint flags, nuint idOrSubmenu, string? title)
    {
        if (!TrayNativeMethods.AppendMenu(menu, flags, idOrSubmenu, title))
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not add an item to the tray menu.");
        }
    }

    private void DispatchItem(string id)
    {
        try
        {
            _onItemInvoked(id);
        }
        catch (Exception exception)
        {
            try
            {
                MenuDispatchFailed?.Invoke(exception);
            }
            catch
            {
                // User event handlers must not unwind through the unmanaged window procedure.
            }
        }
    }

    private IntPtr WindowProcedure(IntPtr window, uint message, nuint wParam, nint lParam)
    {
        if (message == _taskbarCreatedMessage)
        {
            _registered = false;
            AddIcon();
            return IntPtr.Zero;
        }

        if (message is WmSettingChange or WmSysColorChange or WmThemeChanged)
        {
            ModifyIcon();
            return IntPtr.Zero;
        }

        if (message == WmAppNotifyIcon)
        {
            var decoded = TryDecodeCallback(wParam, lParam, out var eventId, out var position);
            // Version 4 delivers a semantic activation after the corresponding mouse-up.
            // Opening on both reenters TrackPopupMenuEx while its first menu loop is active.
            var activation = decoded &&
                (eventId is WmContextMenu or NinSelect or NinKeySelect ||
                 (!_version4Callbacks && eventId is WmRButtonUp or WmLButtonUp));
            if (activation)
            {
                try
                {
                    if (!TryShowMenu(position) && _menuPresenterForTesting is null)
                    {
                        DispatchMenuFailure(new InvalidOperationException(
                            "Windows did not allow the tray menu to take foreground ownership."));
                    }
                }
                catch (Exception exception)
                {
                    DispatchMenuFailure(exception);
                }
            }

            return IntPtr.Zero;
        }

        return TrayNativeMethods.DefWindowProc(window, message, wParam, lParam);
    }

    private bool TryDecodeCallback(
        nuint wParam,
        nint lParam,
        out uint eventId,
        out TrayNativeMethods.Point? position)
    {
        if (_version4Callbacks)
        {
            var packed = unchecked((uint)lParam);
            var iconId = packed >> 16;
            eventId = packed & 0xFFFF;
            if (iconId != TrayIconId)
            {
                position = null;
                return false;
            }

            var x = unchecked((short)(wParam & 0xFFFF));
            var y = unchecked((short)((wParam >> 16) & 0xFFFF));
            position = x == -1 && y == -1 ? null : new TrayNativeMethods.Point { X = x, Y = y };
            return true;
        }

        eventId = unchecked((uint)lParam);
        position = null;
        return unchecked((uint)wParam) == TrayIconId;
    }

    private void DispatchMenuFailure(Exception exception)
    {
        try
        {
            MenuDispatchFailed?.Invoke(exception);
        }
        catch
        {
            // User event handlers must not unwind through the unmanaged window procedure.
        }
    }

    private void DestroyLoadedIcons()
    {
        if (_ownsLightIcon) TrayNativeMethods.DestroyIcon(_lightIcon);
        if (_ownsDarkIcon) TrayNativeMethods.DestroyIcon(_darkIcon);
        if (_ownsAttentionLightIcon) TrayNativeMethods.DestroyIcon(_attentionLightIcon);
        if (_ownsAttentionDarkIcon) TrayNativeMethods.DestroyIcon(_attentionDarkIcon);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        RemoveIcon();
        if (_windowHandle != IntPtr.Zero)
        {
            TrayNativeMethods.DestroyWindow(_windowHandle);
            _windowHandle = IntPtr.Zero;
        }

        TrayNativeMethods.UnregisterClass(_className, _instance);
        DestroyLoadedIcons();
        _disposed = true;
        GC.KeepAlive(_windowProcedure);
    }
}

internal static partial class TrayNativeMethods
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct NotifyIconData
    {
        public uint Size;
        public IntPtr Window;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string? Tip;
        public uint State;
        public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string? Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string? InfoTitle;
        public uint InfoFlags;
        public Guid GuidItem;
        public IntPtr BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Point
    {
        public int X;
        public int Y;
    }

    [LibraryImport("user32.dll", EntryPoint = "RegisterClassExW", SetLastError = true)]
    internal static partial ushort RegisterClassEx(ref WindowClassEx windowClass);

    [LibraryImport("user32.dll", EntryPoint = "CreateWindowExW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    internal static partial IntPtr CreateWindowEx(uint extendedStyle, string className, string? windowName, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);

    [LibraryImport("user32.dll", EntryPoint = "DefWindowProcW")]
    internal static partial IntPtr DefWindowProc(IntPtr window, uint message, nuint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "SendMessageW")]
    internal static partial nint SendMessage(IntPtr window, uint message, nuint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "RegisterWindowMessageW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    internal static partial uint RegisterWindowMessage(string message);

    [LibraryImport("user32.dll", EntryPoint = "SetForegroundWindow", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetForegroundWindow(IntPtr window);

    [LibraryImport("user32.dll", EntryPoint = "GetCursorPos", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetCursorPos(out Point point);

    [LibraryImport("user32.dll", EntryPoint = "TrackPopupMenuEx", SetLastError = true)]
    internal static partial uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);

    [LibraryImport("user32.dll", EntryPoint = "CreatePopupMenu", SetLastError = true)]
    internal static partial IntPtr CreatePopupMenu();

    [LibraryImport("user32.dll", EntryPoint = "DestroyMenu", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyMenu(IntPtr menu);

    [LibraryImport("user32.dll", EntryPoint = "AppendMenuW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool AppendMenu(IntPtr menu, uint flags, nuint itemIdOrSubmenu, string? newItem);

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool PostMessage(IntPtr window, uint message, nuint wParam, nint lParam);

    [LibraryImport("user32.dll", EntryPoint = "DestroyWindow", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyWindow(IntPtr window);

    [LibraryImport("user32.dll", EntryPoint = "UnregisterClassW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterClass(string className, IntPtr instance);

    [LibraryImport("user32.dll", EntryPoint = "LoadImageW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    internal static partial IntPtr LoadImage(IntPtr instance, string fileName, int imageType, int width, int height, uint loadOptions);

    [LibraryImport("user32.dll", EntryPoint = "LoadIconW", SetLastError = true)]
    internal static partial IntPtr LoadIcon(IntPtr instance, IntPtr resourceName);

    [LibraryImport("user32.dll", EntryPoint = "DestroyIcon", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyIcon(IntPtr icon);

    [LibraryImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ShellNotifyIcon(uint operation, IntPtr data);

    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial IntPtr GetModuleHandle(string? moduleName);
}
