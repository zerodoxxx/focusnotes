using CaptureApp.AppCore.Shell;
using CaptureApp.AppCore.Tests.Semantic;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.AppCore.Tests;

internal static class TestPipeline
{
    public static CapturePipeline Open(TempDirectory temp) => CapturePipeline.Open(
        Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);

    public static (string Root, string State, Vault Vault, SearchIndex Index) OpenIndexedVault(TempDirectory temp)
    {
        var root = Path.Combine(temp.Path, "vault");
        var state = Path.Combine(temp.Path, "state");
        var vault = new Vault(root, Path.Combine(state, "external-notes.json"));
        vault.Prepare();
        return (root, state, vault, new SearchIndex(vault, Path.Combine(state, "index.sqlite"), TimeZoneInfo.Local));
    }
}

internal static class RetryHold
{
    public static async Task HoldAsync(CaptureCoordinator coordinator, HeadlessCaptureHost host, PendingCapture capture, string title,
        string warning = Strings.CouldNotSaveToNote)
    {
        var commit = coordinator.CommitPending(title, true) ?? throw new InvalidOperationException("Capture was not pending.");
        await Assert.ThrowsAnyAsync<Exception>(() => commit);
        await Wait.Until(() => coordinator.PendingWithRetryWarning?.Id == capture.Id && Toasts(host).Any(toast => toast.Title == warning), "the retry warning");
    }

    public static AppToast[] Toasts(HeadlessCaptureHost host)
    {
        lock (host.Toasts) { return host.Toasts.ToArray(); }
    }
}
