using System.Diagnostics;
using System.Text;
using CaptureApp.Platform.Context;
using CaptureApp.Platform.Selection;
using Xunit;

namespace CaptureApp.Platform.Tests.Selection;

[Collection("Selection")]
[Trait("Needs", "InteractiveDesktop")]
public sealed class SelectionRaceTests
{
    [Fact]
    public async Task A_OtherCopyDuringWaitIsIntactAndNotRestored()
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await using var other = await HelperTarget.StartAsync();
        await target.CommandAsync("seed");
        await target.CommandAsync("mode", "ignore");
        await target.FocusAsync();
        var injected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var services = new InstrumentedServices { OnInjected = () => injected.SetResult() };
        // This checks ownership during an in-flight capture; allow time to exercise the competing copy.
        var read = new SelectionReader(services, copyDeadline: TimeSpan.FromSeconds(5))
            .ReadAsync(true, target.Context, TestContext.Current.CancellationToken);
        // Report an early safety refusal directly instead of timing out on an injection that never happened.
        await Task.WhenAny(injected.Task, read).WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        if (!injected.Task.IsCompleted)
        {
            var refused = await read;
            Assert.Fail($"Selection returned before injection: {refused.Failure} at {refused.Detail}.");
        }
        // Run the second process's copy after SendInput while capture is still waiting.
        Assert.False(read.IsCompleted, "Capture finished before the competing copy; the race was not exercised.");
        await other.CommandAsync("copy", "newer during wait");
        var result = await read;
        Assert.Equal(SelectionFailure.NoSelection, result.Failure);
        Assert.Equal("newer during wait", Text(await other.CommandAsync("dump")));
        Assert.Empty(services.Restorations);
    }

    [Theory]
    [InlineData("AfterUia")]
    [InlineData("AfterModifiers")]
    [InlineData("AfterSnapshot")]
    [InlineData("BeforeInjection")]
    public async Task B_FocusSwitchPreventsInjection(string checkpoint)
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await using var other = await HelperTarget.StartAsync();
        // Start from a known, live-owned plain clipboard (earlier tests leave arbitrary owners/formats behind).
        await target.CommandAsync("seed");
        var token = TestContext.Current.CancellationToken;
        var services = new InstrumentedServices();
        var hookObserved = false;
        services.Hook = async point =>
        {
            if (point.ToString() == checkpoint)
            {
                hookObserved = true;
                await other.FocusAsync();
            }
        };

        SelectionResult? result = null;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            await target.FocusAsync();
            result = await new SelectionReader(services).ReadAsync(true, target.Context, token);
            if (result.Failure != SelectionFailure.SelectionUndetermined || result.Detail != "G3 entry" || hookObserved) break;
            Assert.Equal(0, services.Injections);
            if (!services.IsFrontmost(target.Context)) break;
            if (attempt < 2) await Task.Delay(100, token);
        }

        Assert.True(hookObserved, $"Focus-switch hook {checkpoint} was not reached ({result?.Failure} at {result?.Detail}).");
        Assert.True(result?.Failure == SelectionFailure.TargetChanged, $"{result?.Failure} at {result?.Detail}");
        Assert.Equal(0, services.Injections);
        Assert.Equal(0, (await target.CommandAsync("mode", "normal")).Copies);
    }

    [Theory]
    [InlineData(0x10)]
    [InlineData(0x11)]
    [InlineData(0x12)]
    [InlineData(0x5b)]
    [InlineData(0x5c)]
    public async Task C_ModifiersHeldPastDeadlinePreventInjection(int key)
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await target.FocusAsync();
        await target.CommandAsync("modifiers", key.ToString());
        var services = new InstrumentedServices();
        SelectionResult result;
        try { result = await new SelectionReader(services).ReadAsync(true, target.Context, TestContext.Current.CancellationToken); }
        finally { await target.CommandAsync("release-modifiers"); }
        Assert.True(result.Failure == SelectionFailure.ModifiersHeld, $"{result.Failure} at {result.Detail}");
        Assert.Equal("Release the shortcut keys and try again", result.Message);
        Assert.Equal(0, services.Injections);
    }

    [Theory]
    [InlineData(0x11)]
    [InlineData(0x12)]
    public async Task ModifierReleaseAfterNormalHotkeyHoldCapturesAndRestoresClipboard(int key)
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await target.CommandAsync("seed");
        var original = await target.CommandAsync("dump");
        await target.FocusAsync();
        var token = TestContext.Current.CancellationToken;
        var services = new InstrumentedServices();
        Task? release = null;
        var injectionsBeforeRelease = -1;
        var held = Stopwatch.StartNew();
        TimeSpan heldFor = default;
        services.Hook = async point =>
        {
            if (point != SelectionCheckpoint.AfterUia) return;
            // Start the physical hold after initial UIA setup, so slow fixture startup
            // cannot accidentally release the key before the modifier wait is exercised.
            await target.CommandAsync("modifiers", key.ToString(System.Globalization.CultureInfo.InvariantCulture));
            Assert.True(services.ModifiersHeld, "The native keydown must be visible to GetAsyncKeyState.");
            held.Restart();
            release = ReleaseLaterAsync();
        };
        async Task ReleaseLaterAsync()
        {
            await Task.Delay(TimeSpan.FromMilliseconds(450), token);
            injectionsBeforeRelease = Volatile.Read(ref services.Injections);
            heldFor = held.Elapsed;
            await target.CommandAsync("release-modifiers");
        }

        SelectionResult result;
        try
        {
            result = await new SelectionReader(services).ReadAsync(true, target.Context, token);
            if (release is not null) await release;
        }
        finally
        {
            // Always release our synthetic modifier, including assertion/cancellation failures.
            try { if (release is not null) await release; }
            finally { await target.CommandAsync("release-modifiers"); }
        }
        Assert.NotNull(release);
        Assert.True(heldFor >= TimeSpan.FromMilliseconds(400), "Exercise a natural hold beyond the former 200 ms deadline.");
        Assert.Equal(0, injectionsBeforeRelease);
        Assert.True(result.IsSuccess, $"Selection refused after modifier release: {result.Failure} at {result.Detail}.");
        Assert.Equal("first selected text", result.Capture?.Text);
        Assert.Equal(SelectionMethod.Clipboard, result.Capture?.Method);
        Assert.Equal(1, services.Injections);
        Assert.False(services.ModifiersHeld);
        AssertSnapshot(original, await target.CommandAsync("dump"));
        Assert.True(Assert.Single(services.Restorations).Restored);
    }

    [Fact]
    public async Task D_DelayedCopyCapturesTextAndRestoresEveryNativeFormat()
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await target.CommandAsync("seed");
        var original = await target.CommandAsync("dump");
        await target.CommandAsync("mode", "delayed");
        await target.FocusAsync();
        var services = new InstrumentedServices();
        var result = await new SelectionReader(services).ReadAsync(true, target.Context, TestContext.Current.CancellationToken);
        Assert.Equal("delayed selected text", result.Capture?.Text);
        Assert.Equal(SelectionMethod.Clipboard, result.Capture?.Method);
        AssertSnapshot(original, await target.CommandAsync("dump"));
        Assert.True(Assert.Single(services.Restorations).Restored);
    }

    [Fact]
    public async Task E_ClipboardHeldByOtherProcessHasBoundedRetryAndNoMutation()
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await using var other = await HelperTarget.StartAsync();
        await target.CommandAsync("seed");
        var original = await target.CommandAsync("dump");
        await target.FocusAsync();
        Assert.True((await other.CommandAsync("hold")).Holding);
        var services = new InstrumentedServices();
        SelectionResult result;
        try { result = await new SelectionReader(services).ReadAsync(true, target.Context, TestContext.Current.CancellationToken)
            .WaitAsync(TimeSpan.FromSeconds(30), TestContext.Current.CancellationToken); }
        finally { await other.CommandAsync("release"); }
        Assert.Equal(SelectionFailure.ClipboardUnsafe, result.Failure);
        Assert.Equal("Couldn't capture selection", result.Message);
        Assert.Equal(0, services.Injections);
        AssertSnapshot(original, await target.CommandAsync("dump"), expectRestoreFlags: false);
    }

    [Fact]
    public async Task F_OwnPanelIsRejected()
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await desktop.FocusAsync();
        var result = await new SelectionReader().ReadAsync(true, new(desktop.Handle, (uint)Environment.ProcessId), TestContext.Current.CancellationToken);
        Assert.Equal(SelectionFailure.OwnApp, result.Failure);
        Assert.Null(result.Message);
    }

    [Fact]
    public async Task G_PasswordFieldIsRejected()
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await target.FocusAsync("password");
        var services = new InstrumentedServices();
        Assert.Equal(SelectionFailure.SecureField, (await new SelectionReader(services).ReadAsync(true, target.Context, TestContext.Current.CancellationToken)).Failure);
        Assert.Equal(0, services.Injections);
    }

    [Fact]
    public async Task H_ElevatedTargetRequiresHigherIntegrityHelper()
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        var own = ElevationCheck.ReadIntegrity((uint)Environment.ProcessId);
        Assert.Skip(own >= 0x3000
            ? "Runner is already high integrity; a higher-integrity helper cannot be launched. Fake-token comparison is covered; real elevated target is step 11."
            : "A higher-integrity helper requires an interactive UAC grant; unattended elevation is unavailable. Fake-token comparison is covered; real elevated target is step 11.");
    }

    [Fact]
    public async Task I_ThousandCapturesRestoreByteIdenticalFormatsAndReportHoldTimes()
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await target.CommandAsync("seed");
        var original = await target.CommandAsync("dump");
        await target.FocusAsync();
        var services = new InstrumentedServices();
        var reader = new SelectionReader(services);
        for (var iteration = 0; iteration < 1000; iteration++)
        {
            var result = await reader.ReadAsync(true, target.Context, TestContext.Current.CancellationToken);
            Assert.True(result.IsSuccess, $"Capture {iteration}: {result.Failure}");
            Assert.Equal("first selected text", result.Capture!.Text);
            AssertSnapshot(original, await target.CommandAsync("dump"));
        }
        Assert.Equal(1000, services.Restorations.Count);
        Assert.All(services.Restorations, result => Assert.True(result.Restored));
        var holds = services.Restorations.Select(result => result.HoldTime.TotalMilliseconds).Order().ToArray();
        TestContext.Current.TestOutputHelper?.WriteLine($"Clipboard restore hold p99 was {holds[989]:F3} ms across {holds.Length} captures.");
        if (Environment.GetEnvironmentVariable("FOCUSNOTES_PERF_GATES") == "1")
        {
            Assert.True(holds[989] <= 10, $"Clipboard restore hold p99 was {holds[989]:F3} ms (limit 10 ms)");
        }
    }

    [Fact]
    public async Task J_CopyStormDuringRestoreNeverMixesFormatsOrOverwritesNewerCopy()
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await using var other = await HelperTarget.StartAsync();
        for (var iteration = 0; iteration < 50; iteration++)
        {
            await target.CommandAsync("seed");
            var original = await target.CommandAsync("dump");
            await target.FocusAsync();
            var attemptedWhileLocked = 0;
            var services = new InstrumentedServices
            {
                WhileRestoreLocked = () =>
                {
                    _ = other.CommandAsync("storm").GetAwaiter().GetResult();
                    var deadline = Stopwatch.StartNew();
                    while (deadline.Elapsed < TimeSpan.FromSeconds(1))
                    {
                        var state = other.CommandAsync("state").GetAwaiter().GetResult();
                        if (state.StormAttempts > 0) { attemptedWhileLocked = state.StormAttempts; break; }
                        Thread.Yield();
                    }
                }
            };
            _ = await new SelectionReader(services).ReadAsync(true, target.Context, TestContext.Current.CancellationToken);
            Assert.True(attemptedWhileLocked > 0, "The second process must attempt OpenClipboard while restore holds the lock.");
            var stopped = await other.CommandAsync("stop");
            var final = await other.CommandAsync("dump");
            if (stopped.StormCopies == 0) AssertSnapshot(original, final);
            else
            {
                var expected = $"storm:{stopped.StormCopies}";
                Assert.Equal(expected, Text(final));
                var rich = NativeMethods.RegisterClipboardFormat("CaptureApp.Test.Rich");
                Assert.Equal(expected + '\0', Encoding.UTF8.GetString(Convert.FromBase64String(final.Formats![rich])));
                Assert.False(final.Formats.ContainsKey(NativeMethods.RegisterClipboardFormat("HTML Format")));
            }
        }
    }

    [Theory]
    [InlineData("large")]
    [InlineData("unreadable")]
    public async Task K_UnsafeNativeFormatAbortsBeforeInjectionAndLeavesClipboardUntouched(string mode)
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await target.CommandAsync(mode);
        var sequence = NativeMethods.GetClipboardSequenceNumber();
        await target.FocusAsync();
        var services = new InstrumentedServices();
        var result = await new SelectionReader(services).ReadAsync(true, target.Context, TestContext.Current.CancellationToken);
        Assert.Contains(result.Failure, new SelectionFailure?[] { SelectionFailure.ClipboardTooLarge, SelectionFailure.ClipboardUnsafe });
        Assert.Equal("Couldn't capture selection", result.Message);
        Assert.Equal(0, services.Injections);
        Assert.Equal(sequence, NativeMethods.GetClipboardSequenceNumber());
        if (mode == "large")
        {
            Assert.Equal(SelectionFailure.ClipboardTooLarge, result.Failure);
            Assert.Equal("Your clipboard is too large to restore safely", result.Hint);
            var dump = await target.CommandAsync("dump");
            var bytes = Convert.FromBase64String(Assert.Single(dump.Formats!).Value);
            Assert.Equal(100 * 1024 * 1024, bytes.Length);
            Assert.True(bytes.All(value => value == 0));
        }
    }

    [Fact]
    public async Task RealUiaSelectionUsesFocusedProcessAndContext()
    {
        await using var desktop = await DesktopProbe.RequireAsync();
        await using var target = await HelperTarget.StartAsync();
        await target.FocusAsync("second");
        var context = FrontmostContext.Capture();
        Assert.Equal(target.Context.WindowHandle, context.WindowHandle);
        Assert.Equal(target.Context.ProcessIdentifier, context.ProcessIdentifier);
        Assert.Equal("Selection fixture", context.SourceHeading);
        Assert.False(string.IsNullOrEmpty(context.ExecutablePath));
        var services = new InstrumentedServices { SuppressSelection = false };
        var result = await new SelectionReader(services).ReadAsync(context: context, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal("second selected text", result.Capture?.Text);
        Assert.Equal(SelectionMethod.UiAutomation, result.Capture?.Method);
        Assert.Equal(0, services.Injections);
    }

    private static string Text(TargetResponse state) => Encoding.Unicode.GetString(Convert.FromBase64String(state.Formats![13])).TrimEnd('\0');
    private static void AssertSnapshot(TargetResponse original, TargetResponse actual, bool expectRestoreFlags = true)
    {
        foreach (var pair in original.Formats!) Assert.Equal(pair.Value, actual.Formats![pair.Key]);
        if (!expectRestoreFlags) { Assert.Equal(original.Formats.Count, actual.Formats!.Count); return; }
        foreach (var name in new[] { "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard" })
        {
            var id = NativeMethods.RegisterClipboardFormat(name);
            Assert.Equal(new byte[4], Convert.FromBase64String(actual.Formats![id]));
        }
    }
}
