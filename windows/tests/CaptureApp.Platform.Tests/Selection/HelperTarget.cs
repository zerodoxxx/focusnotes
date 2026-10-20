global using System.IO;

using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using CaptureApp.Platform.Context;
using CaptureApp.Platform.Selection;
using Xunit;
using Forms = System.Windows.Forms;

namespace CaptureApp.Platform.Tests.Selection;

internal sealed record TargetResponse(long Window, bool Foreground, int Copies, int StormCopies, int StormAttempts, bool Holding, Dictionary<uint, string>? Formats);

internal sealed class HelperTarget : IAsyncDisposable
{
    private readonly Process process;
    private readonly NamedPipeServerStream pipe;
    private readonly StringBuilder errors = new();
    private StreamReader reader = null!;
    private StreamWriter writer = null!;
    internal FrontmostContext Context { get; private set; } = new(0, 0);

    private HelperTarget(Process process, NamedPipeServerStream pipe)
    {
        this.process = process; this.pipe = pipe;
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (errors) errors.AppendLine(e.Data); };
    }

    // Readers/writers wrap the pipe only once connected: an unconnected server stream throws "Pipe hasn't been connected yet".
    private void Attach()
    {
        // 64 KB buffers: the 100 MB clipboard dump is a ~133 MB line, which a 1 KB buffer streams painfully slowly.
        reader = new(pipe, Encoding.UTF8, false, 64 * 1024, true);
        writer = new(pipe, new UTF8Encoding(false), 64 * 1024, true) { AutoFlush = true };
    }

    private string Diagnostics()
    {
        string stderr; lock (errors) stderr = errors.ToString();
        return $"helper exited={process.HasExited}" + (process.HasExited ? $" code={process.ExitCode}" : "") + $", stderr: {stderr}";
    }

    internal static async Task<HelperTarget> StartAsync()
    {
        var testDirectory = new DirectoryInfo(AppContext.BaseDirectory);
        string? executable = null;
        for (var directory = testDirectory; directory is not null; directory = directory.Parent)
        {
            if (directory.Name != "bin") continue;
            var candidates = Directory.GetFiles(directory.FullName, "CaptureApp.TestTarget.exe", SearchOption.AllDirectories);
            executable = candidates.FirstOrDefault();
            break;
        }
        // Also supports the repository's ordinary bin/Release/<TFM> output layout.
        if (executable is null)
        {
            for (var directory = testDirectory; directory is not null; directory = directory.Parent)
            {
                var helperRoot = Path.Combine(directory.FullName, "CaptureApp.TestTarget", "bin");
                if (!Directory.Exists(helperRoot)) continue;
                executable = Directory.GetFiles(helperRoot, "CaptureApp.TestTarget.exe", SearchOption.AllDirectories).FirstOrDefault();
                break;
            }
        }
        Assert.True(executable is not null, "Build the solution so the helper target executable is available.");
        var pipeName = "capture-selection-" + Guid.NewGuid().ToString("N");
        var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        var start = new ProcessStartInfo(executable!) { UseShellExecute = false, RedirectStandardError = true };
        start.ArgumentList.Add(pipeName);
        var process = Process.Start(start)!;
        process.BeginErrorReadLine();
        var target = new HelperTarget(process, pipe);
        try
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            try { await pipe.WaitForConnectionAsync(deadline.Token); }
            catch (OperationCanceledException) { throw new InvalidOperationException("Helper never connected to the pipe (" + target.Diagnostics() + ")"); }
            target.Attach();
            var state = await target.CommandAsync("mode", "normal");
            target.Context = new((nint)state.Window, (uint)process.Id, "Selection fixture");
            return target;
        }
        catch { await target.DisposeAsync(); throw; }
    }

    internal async Task<TargetResponse> CommandAsync(string command, string? value = null)
    {
        await writer.WriteLineAsync(JsonSerializer.Serialize(new { Command = command, Value = value }));
        // Placing/dumping the 100 MB payload (base64 over the pipe) legitimately exceeds the usual budget on slow CI.
        var timeout = TimeSpan.FromSeconds(command is "large" or "dump" ? 90 : 15);
        var line = await reader.ReadLineAsync().WaitAsync(timeout, TestContext.Current.CancellationToken);
        Assert.True(line is not null, "Helper closed the pipe (" + Diagnostics() + ")");
        return JsonSerializer.Deserialize<TargetResponse>(line)!;
    }

    internal async Task FocusAsync(string field = "first")
    {
        // Foreground changes can lose a race with the previous window's teardown, and the foreground lock blocks
        // background processes; own the last input event, grant the helper the right, then retry briefly.
        var foreground = false;
        for (var attempt = 0; attempt < 5 && !foreground; attempt++)
        {
            Win32.keybd_event(0xE8, 0, 0, 0); // VK_NONAME: no-op key that makes this process the last-input owner.
            Win32.keybd_event(0xE8, 0, 2, 0);
            _ = NativeMethods.AllowSetForegroundWindow((uint)process.Id);
            foreground = (await CommandAsync("focus", field)).Foreground;
            if (!foreground)
            {
                // Attach to the current foreground thread's input queue so the helper's retry is allowed.
                var current = NativeMethods.GetForegroundWindow();
                var foregroundThread = current == 0 ? 0 : Win32.GetWindowThreadProcessId(current, out _);
                var self = Win32.GetCurrentThreadId();
                var attached = foregroundThread != 0 && foregroundThread != self && Win32.AttachThreadInput(self, foregroundThread, true);
                try { foreground = (await CommandAsync("focus", field)).Foreground; }
                finally { if (attached) _ = Win32.AttachThreadInput(self, foregroundThread, false); }
            }
            if (!foreground) await Task.Delay(100, TestContext.Current.CancellationToken);
        }
        var owner = NativeMethods.GetForegroundWindow();
        _ = Win32.GetWindowThreadProcessId(owner, out var ownerPid);
        Assert.True(foreground, $"SetForegroundWindow probe succeeded, but the helper could not become foreground (foreground window 0x{owner:X} owned by pid {ownerPid}, helper pid {process.Id}).");
        await Task.Delay(30, TestContext.Current.CancellationToken);
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (pipe.IsConnected && !process.HasExited) await CommandAsync("quit");
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or InvalidOperationException) { }
        if (!process.HasExited)
        {
            try
            {
#pragma warning disable xUnit1051 // Cleanup must run after test cancellation.
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
#pragma warning restore xUnit1051
            }
            catch (TimeoutException) { process.Kill(true); }
        }
        writer?.Dispose(); reader?.Dispose(); pipe.Dispose(); process.Dispose();
    }
}

