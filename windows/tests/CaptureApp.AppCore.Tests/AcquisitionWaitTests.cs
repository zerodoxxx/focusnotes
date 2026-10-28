using CaptureApp.AppCore.Shell;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class AcquisitionWaitTests
{
    private const string Needle = "acquired in session needle";

    [Fact]
    public async Task WaitReturnsAtOnceWhenNothingIsBeingAcquired()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        await coordinator.WaitForAcquisitionAsync().WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
    }

    // The controller's session commands run this drain, with WaitForAcquisitionAsync first, before they change the session.
    [Fact]
    public async Task EndingASessionWaitsForAnAcquisitionStartedInIt()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var session = await coordinator.StartSessionAsync("Thermo");
        var release = new TaskCompletionSource<PendingCapture?>(TaskCreationOptions.RunContinuationsAsynchronously);
        Assert.True(coordinator.BeginAcquisition(() => release.Task));

        var drain = Task.Run(async () =>
        {
            await coordinator.WaitForAcquisitionAsync();
            _ = coordinator.CommitPending();
            await coordinator.WaitForProcessingAsync();
            if (coordinator.CommitPending() is { } commit) { await commit; }
            await coordinator.WaitForCommitsAsync();
            await coordinator.EndSessionAsync(session);
        }, TestContext.Current.CancellationToken);
        await Task.Delay(100, TestContext.Current.CancellationToken);
        Assert.False(drain.IsCompleted);

        release.SetResult(PendingCaptures.Selection(Needle, new()));
        await drain.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.Null(pipeline.Sessions.Current());
        Assert.Contains(Needle, File.ReadAllText(pipeline.Vault.ManagedUrl(session.NotePath)), StringComparison.Ordinal);
        Assert.DoesNotContain(Needle, File.ReadAllText(pipeline.Vault.InboxUrl), StringComparison.Ordinal);
    }

    private static CapturePipeline Open(TempDirectory temp) => CapturePipeline.Open(
        Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
}
