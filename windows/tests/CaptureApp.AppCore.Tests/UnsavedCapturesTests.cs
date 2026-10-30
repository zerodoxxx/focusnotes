using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class UnsavedCapturesTests
{
    [Fact]
    public async Task CommitsSaveInOrderAndAFailedOneIsKeptUntilTheDrain()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var ledger = pipeline.Unsaved;
        var gate = new TaskCompletionSource<CaptureJob>(TaskCreationOptions.RunContinuationsAsynchronously);
        var first = pipeline.PrepareText("firstneedle", new CaptureSource());
        var blocked = Path.Combine(pipeline.Vault.Root, "Blocked.md");
        Directory.CreateDirectory(blocked);
        var failing = pipeline.PrepareText("blockedneedle", new CaptureSource(), "Blocked");

        // The first commit is still preparing, so the later ones must wait for it.
        var firstCommit = ledger.Commit(first.Prepared.Capture.Id, gate.Task, job => pipeline.Commit(job));
        var failedCommit = ledger.Commit(failing.Prepared.Capture.Id, Task.FromResult(failing), job => pipeline.Commit(job));
        var second = pipeline.PrepareText("secondneedle", new CaptureSource());
        var secondCommit = ledger.Commit(second.Prepared.Capture.Id, Task.FromResult(second), job => pipeline.Commit(job));
        await Task.Delay(50, TestContext.Current.CancellationToken);
        Assert.False(failedCommit.IsCompleted || secondCommit.IsCompleted);
        gate.SetResult(first);
        await firstCommit;
        await Assert.ThrowsAnyAsync<IOException>(() => failedCommit);
        await secondCommit;
        Assert.Null(ledger.Tail);
        var inbox = File.ReadAllText(pipeline.Vault.InboxUrl);
        Assert.InRange(inbox.IndexOf("firstneedle", StringComparison.Ordinal), 0, inbox.IndexOf("secondneedle", StringComparison.Ordinal));
        Assert.Equal(failing.Prepared.Capture.Id, pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths())).Prepared.Capture.Id);

        Directory.Delete(blocked);
        await ledger.DrainAsync(job => pipeline.Commit(job), () => false);
        Assert.Contains("blockedneedle", File.ReadAllText(blocked), StringComparison.Ordinal);
        Assert.Empty(pipeline.Journal.RecordPaths());
    }

    [Fact]
    public async Task AnInFlightCommitIsNotARetryCandidate()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var ledger = pipeline.Unsaved;
        var gate = new TaskCompletionSource<CaptureJob>(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = pipeline.PrepareText("queuedneedle", new CaptureSource());
        var queuedCommit = ledger.Commit(queued.Prepared.Capture.Id, gate.Task, job => pipeline.Commit(job));
        Assert.Null(await ledger.FindRetryAsync(job => job.Prepared.Capture.Content == CaptureContent.Text("queuedneedle")));
        gate.SetResult(queued);
        await queuedCommit;
        Assert.Empty(pipeline.Journal.RecordPaths());
    }

    [Fact]
    public async Task AnEquivalentRetryReusesTheFailedCaptureId()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var ledger = pipeline.Unsaved;
        File.WriteAllText(pipeline.Journal.DirectoryPath, "block journal creation");
        var failed = pipeline.PrepareText("retryneedle", new CaptureSource());
        await Assert.ThrowsAnyAsync<IOException>(() => ledger.Commit(failed.Prepared.Capture.Id, Task.FromResult(failed), job => pipeline.Commit(job)));
        File.Delete(pipeline.Journal.DirectoryPath);

        var retry = Assert.IsType<CaptureJob>(await ledger.FindRetryAsync(job => job.Prepared.Capture.Content == CaptureContent.Text("retryneedle")));
        Assert.Equal(failed.Prepared.Capture.Id, retry.Prepared.Capture.Id);
        // The retry is claimed, so no second caller can take it.
        Assert.Null(await ledger.FindRetryAsync(job => job.Prepared.Capture.Content == CaptureContent.Text("retryneedle")));
        await ledger.Commit(retry.Prepared.Capture.Id, Task.FromResult(retry), job => pipeline.Commit(job));
        await ledger.DrainAsync(job => pipeline.Commit(job), () => false);
        Assert.Equal(1, File.ReadAllText(pipeline.Vault.InboxUrl).Split("retryneedle").Length - 1);
        Assert.Empty(pipeline.Journal.RecordPaths());
    }

    [Fact]
    public async Task ASupersededFailedCaptureIsDiscarded()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var ledger = pipeline.Unsaved;
        var blocked = Path.Combine(pipeline.Vault.Root, "Blocked.md");
        Directory.CreateDirectory(blocked);
        var failed = pipeline.PrepareText("supersededneedle", new CaptureSource(), "Blocked");
        await Assert.ThrowsAnyAsync<IOException>(() => ledger.Commit(failed.Prepared.Capture.Id, Task.FromResult(failed), job => pipeline.Commit(job)));
        Assert.Single(pipeline.Journal.RecordPaths());

        Assert.Null(await ledger.FindRetryAsync(_ => false, job => job.Prepared.Capture.Id == failed.Prepared.Capture.Id));
        Assert.Empty(pipeline.Journal.RecordPaths());
        Directory.Delete(blocked);
        await ledger.DrainAsync(job => pipeline.Commit(job), () => false);
        Assert.False(File.Exists(blocked));
    }

    [Fact]
    public async Task APreparedSessionCaptureIsSavedToTheRenamedNote()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var ledger = pipeline.Unsaved;
        var session = pipeline.Sessions.Start("Standup");
        // Prepared but neither recorded nor committed: only the ledger knows it targets the session note.
        var prepared = pipeline.PrepareText("renameneedle", new CaptureSource());
        Assert.Equal(pipeline.Vault.ManagedUrl(session.NotePath), prepared.Prepared.Destination.Url);
        Assert.Empty(pipeline.Journal.RecordPaths());

        var renamed = pipeline.RenameSession(new(session.Name, session.NotePath, DateTimeOffset.UtcNow), "Daily sync").Session;
        var saved = await ledger.Commit(prepared.Prepared.Capture.Id, Task.FromResult(prepared), job => pipeline.Commit(job));
        var newUrl = pipeline.Vault.ManagedUrl(renamed.NotePath);
        Assert.Equal(newUrl, saved.Destination.Url);
        Assert.Contains("renameneedle", File.ReadAllText(newUrl), StringComparison.Ordinal);
        Assert.Empty(pipeline.Journal.RecordPaths());
    }

    private static CapturePipeline Open(TempDirectory temp) => CapturePipeline.Open(
        Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
}
