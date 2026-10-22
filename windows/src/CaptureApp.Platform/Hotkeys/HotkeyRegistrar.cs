using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace CaptureApp.Platform.Hotkeys;

public sealed record HotkeyRegistrationResult(
    HotkeyAction? Action,
    KeyChord Chord,
    bool Succeeded,
    int Win32Error,
    string? ValidationError = null);

/// <summary>Owns a message-only window and registers global shortcuts on its message-pump thread.</summary>
public sealed class HotkeyRegistrar : IDisposable
{
    private const uint WmHotkey = 0x0312;
    private const uint WmAppDispatch = 0x8001;
    private const uint WmDestroy = 0x0002;
    private const uint WmNcDestroy = 0x0082;
    private const int HwndMessage = -3;
    private const int TemporaryId = 0x7FFF;
    private const int ErrorInvalidParameter = 87;

    private readonly ConcurrentQueue<Action> _work = new();
    private readonly ManualResetEventSlim _ready = new();
    private readonly Thread _thread;
    private readonly HotkeyNativeMethods.WindowProcedure _windowProcedure;
    private readonly Dictionary<int, Action> _callbacks = [];
    private readonly Dictionary<HotkeyAction, int> _registeredIds = [];
    private readonly Dictionary<Guid, int> _customIds = [];
    private IntPtr _windowHandle;
    private string? _className;
    private Exception? _startupFailure;
    private bool _disposed;

    public HotkeyRegistrar()
    {
        _windowProcedure = WindowProcedure;
        _thread = new Thread(MessageLoop)
        {
            IsBackground = true,
            Name = "Global hotkey registrations"
        };
        _thread.Start();
        _ready.Wait();
        if (_startupFailure is not null)
        {
            _thread.Join();
            throw new InvalidOperationException("Could not create the hotkey message window.", _startupFailure);
        }
    }

    /// <summary>Raised on the hotkey message-pump thread if a registered callback throws.</summary>
    public event Action<Exception>? CallbackFailed;

    public HotkeyRegistrationResult Register(HotkeyAction action, KeyChord chord, Action callback)
    {
        ArgumentNullException.ThrowIfNull(callback);
        var validation = HotkeyValidator.Validate(chord);
        if (!validation.IsValid)
        {
            return new(action, chord, false, ErrorInvalidParameter, validation.Error);
        }

        return InvokeOnThread(() => RegisterCore(action, chord, callback));
    }

    /// <summary>Registers a folder binding independently of the fixed built-in action identities.</summary>
    public HotkeyRegistrationResult Register(Guid id, KeyChord chord, Action callback)
    {
        ArgumentNullException.ThrowIfNull(callback);
        var validation = HotkeyValidator.Validate(chord);
        if (id == Guid.Empty || !validation.IsValid)
            return new(null, chord, false, ErrorInvalidParameter, validation.Error ?? "A shortcut identity is required.");
        return InvokeOnThread(() =>
        {
            if (_customIds.TryGetValue(id, out var previous))
            {
                HotkeyNativeMethods.UnregisterHotKey(_windowHandle, previous);
                _customIds.Remove(id);
                _callbacks.Remove(previous);
            }
            // Built-ins use low enum IDs; the temporary availability probe uses 0x7FFF.
            var nativeId = Enumerable.Range(1024, TemporaryId - 1024).FirstOrDefault(candidate => !_callbacks.ContainsKey(candidate));
            if (nativeId == 0) { return new HotkeyRegistrationResult(null, chord, false, ErrorInvalidParameter, "Too many registered shortcuts."); }
            if (!HotkeyNativeMethods.RegisterHotKey(_windowHandle, nativeId,
                    (uint)chord.Modifiers | (uint)HotkeyModifiers.NoRepeat, (uint)chord.VirtualKey))
                return new HotkeyRegistrationResult(null, chord, false, Marshal.GetLastPInvokeError());
            _customIds[id] = nativeId;
            _callbacks[nativeId] = callback;
            return new HotkeyRegistrationResult(null, chord, true, 0);
        });
    }

    public bool IsRegistered(Guid id) => InvokeOnThread(() => _customIds.ContainsKey(id));

    public void Unregister(Guid id) => InvokeOnThread(() =>
    {
        if (_customIds.Remove(id, out var nativeId))
        {
            HotkeyNativeMethods.UnregisterHotKey(_windowHandle, nativeId);
            _callbacks.Remove(nativeId);
        }
        return true;
    });

    /// <summary>Temporarily tries a chord and unregisters it immediately when available.</summary>
    public HotkeyRegistrationResult TestRegisterTemporarily(KeyChord chord)
    {
        var validation = HotkeyValidator.Validate(chord);
        if (!validation.IsValid)
        {
            return new(null, chord, false, ErrorInvalidParameter, validation.Error);
        }

        return InvokeOnThread(() =>
        {
            if (!HotkeyNativeMethods.RegisterHotKey(_windowHandle, TemporaryId, (uint)chord.Modifiers | (uint)HotkeyModifiers.NoRepeat, (uint)chord.VirtualKey))
            {
                return new HotkeyRegistrationResult(null, chord, false, Marshal.GetLastPInvokeError());
            }

            HotkeyNativeMethods.UnregisterHotKey(_windowHandle, TemporaryId);
            return new HotkeyRegistrationResult(null, chord, true, 0);
        });
    }

    public void Unregister(HotkeyAction action)
    {
        InvokeOnThread(() =>
        {
            if (_registeredIds.Remove(action, out var id))
            {
                HotkeyNativeMethods.UnregisterHotKey(_windowHandle, id);
                _callbacks.Remove(id);
            }

            return true;
        });
    }

