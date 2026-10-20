using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace CaptureApp.Platform.Selection;

internal sealed record ClipboardCopy(string? Text, uint Sequence, bool TargetOwned, bool NotOpened = false);
internal sealed record ClipboardRestore(bool Restored, TimeSpan HoldTime, bool Superseded = false); // Superseded: the sequence moved, so a retry can never succeed.

/// <summary>All mutations are confined to Restore, after a sequence check with the clipboard locked.</summary>
internal sealed class ClipboardGuard
{
    private static readonly Lazy<BoundedWorker> Worker = new(() => new("Selection clipboard materialization (MTA)"));
    private static readonly Lazy<ClipboardListener> Listener = new(() => new());
    private readonly ClipboardListener listener = Listener.Value;
    internal long SignalVersion => listener.SignalVersion;

    internal async Task<SnapshotResult> SnapshotAsync(CancellationToken cancellationToken)
    {
        if (listener.Window == 0) return new(null, SnapshotFailure.Unavailable);
        return await Worker.Value.RunAsync(() => ClipboardSnapshot.Take(listener.Window),
            ClipboardSnapshot.MaximumTime, cancellationToken).ConfigureAwait(false) ?? new(null, SnapshotFailure.TimedOut);
    }

    internal static bool TryOpen(nint window, Stopwatch? clock = null, TimeSpan? limit = null)
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (clock is not null && clock.Elapsed >= limit) return false;
            if (NativeMethods.OpenClipboard(window)) return true;
            Thread.Sleep(10);
        }
        return false;
    }

    internal async Task<ClipboardCopy?> ReadCopyAsync(uint targetPid, TimeSpan remaining, ClipboardSnapshot snapshot)
    {
        if (remaining <= TimeSpan.Zero) return null;
        _ = snapshot.Retain();
        try
        {
            var copy = await Worker.Value.RunAsync(() => ReadCopy(targetPid), remaining, CancellationToken.None,
                onAbandoned: late =>
                {
                    // GetClipboardData cannot be safely interrupted. Keep a snapshot lease until it returns;
                    // cleanup is conditional on that copy's sequence, so it cannot overwrite a later copy.
                    try
                    {
                        if (late is { TargetOwned: true } && late.Sequence != snapshot.Sequence) _ = Restore(snapshot, late.Sequence);
                    }
                    finally { snapshot.Dispose(); }
                }).ConfigureAwait(false);
            if (copy is not null) snapshot.Dispose();
            return copy;
        }
        catch { snapshot.Dispose(); throw; }
    }

    /// <summary>Bounded background retry for a target that kept the clipboard open past the capture deadline.
    /// Restores only a target-owned copy that differs from the snapshot, and only if the sequence is still that copy's.</summary>
    internal void ScheduleRestoreRetry(uint targetPid, ClipboardSnapshot snapshot)
    {
        _ = snapshot.Retain(); // Lease outlives the caller's disposal.
        _ = Task.Run(async () =>
        {
            try
            {
                var clock = Stopwatch.StartNew();
                while (clock.Elapsed < TimeSpan.FromSeconds(2))
                {
                    var copy = await ReadCopyAsync(targetPid, TimeSpan.FromMilliseconds(300), snapshot).ConfigureAwait(false);
                    if (copy is { NotOpened: false })
                    {
                        if (copy.TargetOwned && copy.Sequence != snapshot.Sequence) _ = Restore(snapshot, copy.Sequence);
                        return; // Foreign or unchanged: never overwrite.
                    }
                    await Task.Delay(50).ConfigureAwait(false);
                }
            }
            catch (Exception) { /* Best effort cleanup. */ }
            finally { snapshot.Dispose(); }
        });
    }

    private ClipboardCopy ReadCopy(uint targetPid)
    {
        if (!TryOpen(listener.Window)) return new(null, 0, false, NotOpened: true); // Not a foreign owner: the target may still hold it.
        try
        {
            _ = NativeMethods.GetWindowThreadProcessId(NativeMethods.GetClipboardOwner(), out var ownerPid);
            if (ownerPid != targetPid) return new(null, NativeMethods.GetClipboardSequenceNumber(), false);
            var handle = NativeMethods.GetClipboardData(13); // Listener also wakes us for a delayed-render copy.
            var sequence = NativeMethods.GetClipboardSequenceNumber();
            if (handle == 0) return new(null, sequence, true);
            var size = NativeMethods.GlobalSize(handle);
            if (size < 2 || size > (nuint)ClipboardSnapshot.MaximumBytes) return new(null, sequence, true);
            var pointer = NativeMethods.GlobalLock(handle);
            if (pointer == 0) return new(null, sequence, true);
            try
            {
                var bytes = new byte[(int)size & ~1];
                Marshal.Copy(pointer, bytes, 0, bytes.Length);
                var end = 0;
                while (end + 1 < bytes.Length && (bytes[end] != 0 || bytes[end + 1] != 0)) end += 2;
                return new(Encoding.Unicode.GetString(bytes, 0, end), sequence, true);
            }
            finally { _ = NativeMethods.GlobalUnlock(handle); }
        }
        finally { _ = NativeMethods.CloseClipboard(); }
    }

    internal ClipboardRestore Restore(ClipboardSnapshot snapshot, uint expectedSequence, Action? whileLocked = null)
    {
        var prepared = new List<ClipboardValue>();
        try
        {
            var history = NativeMethods.RegisterClipboardFormat("CanIncludeInClipboardHistory");
            var cloud = NativeMethods.RegisterClipboardFormat("CanUploadToCloudClipboard");
            if (history == 0 || cloud == 0) return new(false, TimeSpan.Zero);
            // Allocate and duplicate everything before taking the lock. Override any original opt-in flags.
            foreach (var value in snapshot.Values.Where(value => value.Format != history && value.Format != cloud)
                .Concat([new ClipboardValue(history, new byte[4], 0, 4), new ClipboardValue(cloud, new byte[4], 0, 4)]))
            {
                var copy = value.Prepare();
                if (copy is null) return new(false, TimeSpan.Zero);
                prepared.Add(copy);
            }
            if (!TryOpen(listener.Window)) return new(false, TimeSpan.Zero);
            var hold = Stopwatch.StartNew();
            bool restored, superseded;
            try { restored = RestoreWhileOpen(prepared, expectedSequence, whileLocked, out superseded); }
            finally { _ = NativeMethods.CloseClipboard(); }
            return new(restored, hold.Elapsed, superseded);

        }
        finally { foreach (var value in prepared) value.Dispose(); }
    }

    private static bool RestoreWhileOpen(List<ClipboardValue> prepared, uint expectedSequence, Action? whileLocked, out bool superseded)
    {
        superseded = false;
        // G11: checking before OpenClipboard leaves a destructive TOCTOU race. Check ONLY under the lock.
        if (NativeMethods.GetClipboardSequenceNumber() != expectedSequence) { superseded = true; return false; }
        whileLocked?.Invoke(); // Deterministic contention seam used only by the helper race test.
        if (!NativeMethods.EmptyClipboard()) return false;
        foreach (var value in prepared)
        {
            if (NativeMethods.SetClipboardData(value.Format, value.Handle) == 0) return false;
            value.Transfer();
        }
        return true;
    }

}

internal sealed class ClipboardListener
{
    private long signals;
    internal nint Window { get; private set; }
    internal long SignalVersion => Interlocked.Read(ref signals);

    internal ClipboardListener()
    {
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            Window = NativeMethods.CreateWindowEx(0, "STATIC", "Selection clipboard listener", 0, 0, 0, 0, 0, -3, 0, 0, 0);
            if (Window != 0 && !NativeMethods.AddClipboardFormatListener(Window))
            { _ = NativeMethods.DestroyWindow(Window); Window = 0; }
            ready.SetResult();
            if (Window == 0) return;
            while (NativeMethods.GetMessage(out var message, 0, 0, 0) > 0)
            {
                if (message.Id == 0x31d) Interlocked.Increment(ref signals);
                _ = NativeMethods.TranslateMessage(in message);
                _ = NativeMethods.DispatchMessage(in message);
            }
            _ = NativeMethods.RemoveClipboardFormatListener(Window);
            _ = NativeMethods.DestroyWindow(Window);
        }) { IsBackground = true, Name = "Selection clipboard notifications" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        _ = ready.Task.Wait(TimeSpan.FromMilliseconds(250));
    }
}
