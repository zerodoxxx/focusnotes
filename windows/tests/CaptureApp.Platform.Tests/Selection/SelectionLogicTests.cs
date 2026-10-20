using CaptureApp.Platform.Context;
using CaptureApp.Platform.Selection;
using Xunit;

namespace CaptureApp.Platform.Tests.Selection;

[CollectionDefinition("Selection", DisableParallelization = true)]
public sealed class SelectionCollection;

[Collection("Selection")]
public sealed class SelectionLogicTests
{
    private static readonly FrontmostContext Target = new(123, 42, "Target");

    [Fact]
    public async Task UiAutomationWinsWithoutClipboardConsentOrMutation()
    {
        var fake = new FakeServices { Text = "selected" };
        var result = await new SelectionReader(fake).ReadAsync(context: Target, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(SelectionMethod.UiAutomation, result.Capture?.Method);
        Assert.Equal("selected", result.Capture?.Text);
        Assert.Equal(0, fake.Snapshots);
        Assert.Equal(0, fake.Injections);
    }

    [Fact]
    public async Task FallbackOffHasExactHintAndDoesNotTouchClipboard()
    {
        var fake = new FakeServices();
        var result = await new SelectionReader(fake).ReadAsync(context: Target, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(SelectionFailure.FallbackOff, result.Failure);
        Assert.Equal("No text selected", result.Message);
        Assert.Equal("This app doesn't share its selection; turn on the clipboard fallback in Settings", result.Hint);
        Assert.Equal(0, fake.Snapshots);
        Assert.Equal(0, fake.Injections);
    }

    [Theory]
    [InlineData(0, 42, SelectionFailure.NoSelection)]
    [InlineData(123, 0, SelectionFailure.NoSelection)]
    [InlineData(123, 7, SelectionFailure.OwnApp)]
    public async Task InvalidAndOwnTargetsAreRejected(int window, uint pid, SelectionFailure failure)
    {
        var fake = new FakeServices();
        Assert.Equal(failure, (await new SelectionReader(fake).ReadAsync(true, new(window, pid), TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, fake.Injections);
    }

    [Fact]
    public async Task GateIsProcessWideAcrossReaderInstancesAndReleasedAfterCancellation()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var fake = new FakeServices { Hook = async point => { if (point == SelectionCheckpoint.AfterUia) { entered.SetResult(); await release.Task; } } };
        using var token = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var first = new SelectionReader(fake).ReadAsync(true, Target, token.Token);
        await entered.Task;
        Assert.Equal(SelectionFailure.Busy, (await new SelectionReader(new FakeServices()).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        token.Cancel(); release.SetResult();
        Assert.Equal(SelectionFailure.Cancelled, (await first).Failure);
        Assert.Equal(SelectionFailure.FallbackOff, (await new SelectionReader(new FakeServices()).ReadAsync(context: Target, cancellationToken: TestContext.Current.CancellationToken)).Failure);
    }

    [Theory]
    [InlineData((int)SelectionCheckpoint.AfterUia)]
    [InlineData((int)SelectionCheckpoint.AfterModifiers)]
    [InlineData((int)SelectionCheckpoint.AfterSnapshot)]
    [InlineData((int)SelectionCheckpoint.BeforeInjection)]
    public async Task FocusChangesAtEveryCheckpointPreventInjection(int checkpointValue)
    {
        var point = (SelectionCheckpoint)checkpointValue;
        var fake = new FakeServices();
        fake.Hook = checkpoint => { if (point == checkpoint) fake.Frontmost = false; return Task.CompletedTask; };
        Assert.Equal(SelectionFailure.TargetChanged, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, fake.Injections);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public async Task PasswordRechecksPreventInjection(int passwordCheck)
    {
        var fake = new FakeServices { PasswordAtCheck = passwordCheck };
        Assert.Equal(SelectionFailure.SecureField, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, fake.Injections);
    }

    [Theory]
    [InlineData((int)FieldSafety.Unknown, SelectionFailure.SelectionUndetermined)]
    [InlineData((int)FieldSafety.WrongProcess, SelectionFailure.TargetChanged)]
    public async Task UnknownOrForeignFocusedElementsFailClosed(int fieldValue, SelectionFailure failure)
    {
        var field = (FieldSafety)fieldValue;
        var fake = new FakeServices { Safety = field };
        Assert.Equal(failure, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, fake.Injections);
    }

    [Fact]
    public async Task UnknownWithChangedForegroundIsTargetChanged()
    {
        var fake = new FakeServices { Safety = FieldSafety.Unknown };
        fake.OnSafetyRead = () => fake.Frontmost = false;
        Assert.Equal(SelectionFailure.TargetChanged, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
    }

    [Fact]
    public async Task UnknownWithModifiersHeldIsModifiersHeld()
    {
        var fake = new FakeServices { Safety = FieldSafety.Unknown, ModifiersHeld = true };
        Assert.Equal(SelectionFailure.ModifiersHeld, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
    }

    [Fact]
    public async Task UnknownOtherwiseIsUndeterminedWithCouldNotCaptureMessage()
    {
        var result = await new SelectionReader(new FakeServices { Safety = FieldSafety.Unknown }).ReadAsync(true, Target, TestContext.Current.CancellationToken);
        Assert.Equal(SelectionFailure.SelectionUndetermined, result.Failure);
        Assert.Equal("Couldn't capture selection", result.Message);
    }

    [Fact]
    public async Task CouldNotOpenThenTargetCopyLandsIsCapturedAndRestored()
    {
        var fake = new FakeServices();
        fake.CopyScript.Enqueue(new(null, 0, false, NotOpened: true));
        var result = await new SelectionReader(fake, copyDeadline: TimeSpan.FromSeconds(10)).ReadAsync(true, Target, TestContext.Current.CancellationToken);
        Assert.Equal("copied", result.Capture?.Text);
        Assert.Equal(1, fake.Restores);
    }

    [Fact]
    public async Task CouldNotOpenUntilDeadlineStillRestoresLateCopy()
    {
        var fake = new FakeServices();
        // The target releases the clipboard only for the late check (the sole read that asks for exactly 100 ms).
        fake.CopyFactory = remaining => remaining == TimeSpan.FromMilliseconds(100) ? new("late", 11, true) : new(null, 0, false, NotOpened: true);
        var result = await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken);
        Assert.Equal(SelectionFailure.NoSelection, result.Failure);
        Assert.Equal(1, fake.Restores);
    }

    [Fact]
    public async Task FailedRestoreIsRetriedUpToThreeAttempts()
    {
        var fake = new FakeServices { FailRestores = 2 };
        var result = await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken);
        Assert.Equal("copied", result.Capture?.Text);
        Assert.Equal(3, fake.Restores);
        Assert.True(fake.Restored);
    }

    [Fact]
    public async Task NotOpenedPastDeadlineSchedulesBackgroundRetry()
    {
        var fake = new FakeServices { CopyFactory = _ => new(null, 0, false, NotOpened: true) };
        var result = await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken);
        Assert.Equal(SelectionFailure.NoSelection, result.Failure);
        Assert.Equal(1, fake.RetriesScheduled);
        Assert.Equal(0, fake.Restores);
    }

    [Fact]
    public async Task NotOpenedWithCancellationBreaksToCleanup()
    {
        using var cancel = new CancellationTokenSource();
        var fake = new FakeServices { CopyFactory = _ => { cancel.Cancel(); return new(null, 0, false, NotOpened: true); } };
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var result = await new SelectionReader(fake).ReadAsync(true, Target, cancel.Token);
        Assert.Equal(SelectionFailure.Cancelled, result.Failure);
        Assert.True(clock.ElapsedMilliseconds < 400);
        Assert.Equal(1, fake.RetriesScheduled);
    }

    [Fact]
    public async Task ForeignOwnerCopyIsNeverRestored()
    {
        var fake = new FakeServices { TargetOwnsCopy = false };
        Assert.Equal(SelectionFailure.NoSelection, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, fake.Restores);
    }

    [Fact]
    public async Task HeldModifiersHaveBoundedWaitAndExactMessage()
    {
        var fake = new FakeServices { ModifiersHeld = true };
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var result = await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken);
        Assert.Equal(SelectionFailure.ModifiersHeld, result.Failure);
        Assert.Equal("Release the shortcut keys and try again", result.Message);
        Assert.InRange(clock.Elapsed.TotalMilliseconds, 180, 1500);
        Assert.Equal(0, fake.Injections);
    }

    [Fact]
    public async Task ModifierRepressDuringSnapshotPreventsInjection()
    {
        var fake = new FakeServices();
        fake.Hook = point => { if (point == SelectionCheckpoint.AfterSnapshot) fake.ModifiersHeld = true; return Task.CompletedTask; };
        Assert.Equal(SelectionFailure.ModifiersHeld, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, fake.Injections);
    }

    [Fact]
    public async Task SequenceChangeDuringSnapshotPreventsInjection()
    {
        var fake = new FakeServices();
        fake.Hook = point => { if (point == SelectionCheckpoint.AfterSnapshot) fake.ClipboardSequence++; return Task.CompletedTask; };
        Assert.Equal(SelectionFailure.ClipboardUnsafe, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, fake.Injections);
    }

    [Theory]
    [InlineData((int)SnapshotFailure.TooLarge, SelectionFailure.ClipboardTooLarge)]
    [InlineData((int)SnapshotFailure.TimedOut, SelectionFailure.ClipboardUnsafe)]
    [InlineData((int)SnapshotFailure.Unavailable, SelectionFailure.ClipboardUnsafe)]
    [InlineData((int)SnapshotFailure.Changed, SelectionFailure.ClipboardUnsafe)]
    public async Task UnsafeSnapshotsAbortBeforeInjection(int snapshotFailureValue, SelectionFailure failure)
    {
        var snapshotFailure = (SnapshotFailure)snapshotFailureValue;
        var fake = new FakeServices { SnapshotFailure = snapshotFailure };
        Assert.Equal(failure, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, fake.Injections);
    }

    [Theory]
    [InlineData((int)SelectionCheckpoint.AfterUia)]
    [InlineData((int)SelectionCheckpoint.AfterModifiers)]
    [InlineData((int)SelectionCheckpoint.AfterSnapshot)]
    [InlineData((int)SelectionCheckpoint.BeforeInjection)]
    [InlineData((int)SelectionCheckpoint.CopyObserved)]
    public async Task CancellationAtEveryCheckpointReleasesGateAndRestoresIfCopied(int checkpointValue)
    {
        var checkpoint = (SelectionCheckpoint)checkpointValue;
        using var token = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var fake = new FakeServices { Hook = point => { if (point == checkpoint) token.Cancel(); return Task.CompletedTask; } };
        Assert.Equal(SelectionFailure.Cancelled, (await new SelectionReader(fake).ReadAsync(true, Target, token.Token)).Failure);
        Assert.Equal(checkpoint == SelectionCheckpoint.CopyObserved ? 1 : 0, fake.Restores);
    }

    [Fact]
    public async Task NewerCopyIsNeitherReturnedNorOverwritten()
    {
        var fake = new FakeServices();
        fake.Hook = point => { if (point == SelectionCheckpoint.CopyObserved) fake.ClipboardSequence++; return Task.CompletedTask; };
        Assert.Equal(SelectionFailure.NoSelection, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(1, fake.Restores);
        Assert.False(fake.Restored);
        Assert.Equal(12U, fake.ClipboardSequence);
    }

    [Fact]
    public async Task ForeignClipboardOwnerDuringWaitIsNotCapturedOrRestored()
    {
        var fake = new FakeServices { TargetOwnsCopy = false };
        Assert.Equal(SelectionFailure.NoSelection, (await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, fake.Restores);
    }

    [Theory]
    [InlineData(0x2000U, 0x3000U, true)]
    [InlineData(0x3000U, 0x2000U, false)]
    [InlineData(0x2000U, 0x2000U, false)]
    [InlineData(null, 0x2000U, true)]
    [InlineData(0x2000U, null, true)]
    public void IntegrityComparisonIncludesInaccessibleTokens(uint? ours, uint? theirs, bool refuse) =>
        Assert.Equal(refuse, ElevationCheck.MustRefuse(ours, theirs));

    [Fact]
    public async Task ElevatedTargetRefusalHasCaptureAreaHint()
    {
        var fake = new FakeServices { Elevated = true };
        var result = await new SelectionReader(fake).ReadAsync(true, Target, TestContext.Current.CancellationToken);
        Assert.Equal("Can't capture from apps running as administrator", result.Message);
        Assert.Equal("Use Capture Area (Alt+Shift+S) instead", result.HintForCaptureArea("Alt+Shift+S"));
        Assert.Equal(0, fake.Injections);
    }

    [Theory]
    [InlineData(13U, 1U, true)]
    [InlineData(7U, 13U, true)]
    [InlineData(2U, 8U, true)]
    [InlineData(9U, 17U, true)]
    [InlineData(3U, 14U, true)]
    [InlineData(49152U, 13U, false)]
    [InlineData(8U, 13U, false)]
    public void SnapshotClassificationSkipsOnlyConversionFamilies(uint format, uint earlier, bool synthesized) =>
        Assert.Equal(synthesized, ClipboardSnapshot.IsSynthesized(format, new HashSet<uint> { earlier }));

    [Theory]
    [InlineData("Page — Microsoft Edge", "Page")]
    [InlineData("Page - Google Chrome", "Page")]
    [InlineData("Page – Mozilla Firefox", "Page")]
    [InlineData(null, "Example")]
    public void FrontmostSourceUsesCoreBrowserSuffixRules(string? title, string expected) =>
        Assert.Equal(expected, new FrontmostContext(1, 2, "Example", WindowTitle: title).SourceHeading);

    [Fact]
    public void MissingSourceIsUnknownAndNeverContainsUrl()
    {
        var context = new FrontmostContext(0, 0);
        Assert.Equal("Unknown source", context.SourceHeading);
        Assert.Null(context.Source.Url);
    }

    private sealed class FakeServices : ISelectionServices
    {
        public uint OwnPid => 7;
        internal bool Frontmost = true;
        internal bool Elevated;
        internal string? Text;
        internal FieldSafety Safety = FieldSafety.Safe;
        internal int PasswordAtCheck;
        private int checks;
        internal int Snapshots, Injections, Restores;
        internal bool Restored;
        internal bool TargetOwnsCopy = true;
        internal SnapshotFailure SnapshotFailure;
        internal Queue<ClipboardCopy> CopyScript = new();
        internal Func<TimeSpan, ClipboardCopy?>? CopyFactory;
        internal int FailRestores, RetriesScheduled;
        internal Action? OnSafetyRead;
        internal Func<SelectionCheckpoint, Task>? Hook;
        public bool ModifiersHeld { get; set; }
        public uint ClipboardSequence { get; set; } = 10;
        public long ClipboardSignal => 0;
        public bool IsFrontmost(FrontmostContext context) => Frontmost;
        public bool IsElevated(uint pid) => Elevated;
        public Task<UiaRead> ReadUiaAsync(uint pid, bool selection, CancellationToken token)
        {
            if (!selection) { checks++; OnSafetyRead?.Invoke(); }
            return Task.FromResult(new UiaRead(PasswordAtCheck == checks && checks > 0 ? FieldSafety.Password : Safety, selection ? Text : null));
        }
        public Task<SnapshotResult> SnapshotAsync(CancellationToken token)
        {
            Snapshots++;
            return Task.FromResult(SnapshotFailure == SnapshotFailure.None ? new SnapshotResult(new(ClipboardSequence, []), SnapshotFailure.None) : new(null, SnapshotFailure));
        }
        public bool InjectCopy() { Injections++; ClipboardSequence++; return true; }
        public Task<ClipboardCopy?> ReadCopyAsync(uint targetPid, TimeSpan remaining, ClipboardSnapshot snapshot) => Task.FromResult<ClipboardCopy?>(CopyFactory is not null ? CopyFactory(remaining) : CopyScript.Count > 0 ? CopyScript.Dequeue() : new("copied", ClipboardSequence, TargetOwnsCopy));
        public ClipboardRestore Restore(ClipboardSnapshot snapshot, uint sequence)
        {
            Restores++;
            var superseded = sequence != ClipboardSequence; // Distinct from a transient failure (FailRestores).
            Restored = !superseded && Restores > FailRestores;
            return new(Restored, TimeSpan.Zero, superseded);
        }
        public void ScheduleRestoreRetry(uint targetPid, ClipboardSnapshot snapshot) => RetriesScheduled++;
        public Task CheckpointAsync(SelectionCheckpoint checkpoint) => Hook?.Invoke(checkpoint) ?? Task.CompletedTask;
    }
}
