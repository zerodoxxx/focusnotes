using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class TypedNoteSaveTests
{
    [Fact]
    public async Task SaveAsNewReplacesAFailedAppendBeforeReplay()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        const string draft = "# Blocked\n\nreplacementneedle";
        // An existing directory at the file path makes the append fail after its intent is journaled.
        var blocked = Path.Combine(pipeline.Vault.Root, "Blocked.md");
        Directory.CreateDirectory(blocked);
        await Assert.ThrowsAnyAsync<IOException>(() => coordinator.AddNoteAsync(draft));
        // A failed save must not leave a faulted tail that every later note open rethrows.
        Assert.Null(coordinator.CommitTail);
        var oldRecord = Assert.Single(pipeline.Journal.RecordPaths());
        var old = pipeline.Journal.Load(oldRecord);
        Assert.Null(old.Prepared.CreatesNote);
        Assert.Equal(draft, pipeline.Drafts.Load());

        var saved = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync(draft, newNote: true));
        Assert.Equal("Blocked 2.md", Path.GetFileName(saved.Destination.Url));
        Assert.NotEqual(old.Prepared.Capture.Id, saved.CaptureId);
        Assert.Empty(pipeline.Journal.RecordPaths());
        Directory.Delete(blocked);
        File.WriteAllText(blocked, "# Original\n");
        Assert.Equal(0, await pipeline.ReplayUnsavedAsync(TestContext.Current.CancellationToken));
        Assert.Equal("# Original\n", File.ReadAllText(blocked));
        Assert.Single(pipeline.Index.Search("replacementneedle"));
        Assert.Empty(pipeline.Drafts.Load());
    }

    [Fact]
    public async Task SaveAsNewRetriesTheSameReservedPathWhenJournalingFailed()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        const string draft = "# Existing\n\nretryneedle";
        File.WriteAllText(Path.Combine(pipeline.Vault.Root, "Existing.md"), "# Existing\n");
        File.WriteAllText(pipeline.Journal.DirectoryPath, "block journal creation");
        await Assert.ThrowsAnyAsync<IOException>(() => coordinator.AddNoteAsync(draft, newNote: true));
        Assert.Null(coordinator.CommitTail);
        var reserved = Assert.Single(pipeline.Service.ReservedNoteUrls);
        Assert.Equal("Existing 2.md", Path.GetFileName(reserved));
        File.Delete(pipeline.Journal.DirectoryPath);

        var saved = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync(draft, newNote: true));
        Assert.Equal(reserved, saved.Destination.Url);
        Assert.False(File.Exists(Path.Combine(pipeline.Vault.Root, "Existing 3.md")));
        Assert.Equal(1, File.ReadAllText(reserved).Split("<!-- note:").Length - 1);
        Assert.Empty(pipeline.Journal.RecordPaths());
        Assert.Empty(pipeline.Service.ReservedNoteUrls);
    }

    [Fact]
    public async Task FailedSubheadingSaveClearsTheCommitTail()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        File.WriteAllText(pipeline.Journal.DirectoryPath, "block journal creation");
        await Assert.ThrowsAnyAsync<IOException>(() => coordinator.AddSubheadingAsync("Tradeoffs"));
        Assert.Null(coordinator.CommitTail);
        File.Delete(pipeline.Journal.DirectoryPath);

        Assert.NotNull(await coordinator.AddSubheadingAsync("Tradeoffs"));
        Assert.Null(coordinator.CommitTail);
    }

    [Fact]
    public async Task RetypedFailedSubheadingIsWrittenOnceAcrossQuit()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        File.WriteAllText(pipeline.Journal.DirectoryPath, "block journal creation");
        await Assert.ThrowsAnyAsync<IOException>(() => coordinator.AddSubheadingAsync("Tradeoffs"));
        File.Delete(pipeline.Journal.DirectoryPath);

        // The retyped heading retries the failed capture and id, so the quit drain has nothing left to write.
        Assert.NotNull(await coordinator.AddSubheadingAsync("## Tradeoffs "));
        Assert.True(await coordinator.BeginTermination());
        Assert.Equal(1, File.ReadAllText(pipeline.Vault.InboxUrl).Split("## Tradeoffs").Length - 1);
    }

    [Fact]
    public async Task DifferentRetypedSubheadingKeepsTheFailedOneForTheQuitDrain()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        File.WriteAllText(pipeline.Journal.DirectoryPath, "block journal creation");
        await Assert.ThrowsAnyAsync<IOException>(() => coordinator.AddSubheadingAsync("Alpha"));
        File.Delete(pipeline.Journal.DirectoryPath);

        Assert.NotNull(await coordinator.AddSubheadingAsync("Beta"));
        Assert.True(await coordinator.BeginTermination());
        var inbox = File.ReadAllText(pipeline.Vault.InboxUrl);
        Assert.Equal(1, inbox.Split("## Alpha").Length - 1);
        Assert.Equal(1, inbox.Split("## Beta").Length - 1);
    }

    [Fact]
    public async Task FailedJournalRemovalKeepsTheAppendRetryable()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Requires Windows file-sharing semantics.");
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        const string draft = "# Locked\n\nkeptneedle";
        var blocked = Path.Combine(pipeline.Vault.Root, "Locked.md");
        Directory.CreateDirectory(blocked);
        await Assert.ThrowsAnyAsync<IOException>(() => coordinator.AddNoteAsync(draft));
        var record = Assert.Single(pipeline.Journal.RecordPaths());
        var old = pipeline.Journal.Load(record);
        using (var journalLock = new FileStream(record, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            await Assert.ThrowsAnyAsync<IOException>(() => coordinator.AddNoteAsync(draft, newNote: true));
            Assert.True(File.Exists(record));
            Assert.Equal(draft, pipeline.Drafts.Load());
            Assert.False(File.Exists(Path.Combine(pipeline.Vault.Root, "Locked 2.md")));
        }

        Directory.Delete(blocked);
        File.WriteAllText(blocked, "# Locked\n");
        var saved = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync(draft));
        Assert.Equal(old.Prepared.Capture.Id, saved.CaptureId);
        Assert.Equal(blocked, saved.Destination.Url);
        Assert.Empty(pipeline.Journal.RecordPaths());
        Assert.Single(pipeline.Index.Search("keptneedle"));
    }

    private static CapturePipeline Open(TempDirectory temp) => CapturePipeline.Open(
        Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
}
