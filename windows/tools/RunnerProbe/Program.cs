using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using Forms = System.Windows.Forms;

namespace CaptureApp.RunnerProbe;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        Console.WriteLine("| Capability | Result | Detail |");
        Console.WriteLine("| --- | --- | --- |");
        try
        {
            Forms.Application.SetHighDpiMode(Forms.HighDpiMode.PerMonitorV2);
            Forms.Application.EnableVisualStyles();
            Forms.Application.SetCompatibleTextRenderingDefault(false);
            using var form = new ProbeWindow();
            Forms.Application.Run(form);
        }
        catch (Exception error)
        {
            Report("Probe startup", false, error.Message);
        }

        return 0;
    }

    internal static void Report(string capability, bool passed, string detail)
    {
        static string Escape(string text) => text.Replace("|", "\\|", StringComparison.Ordinal)
            .Replace("\r", " ", StringComparison.Ordinal).Replace("\n", " ", StringComparison.Ordinal);
        Console.WriteLine($"| {Escape(capability)} | {(passed ? "PASS" : "FAIL")} | {Escape(detail)} |");
    }
}

internal sealed class ProbeWindow : Forms.Form
{
    private const string SelectedText = "selected probe text";
    private readonly Forms.TextBox textBox = new()
    {
        Multiline = true,
        Dock = Forms.DockStyle.Fill,
        Text = SelectedText,
        AccessibleName = "Runner probe selection"
    };
    private TaskCompletionSource<bool>? hotKey;

    internal ProbeWindow()
    {
        Text = "Runner capability probe";
        Width = 480;
        Height = 180;
        Controls.Add(textBox);
        Shown += RunProbes;
    }

    protected override void WndProc(ref Forms.Message message)
    {
        if (message.Msg == 0x0312 && message.WParam == 1)
        {
            hotKey?.TrySetResult(true);
        }

        base.WndProc(ref message);
    }

    private async void RunProbes(object? sender, EventArgs args)
    {
        try
        {
            await Probe("RegisterHotKey / WM_HOTKEY", async () =>
            {
                hotKey = new(TaskCreationOptions.RunContinuationsAsynchronously);
                if (!Native.RegisterHotKey(Handle, 1, 0x4000 | 0x0001 | 0x0004, 0x51))
                {
                    return (false, $"RegisterHotKey error {Marshal.GetLastWin32Error()}");
                }

                try
                {
                    var sent = Native.SendCombo(0x51, 0x12, 0x10);
                    var completed = await Task.WhenAny(hotKey.Task, Task.Delay(TimeSpan.FromSeconds(2)));
                    return (sent && completed == hotKey.Task,
                        $"Alt+Shift+Q; SendInput={sent}; WM_HOTKEY={hotKey.Task.IsCompletedSuccessfully} within 2 s");
                }
                finally
                {
                    Native.UnregisterHotKey(Handle, 1);
                }
            });

            await Probe("SetForegroundWindow", async () =>
            {
                var accepted = Native.SetForegroundWindow(Handle);
                var matches = await Until(() => Native.GetForegroundWindow() == Handle);
                return (matches, $"API return={accepted}; own HWND foreground={matches}");
            });

            textBox.Focus();
            textBox.SelectAll();
            // UIA calls run on an MTA worker while the owner STA continues pumping messages.
            await Probe("UIA GetFocusedElement", () => Task.Run(() =>
            {
                var focused = AutomationElement.FocusedElement;
                var matches = focused is not null && focused.Current.ProcessId == Environment.ProcessId &&
                    focused.Current.NativeWindowHandle == textBoxHandle;
                return (matches, $"Focused element is owned TextBox={matches}");
            }));

            await Probe("UIA TextPattern.GetSelection", () => Task.Run(() =>
            {
                var focused = AutomationElement.FocusedElement;
                if (focused is null || focused.Current.NativeWindowHandle != textBoxHandle ||
                    !focused.TryGetCurrentPattern(TextPattern.Pattern, out var value))
                {
                    return (false, "Owned focused TextBox did not expose TextPattern");
                }

                var selected = string.Concat(((TextPattern)value).GetSelection().Select(range => range.GetText(-1)));
                return (selected == SelectedText, $"Selected text matches={selected == SelectedText}");
            }));

            await Probe("SendInput Ctrl+C", async () =>
            {
                Native.WriteClipboard(Handle, "clipboard sentinel");
                textBox.Focus();
                textBox.SelectAll();
                var sent = Native.SendCombo(0x43, 0x11);
                var copied = await Until(() => Native.ReadClipboard(Handle) == SelectedText);
                return (sent && copied, $"SendInput={sent}; clipboard contains selected text={copied}");
            });

            await Probe("Clipboard round trip / sequence", () =>
            {
                var before = Native.GetClipboardSequenceNumber();
                const string value = "clipboard round trip é 😀";
                Native.WriteClipboard(Handle, value);
                var actual = Native.ReadClipboard(Handle);
                var after = Native.GetClipboardSequenceNumber();
                return Task.FromResult((actual == value && after != before,
                    $"Text matches={actual == value}; sequence {before} → {after}"));
            });

            await Probe("GetAsyncKeyState", async () =>
            {
                var sent = Native.SendKeys([Native.Key(0x11, false)]);
                try
                {
                    var down = await Until(() => (Native.GetAsyncKeyState(0x11) & 0x8000) != 0);
                    return (sent && down, $"Injected Ctrl down={sent}; high bit observed={down}");
                }
                finally
                {
                    Native.SendKeys([Native.Key(0x11, true)]);
                }
            });
        }
        catch (Exception error)
        {
            Program.Report("Probe orchestration", false, error.Message);
        }
        finally
        {
            Close();
        }
    }

