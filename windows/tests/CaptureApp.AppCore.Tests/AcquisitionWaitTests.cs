using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class AcquisitionWaitTests
{
    private const string Needle = "acquired in session needle";

    [Fact]
    public async Task SettleReturnsAtOnceWhenNothingIsBeingAcquired()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        await coordinator.SettleCapturesAsync().WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
    }

    // Session operations settle in-flight captures themselves, so a capture taken in Thermo stays in Thermo.
    [Theory]
    [InlineData("end")]
    [InlineData("start")]
    [InlineData("folder")]
    [InlineData("resume")]
    public async Task SessionChangeWaitsForAnAcquisitionStartedInTheSession(string change)
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var earlier = change == "resume" ? await coordinator.StartSessionAsync("Kinetics") : null;
        var session = await coordinator.StartSessionAsync("Thermo");
        var release = new TaskCompletionSource<PendingCapture?>(TaskCreationOptions.RunContinuationsAsynchronously);
        Assert.True(coordinator.BeginAcquisition(() => release.Task));

        Task<Session?> operation = change switch
        {
            "end" => Task.Run(async () => { await coordinator.EndSessionAsync(session); return (Session?)null; }),
            "start" => Task.Run(async () => (Session?)await coordinator.StartSessionAsync("Kinetics")),
            "folder" => Task.Run(async () => (Session?)await coordinator.StartFolderSessionAsync("Work", "Kinetics")),
            _ => Task.Run(async () => (Session?)await coordinator.ResumeSessionAsync(
                new SessionCandidate(earlier!.Name, earlier.NotePath, DateTimeOffset.UtcNow))),
        };
        await Task.Delay(100, TestContext.Current.CancellationToken);
        Assert.False(operation.IsCompleted);

        release.SetResult(PendingCaptures.Selection(Needle, new()));
        var next = await operation.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.Contains(Needle, File.ReadAllText(pipeline.Vault.ManagedUrl(session.NotePath)), StringComparison.Ordinal);
        Assert.DoesNotContain(Needle, File.ReadAllText(pipeline.Vault.InboxUrl), StringComparison.Ordinal);
        if (change == "end")
        {
            Assert.Null(next);
        }
        else
        {
            Assert.NotNull(next);
            Assert.NotEqual(session.NotePath, next.NotePath);
            Assert.DoesNotContain(Needle, File.ReadAllText(pipeline.Vault.ManagedUrl(next.NotePath)), StringComparison.Ordinal);
        }
    }

    [Theory]
    [InlineData("subheading", "Results")]
    [InlineData("note", "Quick results")]
    public async Task EntryLandsAfterAnAcquisitionStillInFlight(string kind, string text)
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var session = await coordinator.StartSessionAsync("Thermo");
        var release = new TaskCompletionSource<PendingCapture?>(TaskCreationOptions.RunContinuationsAsynchronously);
        Assert.True(coordinator.BeginAcquisition(() => release.Task));

        var add = Task.Run(() => kind == "subheading" ? coordinator.AddSubheadingAsync(text) : coordinator.AddNoteAsync(text), TestContext.Current.CancellationToken);
        await Task.Delay(100, TestContext.Current.CancellationToken);
        Assert.False(add.IsCompleted);

        release.SetResult(PendingCaptures.Selection(Needle, new()));
        Assert.NotNull(await add.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
        var contents = File.ReadAllText(pipeline.Vault.ManagedUrl(session.NotePath));
        var needle = contents.IndexOf(Needle, StringComparison.Ordinal);
        var entry = contents.IndexOf(text, StringComparison.Ordinal);
        Assert.True(entry >= 0);
        Assert.InRange(needle, 0, entry - 1);
    }

    // A quit that begins while captures settle stops the session change.
    [Fact]
    public async Task QuitDuringSettleLeavesTheSessionUnchanged()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var session = await coordinator.StartSessionAsync("Thermo");
        var release = new TaskCompletionSource<PendingCapture?>(TaskCreationOptions.RunContinuationsAsynchronously);
        Assert.True(coordinator.BeginAcquisition(() => release.Task));

        var start = Task.Run(() => coordinator.StartSessionAsync("Kinetics"), TestContext.Current.CancellationToken);
        await Task.Delay(100, TestContext.Current.CancellationToken);
        var termination = coordinator.BeginTermination();
        release.SetResult(PendingCaptures.Selection(Needle, new()));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => start.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
        Assert.Equal(session.NotePath, pipeline.Sessions.Current()?.NotePath);
        Assert.True(await termination.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
    }
}
