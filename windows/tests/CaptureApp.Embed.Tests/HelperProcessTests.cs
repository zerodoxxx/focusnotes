using System.Diagnostics;
using Xunit;

namespace CaptureApp.Embed.Tests;

/// Lifecycle tests that never load a model, so they run without the semantic models.
public sealed class HelperProcessTests
{
    private static async Task<bool> WaitUntil(Func<bool> condition, TimeSpan timeout)
    {
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < timeout)
        {
            if (condition())
            {
                return true;
            }

            await Task.Delay(50);
        }

        return condition();
    }

    [Fact]
    public async Task PingStartsTheHelperWithoutLoadingModels()
    {
        using var temp = new TempDirectory();
        await using var client = new EmbedClient(Helper.Path, temp.Path);
        Assert.Null(client.ProcessId());
        var response = await client.PingAsync();
        Assert.False(response.VisionLoaded);
        Assert.Equal(client.ProcessId(), response.ProcessId);
        Assert.Equal(response.ProcessId, (await client.PingAsync()).ProcessId);
    }

    [Fact]
    public async Task HelperExitsWhenIdle()
    {
        using var temp = new TempDirectory();
        await using var client = new EmbedClient(Helper.Path, temp.Path, idleSeconds: 1);
        await client.PingAsync();
        Assert.True(await WaitUntil(() => client.ProcessId() is null, TimeSpan.FromSeconds(10)), "helper did not exit after the idle timeout");
        // The next request transparently starts a fresh helper.
        var restarted = await client.PingAsync();
        Assert.Equal(client.ProcessId(), restarted.ProcessId);
    }

    [Fact]
    public async Task ACrashedHelperIsRestartedOnTheNextRequest()
    {
        using var temp = new TempDirectory();
        await using var client = new EmbedClient(Helper.Path, temp.Path);
        var first = (await client.PingAsync()).ProcessId;
        using (var victim = Process.GetProcessById(first))
        {
            victim.Kill();
            await victim.WaitForExitAsync();
        }

        var second = (await client.PingAsync()).ProcessId;
        Assert.NotEqual(first, second);
    }

    [Fact]
    public async Task ModelErrorsAreReportedAndTheHelperSurvives()
    {
        using var temp = new TempDirectory();
        await using var client = new EmbedClient(Helper.Path, temp.Path);
        var pid = (await client.PingAsync()).ProcessId;
        var error = await Assert.ThrowsAsync<EmbeddingException>(() => client.EmbedQueryAsync("hello"));
        Assert.Equal(EmbeddingErrorKind.Runtime, error.Kind);
        Assert.Equal(pid, (await client.PingAsync()).ProcessId);
    }

    [Fact]
    public async Task CloseStopsTheHelperAndRejectsNewWork()
    {
        using var temp = new TempDirectory();
        var client = new EmbedClient(Helper.Path, temp.Path);
        var pid = (await client.PingAsync()).ProcessId;
        await client.CloseAsync();
        Assert.Null(client.ProcessId());
        Assert.True(await WaitUntil(() => !Process.GetProcesses().Any(p => p.Id == pid), TimeSpan.FromSeconds(5)));
        var error = await Assert.ThrowsAsync<EmbeddingException>(() => client.PingAsync());
        Assert.Equal(EmbeddingErrorKind.Transport, error.Kind);
    }

    [Fact]
    public async Task CancellingBeforeTheWireLeavesFramingIntact()
    {
        using var temp = new TempDirectory();
        await using var client = new EmbedClient(Helper.Path, temp.Path);
        await client.PingAsync();
        using var cancelled = new CancellationTokenSource();
        await cancelled.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.PingAsync(cancelled.Token));
        await Task.Delay(100);
        Assert.Equal(0, client.PendingRequestCountForTesting);
        Assert.NotNull(client.ProcessId());
        Assert.Equal(client.ProcessId(), (await client.PingAsync()).ProcessId);
    }

    [Fact]
    public async Task StatusReportsTheBackgroundModeFlagsForThisPlatform()
    {
        using var temp = new TempDirectory();
        await using var client = new EmbedClient(Helper.Path, temp.Path);
        var status = await client.StatusAsync();
        if (OperatingSystem.IsWindows())
        {
            Assert.Equal((true, true, true), (status.EcoQos, status.BelowNormal, status.BackgroundMode));
        }
        else
        {
            Assert.Equal((null, null, null), (status.EcoQos, status.BelowNormal, status.BackgroundMode));
        }
    }

    [Fact]
    public async Task SelfTestExitsZeroAndPrintsTheStatusReply()
    {
        var info = new ProcessStartInfo { RedirectStandardOutput = true, UseShellExecute = false };
        if (Helper.Path.EndsWith(".dll", StringComparison.Ordinal))
        {
            info.FileName = "dotnet";
            info.ArgumentList.Add(Helper.Path);
        }
        else
        {
            info.FileName = Helper.Path;
        }

        info.ArgumentList.Add("--self-test");
        using var process = Process.Start(info)!;
        var output = await process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync();
        Assert.Equal(0, process.ExitCode);
        var reply = EmbedProtocol.DecodeLine<EmbedResponse>(System.Text.Encoding.UTF8.GetBytes(output.Trim()));
        Assert.Equal("self-test", reply.Id);
    }

    [Fact]
    public async Task HelperExitsWhenItsParentProcessDies()
    {
        using var temp = new TempDirectory();
        Process Start(params string[] arguments)
        {
            var info = new ProcessStartInfo { RedirectStandardInput = true, RedirectStandardOutput = true, UseShellExecute = false };
            if (Helper.Path.EndsWith(".dll", StringComparison.Ordinal))
            {
                info.FileName = "dotnet";
                info.ArgumentList.Add(Helper.Path);
            }
            else
            {
                info.FileName = Helper.Path;
            }

            foreach (var argument in arguments)
            {
                info.ArgumentList.Add(argument);
            }

            return Process.Start(info)!;
        }

        using var parent = Start("--models", temp.Path, "--idle-seconds", "86400");
        using var child = Start("--models", temp.Path, "--idle-seconds", "86400", "--parent-pid", parent.Id.ToString());
        try
        {
            await Task.Delay(500);
            Assert.False(child.HasExited);
            parent.Kill();
            await parent.WaitForExitAsync();
            Assert.True(await WaitUntil(() => child.HasExited, TimeSpan.FromSeconds(10)), "helper outlived its parent");
        }
        finally
        {
            if (!child.HasExited)
            {
                child.Kill();
            }
        }
    }
}
