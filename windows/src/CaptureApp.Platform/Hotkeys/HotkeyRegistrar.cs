using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;
using CaptureApp.Platform.Interop;

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
    // Native ids: built-ins are action + 1, folder shortcuts 1024 up to the temporary probe id.
    private const int FirstCustomId = 1024;
    private const int ErrorInvalidParameter = 87;

    private readonly ConcurrentQueue<Action> _work = new();
    private readonly ManualResetEventSlim _ready = new();
    private readonly Thread _thread;
    private readonly WindowNativeMethods.WindowProcedure _windowProcedure;
    private readonly Dictionary<int, Action> _callbacks = [];
    private readonly Dictionary<HotkeyAction, int> _registeredIds = [];
    private readonly Dictionary<Guid, int> _customIds = [];
    private IntPtr _windowHandle;
    private string? _className;
    private Exception? _startupFailure;
    private bool _disposed;

    private static int BuiltInId(HotkeyAction action) => (int)action + 1;

    private int NextCustomId() => Enumerable.Range(FirstCustomId, TemporaryId - FirstCustomId).FirstOrDefault(candidate => !_callbacks.ContainsKey(candidate));

    private bool RegisterNative(int id, KeyChord chord) => HotkeyNativeMethods.RegisterHotKey(_windowHandle, id, (uint)chord.Modifiers | (uint)HotkeyModifiers.NoRepeat, (uint)chord.VirtualKey);

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
            var nativeId = NextCustomId();
            if (nativeId == 0) { return new HotkeyRegistrationResult(null, chord, false, ErrorInvalidParameter, "Too many registered shortcuts."); }
            if (!RegisterNative(nativeId, chord))
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
            if (!RegisterNative(TemporaryId, chord))
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
            UnregisterAllCore();
            return true;
        });
    }

    private void UnregisterAllCore()
    {
        foreach (var id in _registeredIds.Values.Concat(_customIds.Values))
        {
            HotkeyNativeMethods.UnregisterHotKey(_windowHandle, id);
            _callbacks.Remove(id);
        }

        _registeredIds.Clear();
        _customIds.Clear();
    }

    private HotkeyRegistrationResult RegisterCore(HotkeyAction action, KeyChord chord, Action callback)
    {
        if (_registeredIds.TryGetValue(action, out var previousId))
        {
            HotkeyNativeMethods.UnregisterHotKey(_windowHandle, previousId);
            _registeredIds.Remove(action);
            _callbacks.Remove(previousId);
        }

        var id = BuiltInId(action);
        if (!RegisterNative(id, chord))
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

        if (!WindowNativeMethods.PostMessage(_windowHandle, WmAppDispatch, 0, 0))
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
                var windowClass = new WindowNativeMethods.WindowClassEx
                {
                    Size = (uint)Marshal.SizeOf<WindowNativeMethods.WindowClassEx>(),
                    WindowProcedure = Marshal.GetFunctionPointerForDelegate(_windowProcedure),
                    Instance = WindowNativeMethods.GetModuleHandle(null),
                    ClassName = classNamePointer
                };
                if (WindowNativeMethods.RegisterClassEx(ref windowClass) == 0)
                {
                    throw new Win32Exception(Marshal.GetLastPInvokeError(), "RegisterClassEx failed.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(classNamePointer);
            }

            _windowHandle = WindowNativeMethods.CreateWindowEx(
                0, _className, null, 0, 0, 0, 0, 0, new IntPtr(HwndMessage), IntPtr.Zero,
                WindowNativeMethods.GetModuleHandle(null), IntPtr.Zero);
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
            var result = WindowNativeMethods.GetMessage(out var message, IntPtr.Zero, 0, 0);
            if (result == 0)
            {
                break;
            }

            if (result == -1)
            {
                break;
            }

            WindowNativeMethods.TranslateMessage(ref message);
            WindowNativeMethods.DispatchMessage(ref message);
        }

        if (_className is not null)
        {
            WindowNativeMethods.UnregisterClass(_className, WindowNativeMethods.GetModuleHandle(null));
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
                SafeWndProc.Invoke(CallbackFailed, exception);
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
            WindowNativeMethods.PostQuitMessage(0);
            return IntPtr.Zero;
        }

        if (message == WmNcDestroy)
        {
            _windowHandle = IntPtr.Zero;
        }

        return WindowNativeMethods.DefWindowProc(window, message, wParam, lParam);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        InvokeOnThread(() =>
        {
            UnregisterAllCore();
            _callbacks.Clear();
            WindowNativeMethods.DestroyWindow(_windowHandle);
            return true;
        });
        _disposed = true;
        _thread.Join();
        _ready.Dispose();
    }
}

internal static partial class HotkeyNativeMethods
{
    [LibraryImport("user32.dll", EntryPoint = "RegisterHotKey", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

    [LibraryImport("user32.dll", EntryPoint = "UnregisterHotKey", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterHotKey(IntPtr window, int id);
}
