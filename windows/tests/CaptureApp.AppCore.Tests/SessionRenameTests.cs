using System.Text;
using System.Text.Json;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class SessionRenameTests
{
    [Fact]
    public async Task SuccessfulRenameFeedbackDoesNotRepeatAFailedIndexCacheUpdate()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var session = pipeline.Sessions.Start("Standup");
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        pipeline.Index.Dispose(); // The pipeline treats search-cache failure as repairable.

        var outcome = await coordinator.RenameSessionAsync(Candidate(session), "Daily sync");

        Assert.False(outcome.IdentityUpdatePending);
        Assert.Equal(outcome.Session, coordinator.ActiveSession);
        Assert.True(File.Exists(pipeline.Vault.ManagedUrl(outcome.Session.NotePath)));
        Assert.False(File.Exists(Path.Combine(pipeline.StateDirectory, "session-rename.json")));
    }

    [Fact]
    public void FailedMoveImmediatelyClearsIntentBeforeLaterSourceEdits()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var session = pipeline.Sessions.Start("Standup");
        var oldUrl = pipeline.Vault.ManagedUrl(session.NotePath);
        Assert.Throws<SessionStoreException>(() => pipeline.RenameSession(Candidate(session), "Daily sync", afterIntent: plan =>
        {
            File.WriteAllText(pipeline.Vault.ManagedUrl(plan.Target.NotePath), "# Occupied\nkeep\n");
        }));
        Assert.False(File.Exists(Path.Combine(pipeline.StateDirectory, "session-rename.json")));
        File.AppendAllText(oldUrl, "user edit\n");
        Assert.Contains("user edit", File.ReadAllText(oldUrl), StringComparison.Ordinal);
        pipeline.Commit(pipeline.PrepareText("next capture", new CaptureSource()));
        Assert.Contains("next capture", File.ReadAllText(oldUrl), StringComparison.Ordinal);
    }

    [Fact]
    public void StartupRemovesOnlyTheRecordedStagingOrphan()
    {
        using var temp = new TempDirectory();
        string stagedPath;
        using (var pipeline = Open(temp))
        {
            var session = pipeline.Sessions.Start("Standup");
            SessionRenamePlan? recorded = null;
            var heldPath = Path.Combine(pipeline.StateDirectory, "held-staging.md");
            Assert.Throws<InvalidOperationException>(() => pipeline.Service.RenameSession(Candidate(session), "Daily sync", plan =>
            {
                recorded = plan;
                File.WriteAllBytes(Path.Combine(pipeline.StateDirectory, "session-rename.json"),
                    JsonSerializer.SerializeToUtf8Bytes(new { Plan = plan, CaptureIds = Array.Empty<Guid>() }));
                File.Move(pipeline.Vault.ManagedUrl(plan.Installation!.TemporaryPath), heldPath);
                throw new InvalidOperationException("simulated crash with a retained staging inode");
            }));
            Assert.NotNull(recorded);
            stagedPath = pipeline.Vault.ManagedUrl(recorded.Installation!.TemporaryPath);
            File.Move(heldPath, stagedPath); // Same inode, restored to the exact crash checkpoint name.
        }
        using var reopened = Open(temp);
        Assert.False(File.Exists(stagedPath));
        Assert.False(File.Exists(Path.Combine(reopened.StateDirectory, "session-rename.json")));
        Assert.True(File.Exists(reopened.Vault.ManagedUrl("Sessions/Standup.md")));
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void StartupRecoversContentDriftOrAbandonsAnUncommittedRename(bool replacementFinished, bool sourceUnmoved)
    {
        using var temp = new TempDirectory();
        string path;
        using (var pipeline = Open(temp))
        {
            var session = pipeline.Sessions.Start("Standup");
            SessionRenamePlan? plan = null;
            void SaveIntent(SessionRenamePlan value)
            {
                plan = value;
                File.WriteAllBytes(Path.Combine(pipeline.StateDirectory, "session-rename.json"),
                    JsonSerializer.SerializeToUtf8Bytes(new { Plan = value, CaptureIds = Array.Empty<Guid>() }));
                if (!replacementFinished) throw new InvalidOperationException("interrupted before move");
            }
            if (replacementFinished) pipeline.Service.RenameSession(Candidate(session), "Daily sync", SaveIntent);
            else Assert.Throws<InvalidOperationException>(() => pipeline.Service.RenameSession(Candidate(session), "Daily sync", SaveIntent));
            Assert.NotNull(plan);
            path = sourceUnmoved ? session.NotePath : plan.Target.NotePath;
            if (!sourceUnmoved && !replacementFinished)
                File.Move(pipeline.Vault.ManagedUrl(session.NotePath), pipeline.Vault.ManagedUrl(path));
            File.AppendAllText(pipeline.Vault.ManagedUrl(path), "external edit after interruption\n");
        }
        using var reopened = Open(temp);
        Assert.False(File.Exists(Path.Combine(reopened.StateDirectory, "session-rename.json")));
        Assert.Contains("external edit after interruption", File.ReadAllText(reopened.Vault.ManagedUrl(path)), StringComparison.Ordinal);
        Assert.Equal(path, reopened.Sessions.Current()?.NotePath);
        reopened.Commit(reopened.PrepareText("works after recovery", new CaptureSource()));
        Assert.Contains("works after recovery", File.ReadAllText(reopened.Vault.ManagedUrl(path)), StringComparison.Ordinal);
    }

    [Fact]
    public void UnrelatedTargetDoesNotBlockStartupOrChangeItsBytes()
    {
        using var temp = new TempDirectory();
        using (var pipeline = Open(temp))
        {
            var session = pipeline.Sessions.Start("Standup");
            pipeline.Service.RenameSession(Candidate(session), "Daily sync", plan =>
                File.WriteAllBytes(Path.Combine(pipeline.StateDirectory, "session-rename.json"),
                    JsonSerializer.SerializeToUtf8Bytes(new { Plan = plan, CaptureIds = Array.Empty<Guid>() })));
            var target = pipeline.Vault.ManagedUrl("Sessions/Daily sync.md");
            File.Move(target, target + ".backup");
            File.WriteAllText(target, "# Unrelated\nkeep these bytes\n");
        }
        using var reopened = Open(temp);
        Assert.Equal("# Unrelated\nkeep these bytes\n", File.ReadAllText(reopened.Vault.ManagedUrl("Sessions/Daily sync.md")));
        Assert.False(File.Exists(Path.Combine(reopened.StateDirectory, "session-rename.json")));
    }

    [Fact]
    public void FailedRollbackReturnsPendingOutcomeAndRecoveryKeepsTheOccupiedOldName()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var session = pipeline.Sessions.Start("Standup");
        var oldUrl = pipeline.Vault.ManagedUrl(session.NotePath);
        var job = pipeline.PrepareText("pending capture", new CaptureSource());
        pipeline.Stage(job);
        var outcome = pipeline.RenameSession(Candidate(session), "Daily sync", beforeReplace: () =>
        {
            File.WriteAllText(oldUrl, "# Other\noccupied old name\n");
            throw new IOException("injected replacement failure");
        });
        Assert.True(outcome.IdentityUpdatePending);
        var saved = pipeline.Commit(job);
        Assert.Equal(pipeline.Vault.ManagedUrl(outcome.Session.NotePath), saved.Destination.Url);
        Assert.Equal("# Other\noccupied old name\n", File.ReadAllText(oldUrl));
        Assert.StartsWith("# Daily sync\n", File.ReadAllText(saved.Destination.Url), StringComparison.Ordinal);
        Assert.Contains("rollback failed", string.Join('\n', Directory.EnumerateFiles(Path.Combine(pipeline.StateDirectory, "logs"))
            .Select(File.ReadAllText)), StringComparison.OrdinalIgnoreCase);
    }
    [Theory]
    [InlineData("{\"Plan\":{\"OldP")]
    [InlineData("{\"Plan\":null,\"CaptureIds\":[]}")]
    [InlineData("{\"Unknown\":true}")]
    public void CorruptRenameIntentIsQuarantinedAndDoesNotBlockStartupOrCaptures(string content)
    {
        using var temp = new TempDirectory();
        var state = Path.Combine(temp.Path, "state");
        Directory.CreateDirectory(state);
        File.WriteAllText(Path.Combine(state, "session-rename.json"), content);

        using var pipeline = Open(temp);
        Assert.False(File.Exists(Path.Combine(state, "session-rename.json")));
        Assert.Equal(content, File.ReadAllText(Path.Combine(pipeline.Journal.DirectoryPath, "corrupt", "session-rename.json")));

        File.WriteAllText(Path.Combine(state, "session-rename.json"), content);
        var saved = pipeline.Commit(pipeline.PrepareText("after corruption", new CaptureSource()));
        Assert.Contains("after corruption", File.ReadAllText(saved.Destination.Url), StringComparison.Ordinal);
        Assert.Equal(2, Directory.GetFiles(Path.Combine(pipeline.Journal.DirectoryPath, "corrupt"), "session-rename*.json").Length);
    }

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

        var outcome = await coordinator.RenameSessionAsync(Candidate(original), "Daily sync");
        Assert.False(outcome.IdentityUpdatePending);
        var renamed = outcome.Session;

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

        Assert.True(pipeline.RenameSession(Candidate(original), "Daily sync").IdentityUpdatePending);
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

        Assert.True(pipeline.RenameSession(Candidate(original), "Daily sync").IdentityUpdatePending);
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

    [Theory]
    [InlineData("start")]
    [InlineData("folder")]
    [InlineData("resume")]
    [InlineData("end")]
    public async Task SessionTransitionRecoversPendingRenameBeforeChangingCaptureDestination(string transition)
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var other = pipeline.Sessions.Start("Other");
        var original = await coordinator.StartSessionAsync("Standup");
        var preparedBeforeRename = pipeline.PrepareText("prepared before rename", new CaptureSource());
        pipeline.Pins.Set(original.NotePath, true);
        var pinBackup = BlockPins(pipeline);
        Assert.True((await coordinator.RenameSessionAsync(Candidate(original), "Daily sync")).IdentityUpdatePending);
        RepairPins(pipeline, pinBackup);

        var expected = await Transition(coordinator, transition, Candidate(other));

        Assert.False(File.Exists(Path.Combine(pipeline.StateDirectory, "session-rename.json")));
        Assert.False(pipeline.Pins.IsPinned(original.NotePath));
        Assert.True(pipeline.Pins.IsPinned("Sessions/Daily sync.md"));
        Assert.Equal(expected, pipeline.Sessions.Current());
        AssertSessionPath(expected, new SessionStore(pipeline.StateDirectory, pipeline.Vault, TimeZoneInfo.Utc).Current());
        Assert.Equal(expected, coordinator.ActiveSession);
        Assert.Equal(pipeline.Vault.ManagedUrl("Sessions/Daily sync.md"), pipeline.Commit(preparedBeforeRename).Destination.Url);
        var job = pipeline.PrepareText("after transition", new CaptureSource());
        var saved = pipeline.Commit(job);
        Assert.Equal(expected is null ? pipeline.Vault.InboxUrl : pipeline.Vault.ManagedUrl(expected.NotePath), saved.Destination.Url);
        AssertSessionPath(expected, new SessionStore(pipeline.StateDirectory, pipeline.Vault, TimeZoneInfo.Utc).Current());
    }

    [Theory]
    [InlineData("start")]
    [InlineData("folder")]
    [InlineData("resume")]
    [InlineData("end")]
    public async Task SessionTransitionDoesNotApplyWhenPendingRenameRecoveryFails(string transition)
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var other = pipeline.Sessions.Start("Other");
        var original = await coordinator.StartSessionAsync("Standup");
        pipeline.Pins.Set(original.NotePath, true);
        var pinBackup = BlockPins(pipeline);
        Assert.True((await coordinator.RenameSessionAsync(Candidate(original), "Daily sync")).IdentityUpdatePending);
        var before = pipeline.Sessions.Current();

        await Assert.ThrowsAnyAsync<Exception>(() => Transition(coordinator, transition, Candidate(other)));

        Assert.Equal(before, pipeline.Sessions.Current());
        AssertSessionPath(before, new SessionStore(pipeline.StateDirectory, pipeline.Vault, TimeZoneInfo.Utc).Current());
        Assert.Equal(before, coordinator.ActiveSession);
        Assert.True(File.Exists(Path.Combine(pipeline.StateDirectory, "session-rename.json")));
        Assert.False(File.Exists(pipeline.Vault.ManagedUrl("Sessions/Requested.md")));
        Assert.False(File.Exists(pipeline.Vault.ManagedUrl("Sessions/Work/Requested.md")));

        RepairPins(pipeline, pinBackup);
        var expected = await Transition(coordinator, transition, Candidate(other));
        Assert.Equal(expected, pipeline.Sessions.Current());
        AssertSessionPath(expected, new SessionStore(pipeline.StateDirectory, pipeline.Vault, TimeZoneInfo.Utc).Current());
        Assert.Equal(expected, coordinator.ActiveSession);
        Assert.False(File.Exists(Path.Combine(pipeline.StateDirectory, "session-rename.json")));
    }

    private static async Task<Session?> Transition(CaptureCoordinator coordinator, string transition, SessionCandidate other)
    {
        return transition switch
        {
            "start" => await coordinator.StartSessionAsync("Requested"),
            "folder" => await coordinator.StartFolderSessionAsync("Work", "Requested"),
            "resume" => await coordinator.ResumeSessionAsync(other),
            "end" => await EndAndReturnNull(coordinator),
            _ => throw new ArgumentOutOfRangeException(nameof(transition), transition, null)
        };
    }

    private static async Task<Session?> EndAndReturnNull(CaptureCoordinator coordinator)
    {
        var current = coordinator.ActiveSession ?? throw new InvalidOperationException("Expected active session.");
        await coordinator.EndSessionAsync(current);
        return null;
    }

    private static string BlockPins(CapturePipeline pipeline)
    {
        var pinBackup = Path.Combine(pipeline.StateDirectory, "pinned-backup.json");
        File.Move(pipeline.Pins.Url, pinBackup);
        Directory.CreateDirectory(pipeline.Pins.Url);
        return pinBackup;
    }

    private static void AssertSessionPath(Session? expected, Session? actual)
    {
        Assert.Equal(expected?.Name, actual?.Name);
        Assert.Equal(expected?.NotePath, actual?.NotePath);
    }

    private static void RepairPins(CapturePipeline pipeline, string pinBackup)
    {
        Directory.Delete(pipeline.Pins.Url);
        File.Move(pinBackup, pipeline.Pins.Url);
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