    private int textBoxHandle;

    protected override void OnShown(EventArgs e)
    {
        textBoxHandle = unchecked((int)textBox.Handle.ToInt64());
        base.OnShown(e);
    }

    private static async Task Probe(string capability, Func<Task<(bool Passed, string Detail)>> run)
    {
        try
        {
            var result = await run().WaitAsync(TimeSpan.FromSeconds(6));
            Program.Report(capability, result.Passed, result.Detail);
        }
        catch (Exception error)
        {
            Program.Report(capability, false, $"{error.GetType().Name}: {error.Message}");
        }
    }

    private static async Task<bool> Until(Func<bool> predicate)
    {
        var timer = Stopwatch.StartNew();
        do
        {
            if (predicate())
            {
                return true;
            }

            await Task.Delay(20);
        } while (timer.Elapsed < TimeSpan.FromSeconds(2));
        return false;
    }
}

internal static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Input
    {
        internal uint Type;
        internal InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct InputUnion
    {
        [FieldOffset(0)] internal KeyboardInput Keyboard;
        [FieldOffset(0)] internal MouseInput Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardInput
    {
        internal ushort VirtualKey;
        internal ushort ScanCode;
        internal uint Flags;
        internal uint Time;
        internal nuint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MouseInput
    {
        internal int X;
        internal int Y;
        internal uint MouseData;
        internal uint Flags;
        internal uint Time;
        internal nuint ExtraInfo;
    }

    internal static Input Key(ushort key, bool up) => new()
    {
        Type = 1,
        Data = new() { Keyboard = new() { VirtualKey = key, Flags = up ? 2u : 0u } }
    };

    internal static bool SendKeys(Input[] inputs) => SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) == inputs.Length;

    internal static bool SendCombo(ushort key, params ushort[] modifiers)
    {
        var down = modifiers.Select(modifier => Key(modifier, false)).Append(Key(key, false));
        var up = new[] { Key(key, true) }.Concat(modifiers.Reverse().Select(modifier => Key(modifier, true)));
        try
        {
            return SendKeys(down.Concat(up).ToArray());
        }
        finally
        {
            // Partial SendInput must never leave injected modifiers held down.
            SendKeys(up.ToArray());
        }
    }

    internal static void WriteClipboard(nint owner, string text)
    {
        if (!OpenClipboard(owner)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        nint memory = 0;
        try
        {
            if (!EmptyClipboard()) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            var bytes = System.Text.Encoding.Unicode.GetBytes(text + '\0');
            memory = GlobalAlloc(0x0002, (nuint)bytes.Length);
            if (memory == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            var pointer = GlobalLock(memory);
            if (pointer == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            try { Marshal.Copy(bytes, 0, pointer, bytes.Length); }
            finally { GlobalUnlock(memory); }
            if (SetClipboardData(13, memory) == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            memory = 0; // Ownership transferred to the clipboard.
        }
        finally
        {
            if (memory != 0) { GlobalFree(memory); }
            CloseClipboard();
        }
    }

    internal static string? ReadClipboard(nint owner)
    {
        if (!OpenClipboard(owner)) { return null; }
        try
        {
            var memory = GetClipboardData(13);
            if (memory == 0) { return null; }
            var pointer = GlobalLock(memory);
            if (pointer == 0) { return null; }
            try { return Marshal.PtrToStringUni(pointer); }
            finally { GlobalUnlock(memory); }
        }
        finally { CloseClipboard(); }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, [In] Input[] inputs, int size);
    [DllImport("user32.dll")]
    internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")]
    internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenClipboard(nint owner);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetClipboardData(uint format, nint memory);
    [DllImport("user32.dll")]
    private static extern nint GetClipboardData(uint format);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint GlobalAlloc(uint flags, nuint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint GlobalLock(nint memory);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalUnlock(nint memory);
    [DllImport("kernel32.dll")]
    private static extern nint GlobalFree(nint memory);
}
