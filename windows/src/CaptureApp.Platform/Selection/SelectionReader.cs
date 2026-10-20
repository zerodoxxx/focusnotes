using System.Diagnostics;
using CaptureApp.Platform.Context;

namespace CaptureApp.Platform.Selection;

public enum SelectionMethod { UiAutomation, Clipboard }
public enum SelectionFailure
{
    NoSelection, OwnApp, Busy, SecureField, TargetChanged, ModifiersHeld, ElevatedTarget,
    ClipboardUnsafe, ClipboardTooLarge, FallbackOff, Cancelled, SelectionUndetermined
}
public sealed record SelectionCapture(string Text, FrontmostContext Context, SelectionMethod Method);
public sealed record SelectionResult(SelectionCapture? Capture, SelectionFailure? Failure, string? Detail = null)
{
    public bool IsSuccess => Capture is not null;
    public string? Message => Failure switch
    {
        SelectionFailure.OwnApp => null,
        SelectionFailure.SecureField => PlatformStrings.SecureField,
        SelectionFailure.ModifiersHeld => PlatformStrings.ReleaseShortcutKeys,
        SelectionFailure.ElevatedTarget => PlatformStrings.ElevatedTarget,
        SelectionFailure.ClipboardUnsafe or SelectionFailure.ClipboardTooLarge or SelectionFailure.SelectionUndetermined => PlatformStrings.CouldNotCapture,
        null => null,
        _ => PlatformStrings.NoTextSelected
    };
    public string? Hint => Failure switch
    {
        SelectionFailure.FallbackOff => PlatformStrings.FallbackOffHint,
        SelectionFailure.ClipboardTooLarge => PlatformStrings.ClipboardTooLarge,
        _ => null
    };
    public string? HintForCaptureArea(string binding) => Failure == SelectionFailure.ElevatedTarget
        ? PlatformStrings.CaptureAreaHint(binding) : Hint;
    // Detail names the check that refused; internal diagnostics only.
    internal static SelectionResult Refuse(SelectionFailure reason, string? detail = null) => new(null, reason, detail);
}

internal enum SelectionCheckpoint { AfterUia, AfterModifiers, AfterSnapshot, BeforeInjection, CopyObserved, BeforeRestore }

internal interface ISelectionServices
{
    uint OwnPid { get; }
    bool IsFrontmost(FrontmostContext context);
    bool IsElevated(uint pid);
    Task<UiaRead> ReadUiaAsync(uint pid, bool selection, CancellationToken token);
    bool ModifiersHeld { get; }
    uint ClipboardSequence { get; }
    long ClipboardSignal { get; }
    Task<SnapshotResult> SnapshotAsync(CancellationToken token);
    bool InjectCopy();
    Task<ClipboardCopy?> ReadCopyAsync(uint targetPid, TimeSpan remaining, ClipboardSnapshot snapshot);
    ClipboardRestore Restore(ClipboardSnapshot snapshot, uint sequence);
    void ScheduleRestoreRetry(uint targetPid, ClipboardSnapshot snapshot);
    Task CheckpointAsync(SelectionCheckpoint checkpoint);
}

