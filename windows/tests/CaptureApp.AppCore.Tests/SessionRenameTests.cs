using System.Text;
using System.Text.Json;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class SessionRenameTests
{
    private static CapturePipeline Open(TempDirectory temp) => CapturePipeline.Open(
        Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);

    private static SessionCandidate Candidate(Session session) => new(session.Name, session.NotePath, DateTimeOffset.UtcNow);

    [Fact]
    public async Task RenameMigratesPinsJournalPreparedCapturesAndIndexWithoutMovingImages()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var original = pipeline.Sessions.Start("archive/Standup");
        var oldUrl = pipeline.Vault.ManagedUrl(original.NotePath);
        File.AppendAllText(oldUrl, "![screen](../../assets/screen.png)\n\nrenamebodyneedle\n", new UTF8Encoding(false));
        var image = Path.Combine(pipeline.Vault.Root, "assets", "screen.png");
        Directory.CreateDirectory(Path.GetDirectoryName(image)!);
        File.WriteAllBytes(image, [1, 2, 3]);
        var durable = pipeline.PrepareText("durable capture", new CaptureSource());
        pipeline.Stage(durable);
        var prepared = pipeline.PrepareText("in-memory capture", new CaptureSource());
        pipeline.Pins.Set(original.NotePath, true);
        pipeline.Index.Sync();
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());

        var renamed = await coordinator.RenameSessionAsync(Candidate(original), "Daily sync");

        Assert.Equal("Sessions/archive/Daily sync.md", renamed.NotePath);
        Assert.Equal(renamed, coordinator.ActiveSession);
        Assert.Equal(renamed.NotePath, pipeline.Sessions.Current()?.NotePath);
        Assert.False(File.Exists(oldUrl));
        Assert.False(pipeline.Pins.IsPinned(original.NotePath));
        Assert.True(pipeline.Pins.IsPinned(renamed.NotePath));
        var newUrl = pipeline.Vault.ManagedUrl(renamed.NotePath);
        var record = pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths()));
        Assert.Equal(newUrl, record.Prepared.Destination.Url);
        Assert.Equal("Daily sync", record.Prepared.Destination.Title);
        Assert.Equal(newUrl, pipeline.Commit(prepared).Destination.Url);
        Assert.Equal(newUrl, pipeline.Commit(durable).Destination.Url);
        var contents = File.ReadAllText(newUrl);
        Assert.StartsWith("# Daily sync\n", contents, StringComparison.Ordinal);
        Assert.Contains("![screen](../../assets/screen.png)", contents, StringComparison.Ordinal);
        Assert.Equal(image, Path.GetFullPath(Path.Combine(Path.GetDirectoryName(newUrl)!, "../../assets/screen.png")));
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(image));
        Assert.DoesNotContain(pipeline.Index.TitleSuggestions("", 100), s => s.Path == original.NotePath);
        Assert.Contains(pipeline.Index.Search("renamebodyneedle"), hit => hit.NotePath == renamed.NotePath);

        // Capture-ID redirects apply only to work prepared before rename. A new independent note
        // can reuse the vacated name without being routed into the renamed session.
        pipeline.Sessions.End();
        var reused = pipeline.Sessions.Start("archive/Standup");
        var independent = pipeline.PrepareText("independent capture", new CaptureSource());
        Assert.Equal(pipeline.Vault.ManagedUrl(reused.NotePath), pipeline.Commit(independent).Destination.Url);
        Assert.DoesNotContain("independent capture", File.ReadAllText(newUrl), StringComparison.Ordinal);
    }

    [Fact]
    public void CollisionPreservesOriginalSessionPinsAndJournal()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var original = pipeline.Sessions.Start("archive/Standup");
        var existing = pipeline.Sessions.Start("archive/Daily sync");
        pipeline.Sessions.Resume(Candidate(original));
        var job = pipeline.PrepareText("keep this capture", new CaptureSource());
        pipeline.Stage(job);
        pipeline.Pins.Set(original.NotePath, true);
        var before = File.ReadAllBytes(pipeline.Vault.ManagedUrl(original.NotePath));

        Assert.ThrowsAny<IOException>(() => pipeline.RenameSession(Candidate(original), "daily SYNC"));

        Assert.Equal(before, File.ReadAllBytes(pipeline.Vault.ManagedUrl(original.NotePath)));
        Assert.True(File.Exists(pipeline.Vault.ManagedUrl(existing.NotePath)));
        Assert.Equal(original.NotePath, pipeline.Sessions.Current()?.NotePath);
        Assert.True(pipeline.Pins.IsPinned(original.NotePath));
        Assert.Equal(job.Prepared.Destination, pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths())).Prepared.Destination);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task StartupFinishesInterruptedRenameAndReplaysCaptureExactlyOnce(bool rewriteAlreadyCompleted)
    {
        using var temp = new TempDirectory();
        string oldPath, newPath;
        using (var pipeline = Open(temp))
        {
            var original = pipeline.Sessions.Start("archive/Standup");
            oldPath = original.NotePath;
            var job = pipeline.PrepareText("recoveredrenameneedle", new CaptureSource());
            pipeline.Stage(job);
            pipeline.Pins.Set(oldPath, true);
            SessionRenamePlan? plan = null;
            void BeforeRename(SessionRenamePlan value)
            {
                plan = value;
                File.WriteAllBytes(Path.Combine(pipeline.StateDirectory, "session-rename.json"),
                    JsonSerializer.SerializeToUtf8Bytes(new { Plan = value, CaptureIds = new[] { job.Prepared.Capture.Id } }));
                if (!rewriteAlreadyCompleted) throw new InvalidOperationException("simulated interruption");
            }
            if (rewriteAlreadyCompleted) pipeline.Service.RenameSession(Candidate(original), "Daily sync", BeforeRename);
            else Assert.Throws<InvalidOperationException>(() => pipeline.Service.RenameSession(Candidate(original), "Daily sync", BeforeRename));
            Assert.NotNull(plan);
            newPath = plan.Target.NotePath;
            if (!rewriteAlreadyCompleted)
                File.Move(pipeline.Vault.ManagedUrl(oldPath), pipeline.Vault.ManagedUrl(newPath));
        }

        using var reopened = Open(temp);
        Assert.Equal(newPath, reopened.Sessions.Current()?.NotePath);
        Assert.False(reopened.Pins.IsPinned(oldPath));
        Assert.True(reopened.Pins.IsPinned(newPath));
        Assert.StartsWith("# Daily sync\n", File.ReadAllText(reopened.Vault.ManagedUrl(newPath)), StringComparison.Ordinal);
        Assert.Equal(reopened.Vault.ManagedUrl(newPath), reopened.Journal.Load(Assert.Single(reopened.Journal.RecordPaths())).Prepared.Destination.Url);
        Assert.Equal(1, await reopened.ReplayUnsavedAsync(TestContext.Current.CancellationToken));
        Assert.Equal(0, await reopened.ReplayUnsavedAsync(TestContext.Current.CancellationToken));
        Assert.False(File.Exists(reopened.Vault.ManagedUrl(oldPath)));
        Assert.Contains(reopened.Index.Search("recoveredrenameneedle"), hit => hit.NotePath == newPath);
        Assert.False(File.Exists(Path.Combine(reopened.StateDirectory, "session-rename.json")));
    }

    [Fact]
    public void FailedSessionPersistenceBlocksStaleWritesUntilDurableRenameRecoverySucceeds()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var original = pipeline.Sessions.Start("Standup");
        var job = pipeline.PrepareText("retainthroughfailure", new CaptureSource());
        pipeline.Stage(job);
        pipeline.Pins.Set(original.NotePath, true);
        File.Delete(pipeline.Sessions.StateFileUrl);
        Directory.CreateDirectory(pipeline.Sessions.StateFileUrl);

        Assert.NotNull(Record.Exception(() => pipeline.RenameSession(Candidate(original), "Daily sync")));
        var newPath = "Sessions/Daily sync.md";
        Assert.False(File.Exists(pipeline.Vault.ManagedUrl(original.NotePath)));
        Assert.True(File.Exists(pipeline.Vault.ManagedUrl(newPath)));
        Assert.Equal(newPath, pipeline.Sessions.Current()?.NotePath);
        Assert.NotNull(Record.Exception(() => pipeline.Commit(job)));
        Assert.False(File.Exists(pipeline.Vault.ManagedUrl(original.NotePath)));
        Assert.Single(pipeline.Journal.RecordPaths());

        Directory.Delete(pipeline.Sessions.StateFileUrl);
        var saved = pipeline.Commit(job);
        Assert.Equal(pipeline.Vault.ManagedUrl(newPath), saved.Destination.Url);
        Assert.False(File.Exists(pipeline.Vault.ManagedUrl(original.NotePath)));
        Assert.False(pipeline.Pins.IsPinned(original.NotePath));
        Assert.True(pipeline.Pins.IsPinned(newPath));
        Assert.Empty(pipeline.Journal.RecordPaths());
        Assert.Single(pipeline.Index.Search("retainthroughfailure"));
    }

    [Fact]
    public void UnreadablePinsRetainRenameIntentAndMigrateAfterRepair()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var original = pipeline.Sessions.Start("Standup");
        var job = pipeline.PrepareText("retainpinthroughfailure", new CaptureSource());
        pipeline.Stage(job);
        pipeline.Pins.Set(original.NotePath, true);
        var pinBackup = Path.Combine(pipeline.StateDirectory, "pinned-backup.json");
        File.Move(pipeline.Pins.Url, pinBackup);
        Directory.CreateDirectory(pipeline.Pins.Url);

        Assert.NotNull(Record.Exception(() => pipeline.RenameSession(Candidate(original), "Daily sync")));
        Assert.True(File.Exists(Path.Combine(pipeline.StateDirectory, "session-rename.json")));
        Assert.False(File.Exists(pipeline.Vault.ManagedUrl(original.NotePath)));
        Assert.NotNull(Record.Exception(() => pipeline.Commit(job)));
        Assert.Single(pipeline.Journal.RecordPaths());

        Directory.Delete(pipeline.Pins.Url);
        File.Move(pinBackup, pipeline.Pins.Url);
        var saved = pipeline.Commit(job);
        Assert.Equal(pipeline.Vault.ManagedUrl("Sessions/Daily sync.md"), saved.Destination.Url);
        Assert.False(pipeline.Pins.IsPinned(original.NotePath));
        Assert.True(pipeline.Pins.IsPinned("Sessions/Daily sync.md"));
        Assert.False(File.Exists(Path.Combine(pipeline.StateDirectory, "session-rename.json")));
        Assert.Empty(pipeline.Journal.RecordPaths());
    }

    [Fact]
    public void UnrelatedCorruptJournalDoesNotBlockRenameAndCompletedRedirectsArePrunedOnStartup()
    {
        using var temp = new TempDirectory();
        using (var pipeline = Open(temp))
        {
            var original = pipeline.Sessions.Start("Standup");
            var job = pipeline.PrepareText("capture", new CaptureSource());
            pipeline.Stage(job);
            File.WriteAllText(Path.Combine(pipeline.Journal.DirectoryPath, Guid.NewGuid().ToString("D") + ".json"), "invalid json");
            pipeline.RenameSession(Candidate(original), "Daily sync");
            pipeline.Commit(job);
            Assert.NotEmpty(JsonSerializer.Deserialize<Dictionary<Guid, Destination>>(
                File.ReadAllBytes(Path.Combine(pipeline.StateDirectory, "capture-destinations.json")),
                new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase })!);
        }
        using var reopened = Open(temp);
        Assert.Empty(JsonSerializer.Deserialize<Dictionary<Guid, Destination>>(
            File.ReadAllBytes(Path.Combine(reopened.StateDirectory, "capture-destinations.json")),
            new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase })!);
    }
}
