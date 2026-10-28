using System.Text.RegularExpressions;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class RetryHoldTests
{
    private const string Needle = "retry hold needle";

    [Theory]
    [InlineData("..")]
    [InlineData("a/../b")]
    public async Task FailedTitleKeepsTheCapturePendingThroughTheErrorToast(string title)
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        var inboxBefore = File.ReadAllText(pipeline.Vault.InboxUrl);
        var capture = PendingCaptures.Selection(Needle, new());
        await coordinator.StageAsync(capture);
        await HoldAsync(coordinator, host, capture, title);

        // The warning says the capture was kept and never claims it was not saved.
        var warning = Assert.Single(Toasts(host), toast => toast.Title == Strings.CouldNotSaveToNote);
        Assert.Contains("Capture kept", warning.Subtitle, StringComparison.Ordinal);
        Assert.DoesNotContain(Toasts(host), toast => toast.Title == Strings.CouldNotSaveCapture
            || toast.Subtitle?.Contains("not saved", StringComparison.Ordinal) == true);
        Assert.Equal(inboxBefore, File.ReadAllText(pipeline.Vault.InboxUrl));

        // Implicit commits, including the one inside every other toast, leave it alone.
        Assert.Null(coordinator.CommitPending());
        coordinator.ShowToast(new(AppToastStyle.Success, "Unrelated"));
        Assert.Equal(capture.Id, coordinator.Pending?.Id);
        Assert.Null(coordinator.PendingWithRetryWarning);
        Assert.Equal(inboxBefore, File.ReadAllText(pipeline.Vault.InboxUrl));

        // A valid explicit title saves it once and clears the hold.
        var saved = await coordinator.CommitPending("science/Biology", true)!;
        Assert.Equal(Path.Combine(pipeline.Vault.Root, "science", "Biology.md"), saved.Destination.Url);
        Assert.Null(coordinator.Pending);
        Assert.Single(Regex.Matches(File.ReadAllText(saved.Destination.Url), Regex.Escape(Needle)));
        Assert.Equal(inboxBefore, File.ReadAllText(pipeline.Vault.InboxUrl));
        Assert.Null(coordinator.CommitPending());
    }

    [Fact]
    public async Task AmbiguousTitleKeepsTheCaptureAndAnExplicitNameSavesIt()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        File.WriteAllText(Path.Combine(pipeline.Vault.Root, "Ideas.md"), "# Ideas\n");
        File.WriteAllText(Path.Combine(pipeline.Vault.Root, "Ideas 2.md"), "# Ideas\n");
        var inboxBefore = File.ReadAllText(pipeline.Vault.InboxUrl);
        var capture = PendingCaptures.Selection(Needle, new());
        await coordinator.StageAsync(capture);
        await HoldAsync(coordinator, host, capture, " ideas ", Strings.SeveralNotesTitled("Ideas"));

        var warning = Assert.Single(Toasts(host), toast => toast.Title == Strings.SeveralNotesTitled("Ideas"));
        Assert.Contains("pick one by its path", warning.Subtitle, StringComparison.Ordinal);
        Assert.Equal(inboxBefore, File.ReadAllText(pipeline.Vault.InboxUrl));
        Assert.Equal(capture.Id, coordinator.Pending?.Id);

        var saved = await coordinator.CommitPending("Ideas 2", true)!;
        Assert.Equal(Path.Combine(pipeline.Vault.Root, "Ideas 2.md"), saved.Destination.Url);
        Assert.Single(Regex.Matches(File.ReadAllText(saved.Destination.Url), Regex.Escape(Needle)));
        Assert.DoesNotContain(Needle, File.ReadAllText(Path.Combine(pipeline.Vault.Root, "Ideas.md")), StringComparison.Ordinal);
        Assert.Equal(inboxBefore, File.ReadAllText(pipeline.Vault.InboxUrl));
    }

    [Fact]
    public async Task EscapeKeepsAHeldCaptureAndShowsItsWarningAgain()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        var capture = PendingCaptures.Selection(Needle, new());
        await coordinator.StageAsync(capture);
        await HoldAsync(coordinator, host, capture, "..");
        coordinator.ShowToast(new(AppToastStyle.Success, "Unrelated"));
        Assert.Null(coordinator.PendingWithRetryWarning);

        coordinator.SettleUnchosenCapture(capture.Id, false);
        Assert.Equal(capture.Id, coordinator.PendingWithRetryWarning?.Id);
        Assert.Equal(Strings.ChooseWhereToSave, Toasts(host)[^1].Title);
        Assert.DoesNotContain(Needle, File.ReadAllText(pipeline.Vault.InboxUrl), StringComparison.Ordinal);

        // A capture that was never held still saves to its default on Escape.
        var plain = PendingCaptures.Selection("plain escape capture", new());
        await coordinator.StageAsync(plain);
        coordinator.SettleUnchosenCapture(plain.Id, false);
        Assert.Null(coordinator.Pending);
        await coordinator.WaitForCommitsAsync();
        Assert.Contains("plain escape capture", File.ReadAllText(pipeline.Vault.InboxUrl), StringComparison.Ordinal);
    }

    [Fact]
    public async Task QuitSavesAHeldCaptureToItsStagedDefault()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        var capture = PendingCaptures.Selection(Needle, new());
        await coordinator.StageAsync(capture);
        await HoldAsync(coordinator, host, capture, "..");

        Assert.True(await coordinator.BeginTermination());
        Assert.Null(coordinator.Pending);
        Assert.Single(Regex.Matches(File.ReadAllText(pipeline.Vault.InboxUrl), Regex.Escape(Needle)));
    }

    [Fact]
    public async Task NewerCaptureSavesAHeldCaptureToItsDefaultFirst()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        var capture = PendingCaptures.Selection(Needle, new());
        await coordinator.StageAsync(capture);
        await HoldAsync(coordinator, host, capture, "..");

        var newer = PendingCaptures.Selection("newer capture", new());
        await coordinator.StageAsync(newer);
        Assert.Equal(newer.Id, coordinator.Pending?.Id);
        Assert.Null(coordinator.PendingWithRetryWarning);
        Assert.Single(Regex.Matches(File.ReadAllText(pipeline.Vault.InboxUrl), Regex.Escape(Needle)));
        Assert.DoesNotContain("newer capture", File.ReadAllText(pipeline.Vault.InboxUrl), StringComparison.Ordinal);
    }

    private static async Task HoldAsync(CaptureCoordinator coordinator, HeadlessCaptureHost host, PendingCapture capture, string title,
        string warning = Strings.CouldNotSaveToNote)
    {
        var commit = coordinator.CommitPending(title, true) ?? throw new InvalidOperationException("Capture was not pending.");
        await Assert.ThrowsAnyAsync<Exception>(() => commit);
        await WaitUntil(() => coordinator.PendingWithRetryWarning?.Id == capture.Id && Toasts(host).Any(toast => toast.Title == warning));
    }

    private static AppToast[] Toasts(HeadlessCaptureHost host)
    {
        lock (host.Toasts) { return host.Toasts.ToArray(); }
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "Timed out waiting for the retry warning.");
            await Task.Delay(10);
        }
    }

    private static CapturePipeline Open(TempDirectory temp) => CapturePipeline.Open(
        Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
}