internal class WindowsSelectionServices : ISelectionServices
{
    internal Action? WhileRestoreLocked { get; init; }
    private readonly Lazy<ClipboardGuard> clipboard = new(() => new());
    public uint OwnPid => (uint)Environment.ProcessId;
    public bool IsFrontmost(FrontmostContext context) => context.IsStillFrontmost();
    public bool IsElevated(uint pid) => ElevationCheck.MustRefuse(pid);
    public virtual Task<UiaRead> ReadUiaAsync(uint pid, bool selection, CancellationToken token) => UiaSelection.ReadAsync(pid, selection, token);
    public bool ModifiersHeld => new[] { 0x10, 0x11, 0x12, 0x5b, 0x5c }.Any(key => (NativeMethods.GetAsyncKeyState(key) & 0x8000) != 0);
    public uint ClipboardSequence => NativeMethods.GetClipboardSequenceNumber();
    public long ClipboardSignal => clipboard.Value.SignalVersion;
    public Task<SnapshotResult> SnapshotAsync(CancellationToken token) => clipboard.Value.SnapshotAsync(token);
    public virtual bool InjectCopy()
    {
        var inputs = new[] { Key(0x11, 0), Key(0x43, 0), Key(0x43, 2), Key(0x11, 2) };
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.Input>());
        // A partially accepted batch must never leave our synthetic Ctrl/C down.
        if (sent is > 0 and < 4)
            _ = NativeMethods.SendInput(2, [Key(0x43, 2), Key(0x11, 2)], System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.Input>());
        return sent == inputs.Length;
    }
    private static NativeMethods.Input Key(ushort key, uint flags) => new()
    { Type = 1, Data = new() { Keyboard = new() { Key = key, Flags = flags } } };
    public Task<ClipboardCopy?> ReadCopyAsync(uint targetPid, TimeSpan remaining, ClipboardSnapshot snapshot) => clipboard.Value.ReadCopyAsync(targetPid, remaining, snapshot);
    public virtual ClipboardRestore Restore(ClipboardSnapshot snapshot, uint sequence) => clipboard.Value.Restore(snapshot, sequence, WhileRestoreLocked);
    public virtual void ScheduleRestoreRetry(uint targetPid, ClipboardSnapshot snapshot) => clipboard.Value.ScheduleRestoreRetry(targetPid, snapshot);
    public virtual Task CheckpointAsync(SelectionCheckpoint checkpoint) => Task.CompletedTask;
}

/// <summary>UIA first; the caller must explicitly enable the clipboard fallback after the Setup disclosure.</summary>
public sealed class SelectionReader
{
    private static int captureInProgress;
    private readonly ISelectionServices services;
    private readonly TimeSpan copyDeadline;
    public SelectionReader() : this(new WindowsSelectionServices()) { }
    internal SelectionReader(ISelectionServices services, TimeSpan? copyDeadline = null)
    {
        this.services = services;
        this.copyDeadline = copyDeadline ?? TimeSpan.FromMilliseconds(500);
    }

    public async Task<SelectionResult> ReadAsync(bool useClipboardFallback = false, FrontmostContext? context = null,
        CancellationToken cancellationToken = default)
    {
        context ??= FrontmostContext.Capture();
        if (context.ProcessIdentifier == services.OwnPid) return SelectionResult.Refuse(SelectionFailure.OwnApp); // G1
        if (context.WindowHandle == 0 || context.ProcessIdentifier == 0) return SelectionResult.Refuse(SelectionFailure.NoSelection);
        if (Interlocked.CompareExchange(ref captureInProgress, 1, 0) != 0) return SelectionResult.Refuse(SelectionFailure.Busy); // G2
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!services.IsFrontmost(context)) return SelectionResult.Refuse(SelectionFailure.TargetChanged); // G4 entry
            if (services.IsElevated(context.ProcessIdentifier)) return SelectionResult.Refuse(SelectionFailure.ElevatedTarget);
            var entry = await SafetyAsync(context, "G3 entry", cancellationToken).ConfigureAwait(false);
            if (entry is not null) return entry;
            var selection = await services.ReadUiaAsync(context.ProcessIdentifier, true, cancellationToken).ConfigureAwait(false); // G5
            await services.CheckpointAsync(SelectionCheckpoint.AfterUia).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (!services.IsFrontmost(context)) return SelectionResult.Refuse(SelectionFailure.TargetChanged); // G4 after read
            var afterRead = await SafetyAsync(context, "G3 after read", cancellationToken).ConfigureAwait(false);
            if (afterRead is not null) return afterRead;
            if (selection.Safety == FieldSafety.Password) return SelectionResult.Refuse(SelectionFailure.SecureField, "selection read");
            if (selection.Safety == FieldSafety.WrongProcess) return SelectionResult.Refuse(SelectionFailure.TargetChanged, "selection read");
            cancellationToken.ThrowIfCancellationRequested();
            if (!services.IsFrontmost(context)) return SelectionResult.Refuse(SelectionFailure.TargetChanged);
            if (!string.IsNullOrEmpty(selection.Text))
                return new(new(selection.Text, context, SelectionMethod.UiAutomation), null);
            if (!useClipboardFallback) return SelectionResult.Refuse(SelectionFailure.FallbackOff);

