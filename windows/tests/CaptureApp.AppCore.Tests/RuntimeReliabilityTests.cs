using System.Text;
using CaptureApp.AppCore;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class RuntimeReliabilityTests
{
    [Fact]
    public async Task TwoInstancesSendShowToThePrimaryAndReleaseTheLockOnDispose()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var temp = new TempDirectory();
        var showReceived = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using (var first = await SingleInstance.StartAsync(temp.Path, () => showReceived.TrySetResult(), cancellationToken))
        {
            Assert.NotNull(first);
            var second = await SingleInstance.StartAsync(temp.Path, cancellationToken: cancellationToken);
            Assert.Null(second);
            await showReceived.Task.WaitAsync(TimeSpan.FromSeconds(4), cancellationToken);
        }

        await using var replacement = await SingleInstance.StartAsync(temp.Path, cancellationToken: cancellationToken);
        Assert.NotNull(replacement);
    }

    [Fact]
    public async Task ShutdownWaitReturnsWhetherWorkDrainsBeforeItsDeadline()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var completes = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        completes.SetResult();
        Assert.True(await ShutdownWait.WaitAsync(completes.Task, DateTimeOffset.UtcNow.AddSeconds(1), cancellationToken: cancellationToken));

        var pending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            Assert.False(await ShutdownWait.WaitAsync(pending.Task, TimeSpan.FromMilliseconds(20), cancellationToken));
        }
        finally { pending.SetResult(); }
    }

    [Fact]
    public async Task WatcherChangeDuringInitialIndexPassSchedulesAnotherPass()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var temp = new TempDirectory();
        var vaultRoot = System.IO.Path.Combine(temp.Path, "vault");
        var state = System.IO.Path.Combine(temp.Path, "state");
        var vault = new Vault(vaultRoot, System.IO.Path.Combine(state, "external-notes.json"));
        vault.Prepare();
        using var index = new SearchIndex(vault, System.IO.Path.Combine(state, "index.sqlite"), TimeZoneInfo.Local);
        var firstPassCompleted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseFirstPass = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var passes = 0;
        async Task AfterSync()
        {
            if (Interlocked.Increment(ref passes) == 1)
            {
                firstPassCompleted.TrySetResult();
                await releaseFirstPass.Task;
            }
        }

        using var monitor = new VaultMonitor(vault, index, state, 0.06, afterIndexSyncForTesting: AfterSync);
        monitor.ChangeReceived += value =>
        {
            if (value.NotesChanged.Contains("During startup.md")) { changed.TrySetResult(); }
        };
        monitor.Start();
        var startupSync = monitor.SyncAsync();
        await firstPassCompleted.Task.WaitAsync(TimeSpan.FromSeconds(4), cancellationToken);
        var note = System.IO.Path.Combine(vaultRoot, "During startup.md");
        await File.WriteAllTextAsync(note, "# During startup\n\nstartupeventneedle\n", new UTF8Encoding(false), cancellationToken);
        await changed.Task.WaitAsync(TimeSpan.FromSeconds(4), cancellationToken);
        releaseFirstPass.TrySetResult();
        await startupSync.WaitAsync(TimeSpan.FromSeconds(4), cancellationToken);
        Assert.True(Volatile.Read(ref passes) >= 2);
        Assert.Contains(index.Search("startupeventneedle"), hit => hit.NotePath == "During startup.md");
    }

    [Fact]
    public async Task SelfTestRunsAppCoreSectionsEndToEndInATemporaryDirectory()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var temp = new TempDirectory();
        using var output = new StringWriter();
        await SelfTest.RunAsync(temp.Path, output: output, cancellationToken: cancellationToken);
        var report = output.ToString();
        Assert.Contains("PASS  pipeline opened", report, StringComparison.Ordinal);
        Assert.Contains("PASS  capture persisted to vault bytes", report, StringComparison.Ordinal);
        Assert.Contains("PASS  journal replayed exactly once", report, StringComparison.Ordinal);
        Assert.Contains("PASS  drafts and pins round-tripped", report, StringComparison.Ordinal);
        Assert.Contains("PASS  keyword index query passed", report, StringComparison.Ordinal);
        Assert.Contains("PASS  watcher change reindexed", report, StringComparison.Ordinal);
        Assert.Contains("PASS  shutdown drain passed", report, StringComparison.Ordinal);
        Assert.Contains("PASS  controller shutdown drain", report, StringComparison.Ordinal);
    }
}
