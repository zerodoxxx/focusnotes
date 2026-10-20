using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace CaptureApp.TestTarget;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length != 1) return;
        ApplicationConfiguration.Initialize();
        using var form = new TargetForm(args[0]);
        Application.Run(form);
    }
}

/// <summary>Pipe-driven real process: two editors, a password field, delayed rendering, a clipboard lock and a copy storm.</summary>
internal sealed class TargetForm : Form
{
    private readonly CopyTextBox first;
    private readonly CopyTextBox second;
    private readonly TextBox password = new() { Text = "secret", UseSystemPasswordChar = true, Dock = DockStyle.Top };
    private Task loopTask = Task.CompletedTask;
    private int looping;
    private int loopAttempts;
    private nint clipboardWindow;
    private readonly string pipeName;
    private string copyMode = "normal";
    private int copies;
    private int loopCopies;
    private bool clipboardHeld;
    private bool delayed;
    private readonly uint rich = Native.RegisterClipboardFormat("CaptureApp.Test.Rich");
    private readonly uint html = Native.RegisterClipboardFormat("HTML Format");
    private readonly uint unreadable = Native.RegisterClipboardFormat("CaptureApp.Test.Unreadable");

    internal TargetForm(string pipeName)
    {
        this.pipeName = pipeName;
        Text = "Selection fixture — Microsoft Edge";
        first = new(() => CopySelection(first!)) { Text = "first selected text", Dock = DockStyle.Top };
        second = new(() => CopySelection(second!)) { Text = "second selected text", Dock = DockStyle.Top };
        Controls.Add(password); Controls.Add(second); Controls.Add(first);
        Width = 600; Height = 250;
        Shown += (_, _) => { clipboardWindow = Handle; _ = Task.Run(ServeAsync); };
        FormClosed += (_, _) => { Volatile.Write(ref looping, 0); if (clipboardHeld) _ = Native.CloseClipboard(); };
    }

    private void CopySelection(TextBox box)
    {
        copies++;
        if (copyMode == "ignore") return;
        if (copyMode == "delayed")
        {
            if (!Open()) return;
            try
            {
                delayed = true;
                _ = Native.EmptyClipboard();
                _ = Native.SetClipboardData(13, 0);
            }
            finally { _ = Native.CloseClipboard(); }
            return;
        }
        _ = Publish(box.SelectedText);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x305 && delayed) // WM_RENDERFORMAT: clipboard is already open by the requesting process.
        {
            Put(13, Encoding.Unicode.GetBytes("delayed selected text\0"));
            delayed = false;
            return;
        }
        base.WndProc(ref message);
    }

    private async Task ServeAsync()
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            await pipe.ConnectAsync(10000);
            using var reader = new StreamReader(pipe, Encoding.UTF8, false, 64 * 1024, true);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 64 * 1024, true) { AutoFlush = true };
            while (await reader.ReadLineAsync() is { } line)
            {
                var request = JsonSerializer.Deserialize<Request>(line)!;
                if (request.Command == "stop")
                {
                    Volatile.Write(ref looping, 0);
                    await loopTask;
                }
                var response = (Response)Invoke(() => Command(request));
                await writer.WriteLineAsync(JsonSerializer.Serialize(response));
                if (request.Command == "quit") { BeginInvoke(Close); break; }
            }
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or ObjectDisposedException or InvalidOperationException) { Console.Error.WriteLine(ex); BeginInvoke(Close); }
    }

    private Response Command(Request request)
    {
        switch (request.Command)
        {
            case "focus":
                _ = Native.SetForegroundWindow(Handle);
                TextBox editor = request.Value switch { "second" => second, "password" => password, _ => first };
                _ = editor.Focus(); editor.SelectAll();
                break;
            case "mode": copyMode = request.Value ?? "normal"; break;
            case "copy": _ = Publish(request.Value ?? "other copy"); break;
            case "seed":
                if (Open())
                {
                    try
                    {
                        _ = Native.EmptyClipboard();
                        Put(13, Encoding.Unicode.GetBytes("original clipboard\0"));
                        Put(rich, [0, 1, 2, 0xff, 0, 7]);
                        Put(html, Encoding.UTF8.GetBytes("<b>original clipboard</b>\0"));
                    }
                    finally { _ = Native.CloseClipboard(); }
                }
                break;
            case "large":
                if (Open())
                {
                    try { _ = Native.EmptyClipboard(); Put(rich, new byte[100 * 1024 * 1024]); }
                    finally { _ = Native.CloseClipboard(); }
                }
                break;
            case "unreadable":
                if (Open())
                {
                    try { _ = Native.EmptyClipboard(); _ = Native.SetClipboardData(unreadable, 0); }
                    finally { _ = Native.CloseClipboard(); }
                }
                break;
            case "hold": clipboardHeld = Open(); break;
            case "release": if (clipboardHeld) _ = Native.CloseClipboard(); clipboardHeld = false; break;
            case "storm":
                loopCopies = 0; loopAttempts = 0; Volatile.Write(ref looping, 1);
                loopTask = Task.Run(() =>
                {
                    while (Volatile.Read(ref looping) != 0)
                    {
                        Interlocked.Increment(ref loopAttempts);
                        if (Publish($"storm:{loopCopies + 1}")) Interlocked.Increment(ref loopCopies);
                        Thread.Yield();
                    }
                });
                break;
            case "stop": case "state": break;
            case "modifiers": Native.Key((ushort)int.Parse(request.Value!), false); break;
            case "release-modifiers":
                foreach (var key in new ushort[] { 0x10, 0x11, 0x12, 0x5b, 0x5c }) Native.Key(key, true);
                break;
            case "dump": return new(Handle.ToInt64(), Native.GetForegroundWindow() == Handle, copies, loopCopies, loopAttempts, clipboardHeld, Dump());
            case "quit": break;
            default: throw new InvalidOperationException(request.Command);
        }
        return new(Handle.ToInt64(), Native.GetForegroundWindow() == Handle, copies, loopCopies, loopAttempts, clipboardHeld, null);
    }

    private bool Open()
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            if (Native.OpenClipboard(Handle)) return true;
            Thread.Sleep(2);
        }
        return false;
    }

    private bool Publish(string text)
    {
        if (!Native.OpenClipboard(clipboardWindow)) return false;
        try
        {
            if (!Native.EmptyClipboard()) return false;
            Put(13, Encoding.Unicode.GetBytes(text + '\0'));
            Put(rich, Encoding.UTF8.GetBytes(text + '\0'));
            return true;
        }
        finally { _ = Native.CloseClipboard(); }
    }

    private Dictionary<uint, string> Dump()
    {
        var values = new Dictionary<uint, string>();
        if (!Open()) return values;
        try
        {
            // Deliberately inspect the known native formats, plus the two restore flags.
            foreach (var format in new[] { 13U, rich, html, Native.RegisterClipboardFormat("CanIncludeInClipboardHistory"), Native.RegisterClipboardFormat("CanUploadToCloudClipboard") })
            {
                if (!Native.IsClipboardFormatAvailable(format)) continue;
                var handle = Native.GetClipboardData(format);
                var size = Native.GlobalSize(handle);
                if (handle == 0 || size == 0 || size > 101 * 1024 * 1024) continue;
                var pointer = Native.GlobalLock(handle);
                if (pointer == 0) continue;
                try
                {
                    var bytes = new byte[(int)size];
                    Marshal.Copy(pointer, bytes, 0, bytes.Length);
                    values[format] = Convert.ToBase64String(bytes);
                }
                finally { _ = Native.GlobalUnlock(handle); }
            }
        }
        finally { _ = Native.CloseClipboard(); }
        return values;
    }

    private static void Put(uint format, byte[] bytes)
    {
        var handle = Native.GlobalAlloc(0x42, (nuint)bytes.Length);
        var pointer = handle == 0 ? 0 : Native.GlobalLock(handle);
        if (pointer == 0) throw new InvalidOperationException("Clipboard allocation failed");
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        _ = Native.GlobalUnlock(handle);
        if (Native.SetClipboardData(format, handle) == 0) { _ = Native.GlobalFree(handle); throw new InvalidOperationException("Clipboard write failed"); }
    }

    private sealed class CopyTextBox(Action copy) : TextBox
    {
        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            if (keyData == (Keys.Control | Keys.C)) { copy(); return true; }
            return base.ProcessCmdKey(ref message, keyData);
        }
    }

    private sealed record Request(string Command, string? Value);
    private sealed record Response(long Window, bool Foreground, int Copies, int StormCopies, int StormAttempts, bool Holding, Dictionary<uint, string>? Formats);
}