            await WaitForModifiersAsync(cancellationToken).ConfigureAwait(false); // G6
            cancellationToken.ThrowIfCancellationRequested(); // G12 after modifier wait
            if (services.ModifiersHeld) return SelectionResult.Refuse(SelectionFailure.ModifiersHeld, "G6");
            await services.CheckpointAsync(SelectionCheckpoint.AfterModifiers).ConfigureAwait(false);
            if (!services.IsFrontmost(context)) return SelectionResult.Refuse(SelectionFailure.TargetChanged); // G4
            var afterModifiers = await SafetyAsync(context, "G3 after modifiers", cancellationToken).ConfigureAwait(false);
            if (afterModifiers is not null) return afterModifiers;
            using var snapshotResult = await services.SnapshotAsync(cancellationToken).ConfigureAwait(false); // G10
            cancellationToken.ThrowIfCancellationRequested();
            if (snapshotResult.Snapshot is not { } snapshot)
                return SelectionResult.Refuse(snapshotResult.Failure is SnapshotFailure.TooLarge
                    ? SelectionFailure.ClipboardTooLarge : SelectionFailure.ClipboardUnsafe);
            await services.CheckpointAsync(SelectionCheckpoint.AfterSnapshot).ConfigureAwait(false);
            if (!services.IsFrontmost(context)) return SelectionResult.Refuse(SelectionFailure.TargetChanged); // G4 before G3: a focus switch is not a secure field
            var beforePost = await SafetyAsync(context, "G3 before post", cancellationToken).ConfigureAwait(false);
            if (beforePost is not null) return beforePost;
            if (services.IsElevated(context.ProcessIdentifier)) return SelectionResult.Refuse(SelectionFailure.ElevatedTarget);
            await services.CheckpointAsync(SelectionCheckpoint.BeforeInjection).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (!services.IsFrontmost(context)) return SelectionResult.Refuse(SelectionFailure.TargetChanged); // G4 final
            if (services.ModifiersHeld) return SelectionResult.Refuse(SelectionFailure.ModifiersHeld);
            if (services.ClipboardSequence != snapshot.Sequence) return SelectionResult.Refuse(SelectionFailure.ClipboardUnsafe); // G7