    public void UnregisterAll()
    {
        InvokeOnThread(() =>
        {
            foreach (var id in _registeredIds.Values.Concat(_customIds.Values))
            {
                HotkeyNativeMethods.UnregisterHotKey(_windowHandle, id);
                _callbacks.Remove(id);
            }

            _registeredIds.Clear();
            _customIds.Clear();
            return true;
        });
    }

    private HotkeyRegistrationResult RegisterCore(HotkeyAction action, KeyChord chord, Action callback)
    {
        if (_registeredIds.TryGetValue(action, out var previousId))
        {
            HotkeyNativeMethods.UnregisterHotKey(_windowHandle, previousId);
            _registeredIds.Remove(action);
            _callbacks.Remove(previousId);
        }

        var id = (int)action + 1;
        if (!HotkeyNativeMethods.RegisterHotKey(_windowHandle, id, (uint)chord.Modifiers | (uint)HotkeyModifiers.NoRepeat, (uint)chord.VirtualKey))
        {
            return new(action, chord, false, Marshal.GetLastPInvokeError());
        }

        _registeredIds[action] = id;
        _callbacks[id] = callback;
        return new(action, chord, true, 0);
    }

    private T InvokeOnThread<T>(Func<T> operation)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (Environment.CurrentManagedThreadId == _thread.ManagedThreadId)
        {
            return operation();
        }

        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        _work.Enqueue(() =>
        {
            try
            {
                completion.SetResult(operation());
            }
            catch (Exception exception)
            {
                completion.SetException(exception);
            }
        });

        if (!HotkeyNativeMethods.PostMessage(_windowHandle, WmAppDispatch, 0, 0))
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not dispatch work to the hotkey thread.");
        }

        return completion.Task.GetAwaiter().GetResult();
    }

    private void MessageLoop()
    {
        try
        {
            _className = $"GlobalHotkeyWindow.{Guid.NewGuid():N}";
            var classNamePointer = Marshal.StringToHGlobalUni(_className);
            try
            {
                var windowClass = new HotkeyNativeMethods.WindowClassEx
                {
                    Size = (uint)Marshal.SizeOf<HotkeyNativeMethods.WindowClassEx>(),
                    WindowProcedure = Marshal.GetFunctionPointerForDelegate(_windowProcedure),
                    Instance = HotkeyNativeMethods.GetModuleHandle(null),
                    ClassName = classNamePointer
                };
                if (HotkeyNativeMethods.RegisterClassEx(ref windowClass) == 0)
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError(), "RegisterClassEx failed.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(classNamePointer);
            }

            _windowHandle = HotkeyNativeMethods.CreateWindowEx(
                0, _className, null, 0, 0, 0, 0, 0, new IntPtr(HwndMessage), IntPtr.Zero,
                HotkeyNativeMethods.GetModuleHandle(null), IntPtr.Zero);
            if (_windowHandle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "CreateWindowEx failed.");
            }
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
            var result = HotkeyNativeMethods.GetMessage(out var message, IntPtr.Zero, 0, 0);
            if (result == 0)
            {
                break;
            }

            if (result == -1)
            {
                break;
            }

            HotkeyNativeMethods.TranslateMessage(ref message);
            HotkeyNativeMethods.DispatchMessage(ref message);
        }

        if (_className is not null)
        {
            HotkeyNativeMethods.UnregisterClass(_className, HotkeyNativeMethods.GetModuleHandle(null));
        }
    }

    private IntPtr WindowProcedure(IntPtr window, uint message, nuint wParam, nint lParam)
    {
        if (message == WmHotkey && _callbacks.TryGetValue((int)wParam, out var callback))
        {
            try
            {
                callback();
            }
            catch (Exception exception)
            {
                try
                {
                    CallbackFailed?.Invoke(exception);
                }
                catch
                {
                    // User event handlers must not unwind through the unmanaged window procedure.
                }
            }

            return IntPtr.Zero;
        }

        if (message == WmAppDispatch)
        {
            while (_work.TryDequeue(out var action))
            {
                action();
            }

            return IntPtr.Zero;
        }

        if (message == WmDestroy)
        {
            HotkeyNativeMethods.PostQuitMessage(0);
            return IntPtr.Zero;
        }

        if (message == WmNcDestroy)
        {
            _windowHandle = IntPtr.Zero;
        }

        return HotkeyNativeMethods.DefWindowProc(window, message, wParam, lParam);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        InvokeOnThread(() =>
        {
            foreach (var id in _registeredIds.Values.Concat(_customIds.Values))
            {
                HotkeyNativeMethods.UnregisterHotKey(_windowHandle, id);
            }

            _registeredIds.Clear();
            _customIds.Clear();
            _callbacks.Clear();
            HotkeyNativeMethods.DestroyWindow(_windowHandle);
            return true;
        });
        _disposed = true;
        _thread.Join();
        _ready.Dispose();
    }
}

internal static partial class HotkeyNativeMethods
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

    [LibraryImport("user32.dll", EntryPoint = "RegisterHotKey", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

    [LibraryImport("user32.dll", EntryPoint = "UnregisterHotKey", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterHotKey(IntPtr window, int id);

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

    [LibraryImport("user32.dll", EntryPoint = "PostQuitMessage")]
    internal static partial void PostQuitMessage(int exitCode);

    [LibraryImport("user32.dll", EntryPoint = "DestroyWindow", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyWindow(IntPtr window);

    [LibraryImport("user32.dll", EntryPoint = "UnregisterClassW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterClass(string className, IntPtr instance);

    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial IntPtr GetModuleHandle(string? moduleName);
}