#pragma warning disable SYSLIB1054 // Blittable test-only imports.
internal static class Win32
{
    [System.Runtime.InteropServices.DllImport("user32.dll")] internal static extern void keybd_event(byte key, byte scan, uint flags, nuint extra);
    [System.Runtime.InteropServices.DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint pid);
    [System.Runtime.InteropServices.DllImport("user32.dll")] [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] internal static extern bool AttachThreadInput(uint from, uint to, [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] bool attach);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] internal static extern uint GetCurrentThreadId();
}
#pragma warning restore SYSLIB1054

/// <summary>The quick capability probe uses a window belonging to this very test process.</summary>
internal sealed class DesktopProbe : IAsyncDisposable
{
    private readonly TaskCompletionSource<Forms.Form> ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Forms.Form? form;
    internal nint Handle { get; private set; }

    private DesktopProbe()
    {
        var thread = new Thread(() =>
        {
            using var window = new Forms.Form { Text = "Selection desktop capability probe", Width = 160, Height = 100 };
            window.Shown += (_, _) => ready.SetResult(window);
            Forms.Application.Run(window);
            stopped.SetResult();
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    internal static async Task<DesktopProbe> RequireAsync()
    {
        var probe = new DesktopProbe();
        probe.form = await probe.ready.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        var capable = (bool)probe.form.Invoke(() =>
        {
            probe.Handle = probe.form.Handle;
            return NativeMethods.SetForegroundWindow(probe.Handle) && NativeMethods.GetForegroundWindow() == probe.Handle;
        });
        if (!capable)
        {
            await probe.DisposeAsync();
            Assert.Skip("No interactive desktop focus: SetForegroundWindow on the test process's own window failed (expected on windows-11-arm).");
        }
        return probe;
    }

    internal Task FocusAsync()
    {
        Assert.True((bool)form!.Invoke(() => NativeMethods.SetForegroundWindow(Handle)));
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        if (form is null) return;
        form.BeginInvoke(form.Close);
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        form = null;
    }
}

internal sealed class InstrumentedServices : WindowsSelectionServices
{
    internal int Injections;
    internal Action? OnInjected;
    internal bool SuppressSelection = true;
    internal Func<SelectionCheckpoint, Task>? Hook;
    internal List<ClipboardRestore> Restorations { get; } = [];

    public override async Task<UiaRead> ReadUiaAsync(uint pid, bool selection, CancellationToken token)
    {
        var result = await base.ReadUiaAsync(pid, selection && !SuppressSelection, token);
        return SuppressSelection ? result with { Text = null } : result;
    }
    public override bool InjectCopy() { Injections++; var result = base.InjectCopy(); OnInjected?.Invoke(); return result; }
    public override Task CheckpointAsync(SelectionCheckpoint checkpoint) => Hook?.Invoke(checkpoint) ?? Task.CompletedTask;
    public override ClipboardRestore Restore(ClipboardSnapshot snapshot, uint sequence)
    {
        var result = base.Restore(snapshot, sequence);
        Restorations.Add(result);
        return result;
    }
}