            var signal = services.ClipboardSignal; // Read after the last pre-injection checks so earlier signals don't count.
            uint? restoreSequence = null;
            try
            {
                var injected = services.InjectCopy();
                var wait = Stopwatch.StartNew();
                var notOpened = false;
                // Even partial/failed injection may have changed the clipboard: observe it, then restore in finally.
                while (wait.Elapsed < copyDeadline) // G8
                {
                    if (services.ClipboardSequence != snapshot.Sequence || services.ClipboardSignal != signal)
                    {
                        var copy = await services.ReadCopyAsync(context.ProcessIdentifier,
                            copyDeadline - wait.Elapsed, snapshot).ConfigureAwait(false);
                        if (copy is null) break; // Out of time or abandoned: the late check below still restores.
                        if (copy.NotOpened)
                        {
                            notOpened = true;
                            if (cancellationToken.IsCancellationRequested) break;
                            await Task.Delay(10).ConfigureAwait(false);
                            continue;
                        } // Target may hold the clipboard open (Office): keep polling.
                        if (!copy.TargetOwned) return SelectionResult.Refuse(SelectionFailure.NoSelection);
                        if (copy.Sequence != snapshot.Sequence)
                        {
                            restoreSequence = copy.Sequence;
                            await services.CheckpointAsync(SelectionCheckpoint.CopyObserved).ConfigureAwait(false);
                            cancellationToken.ThrowIfCancellationRequested(); // G12 before accepting text
                            if (!injected || string.IsNullOrEmpty(copy.Text) || services.ClipboardSequence != copy.Sequence) // G9
                                return SelectionResult.Refuse(SelectionFailure.NoSelection);
                            return new(new(copy.Text, context, SelectionMethod.Clipboard), null);
                        }
                    }
                    if (cancellationToken.IsCancellationRequested) break;
                    await Task.Delay(10).ConfigureAwait(false); // Cancellation still takes the cleanup path.
                }
                // Cancellation/timeout must also clean up a copy that landed at the last checkpoint.
                if (services.ClipboardSequence != snapshot.Sequence || services.ClipboardSignal != signal)
                {
                    var late = await services.ReadCopyAsync(context.ProcessIdentifier, TimeSpan.FromMilliseconds(100), snapshot).ConfigureAwait(false);
                    if (late is { TargetOwned: true } && late.Sequence != snapshot.Sequence) restoreSequence = late.Sequence;
                    // The target never released the clipboard: a copy may still land. Retry in the background, sequence-conditionally.
                    else if (late is { NotOpened: true } || (late is null && notOpened)) services.ScheduleRestoreRetry(context.ProcessIdentifier, snapshot);
                }
                return SelectionResult.Refuse(cancellationToken.IsCancellationRequested ? SelectionFailure.Cancelled : SelectionFailure.NoSelection);
            }
            finally // G11: never overwrite a different/newer copy; cancellation cannot bypass restoration.
            {
                if (restoreSequence is { } expected)
                {
                    await services.CheckpointAsync(SelectionCheckpoint.BeforeRestore).ConfigureAwait(false);
                    // Retry only transient failures; a moved sequence (newer copy) is final and must never be retried.
                    for (var attempt = 0; attempt < 3; attempt++)
                    {
                        if (services.Restore(snapshot, expected) is { Restored: true } or { Superseded: true }) break;
                        if (attempt < 2) await Task.Delay(20).ConfigureAwait(false);
                    }
                }
            }
        }
        catch (OperationCanceledException) { return SelectionResult.Refuse(SelectionFailure.Cancelled); }
        finally { Volatile.Write(ref captureInProgress, 0); }
    }

    private async Task WaitForModifiersAsync(CancellationToken token)
    {
        var release = Stopwatch.StartNew();
        while (services.ModifiersHeld && release.Elapsed < TimeSpan.FromMilliseconds(200))
            await Task.Delay(10, token).ConfigureAwait(false);
    }

    private async Task<SelectionResult?> SafetyAsync(FrontmostContext context, string check, CancellationToken token)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            token.ThrowIfCancellationRequested();
            var field = await services.ReadUiaAsync(context.ProcessIdentifier, false, token).ConfigureAwait(false);
            switch (field.Safety)
            {
                case FieldSafety.Safe: return null;
                case FieldSafety.Password: return SelectionResult.Refuse(SelectionFailure.SecureField, check);
                case FieldSafety.WrongProcess: return SelectionResult.Refuse(SelectionFailure.TargetChanged, check);
            }
            // A focus switch or a held modifier can steal UIA focus and leave the read undetermined.
            if (!services.IsFrontmost(context)) return SelectionResult.Refuse(SelectionFailure.TargetChanged, check + " (undetermined, foreground changed)");
            await WaitForModifiersAsync(token).ConfigureAwait(false);
            if (services.ModifiersHeld) return SelectionResult.Refuse(SelectionFailure.ModifiersHeld, check + " (undetermined, modifiers held)");
            if (!services.IsFrontmost(context)) return SelectionResult.Refuse(SelectionFailure.TargetChanged, check + " (undetermined, foreground changed)");
            if (attempt < 2) await Task.Delay(50, token).ConfigureAwait(false);
        }
        return SelectionResult.Refuse(SelectionFailure.SelectionUndetermined, check);
    }
}
