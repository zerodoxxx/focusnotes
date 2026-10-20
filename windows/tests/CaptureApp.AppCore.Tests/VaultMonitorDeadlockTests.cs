using System.Text;
using CaptureApp.AppCore;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.AppCore.Tests;

/// Runs alone: its file churn and index syncs starve the timing-sensitive controller self-test on small CI runners.
[CollectionDefinition("VaultMonitorDeadlock", DisableParallelization = true)]
public sealed class VaultMonitorDeadlockCollection;

[Collection("VaultMonitorDeadlock")]
public sealed class VaultMonitorDeadlockTests
{
    [Fact]
    public async Task RefreshingExternalRootsWhileChangesDeliverDoesNotDeadlock()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var temp = new TempDirectory();
        var vaultRoot = System.IO.Path.Combine(temp.Path, "vault");
        var state = System.IO.Path.Combine(temp.Path, "state");
        var vault = new Vault(vaultRoot, System.IO.Path.Combine(state, "external-notes.json"));
        vault.Prepare();
        using var index = new SearchIndex(vault, System.IO.Path.Combine(state, "index.sqlite"), TimeZoneInfo.Local);
        using var monitor = new VaultMonitor(vault, index, state, 0.01);
        var deliveries = 0;
        monitor.ChangeReceived += _ => Interlocked.Increment(ref deliveries);
        monitor.Start();

        var work = Task.Run(async () =>
        {
            for (var i = 0; i < 60; i++)
            {
                await File.WriteAllTextAsync(System.IO.Path.Combine(vaultRoot, $"Note {i}.md"), $"# Note {i}\n\nbody\n", new UTF8Encoding(false));
                monitor.RefreshExternalRoots();
            }
        }, cancellationToken);
        var refresher = Task.Run(() =>
        {
            for (var i = 0; i < 120; i++) { monitor.RefreshExternalRoots(); }
        }, cancellationToken);

        await Task.WhenAll(work, refresher).WaitAsync(TimeSpan.FromSeconds(20), cancellationToken);
        Assert.True(monitor.IsRunning);
    }
}