internal static partial class Native
{
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool SetForegroundWindow(nint window);
    [LibraryImport("user32.dll")] internal static partial nint GetForegroundWindow();
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool OpenClipboard(nint window);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool CloseClipboard();
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool EmptyClipboard();
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool IsClipboardFormatAvailable(uint format);
    [LibraryImport("user32.dll")] internal static partial nint GetClipboardData(uint format);
    [LibraryImport("user32.dll")] internal static partial nint SetClipboardData(uint format, nint handle);
    [LibraryImport("user32.dll", EntryPoint = "RegisterClipboardFormatW", StringMarshalling = StringMarshalling.Utf16)] internal static partial uint RegisterClipboardFormat(string name);
    [LibraryImport("kernel32.dll")] internal static partial nint GlobalAlloc(uint flags, nuint size);
    [LibraryImport("kernel32.dll")] internal static partial nint GlobalLock(nint handle);
    [LibraryImport("kernel32.dll")] internal static partial nuint GlobalSize(nint handle);
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool GlobalUnlock(nint handle);
    [LibraryImport("kernel32.dll")] internal static partial nint GlobalFree(nint handle);
    [LibraryImport("user32.dll")] private static partial uint SendInput(uint count, [In] Input[] inputs, int size);
    internal static void Key(ushort key, bool up) => _ = SendInput(1, [new() { Type = 1, Data = new() { Keyboard = new() { Key = key, Flags = up ? 2U : 0U } } }], Marshal.SizeOf<Input>());
    [StructLayout(LayoutKind.Sequential)] private struct Input { internal uint Type; internal Union Data; }
    [StructLayout(LayoutKind.Explicit)] private struct Union { [FieldOffset(0)] internal Keyboard Keyboard; [FieldOffset(0)] internal Mouse Mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct Keyboard { internal ushort Key, Scan; internal uint Flags, Time; internal nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct Mouse { internal int X, Y; internal uint Data, Flags, Time; internal nuint Extra; }
}
