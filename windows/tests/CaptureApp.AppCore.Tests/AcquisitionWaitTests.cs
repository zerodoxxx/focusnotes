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
        using var pipeline = Open(temp);
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
        using var pipeline = Open(temp);
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
        if (next is not null)
        {
            Assert.NotEqual(session.NotePath, next.NotePath);
            Assert.DoesNotContain(Needle, File.ReadAllText(pipeline.Vault.ManagedUrl(next.NotePath)), StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task SubheadingLandsAfterAnAcquisitionStillInFlight()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var session = await coordinator.StartSessionAsync("Thermo");
        var release = new TaskCompletionSource<PendingCapture?>(TaskCreationOptions.RunContinuationsAsynchronously);
        Assert.True(coordinator.BeginAcquisition(() => release.Task));

        var subheading = Task.Run(() => coordinator.AddSubheadingAsync("Results"), TestContext.Current.CancellationToken);
        await Task.Delay(100, TestContext.Current.CancellationToken);
        Assert.False(subheading.IsCompleted);

        release.SetResult(PendingCaptures.Selection(Needle, new()));
        Assert.NotNull(await subheading.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
        var contents = File.ReadAllText(pipeline.Vault.ManagedUrl(session.NotePath));
        var needle = contents.IndexOf(Needle, StringComparison.Ordinal);
        Assert.True(needle >= 0 && needle < contents.IndexOf("Results", StringComparison.Ordinal));
    }

    [Fact]
    public async Task QuickNoteLandsAfterAnAcquisitionStillInFlight()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var session = await coordinator.StartSessionAsync("Thermo");
        var release = new TaskCompletionSource<PendingCapture?>(TaskCreationOptions.RunContinuationsAsynchronously);
        Assert.True(coordinator.BeginAcquisition(() => release.Task));

        var note = Task.Run(() => coordinator.AddNoteAsync("Quick results"), TestContext.Current.CancellationToken);
        await Task.Delay(100, TestContext.Current.CancellationToken);
        Assert.False(note.IsCompleted);

        release.SetResult(PendingCaptures.Selection(Needle, new()));
        Assert.NotNull(await note.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
        var contents = File.ReadAllText(pipeline.Vault.ManagedUrl(session.NotePath));
        var needle = contents.IndexOf(Needle, StringComparison.Ordinal);
        Assert.True(needle >= 0 && needle < contents.IndexOf("Quick results", StringComparison.Ordinal));
    }

    // A quit that begins while captures settle stops the session change.
    [Fact]
    public async Task QuitDuringSettleLeavesTheSessionUnchanged()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
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
        await termination.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
    }

    private static CapturePipeline Open(TempDirectory temp) => CapturePipeline.Open(
        Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
}
