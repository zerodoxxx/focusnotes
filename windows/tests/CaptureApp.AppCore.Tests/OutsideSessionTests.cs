using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class OutsideSessionTests
{
    [Theory]
    [InlineData("Biology", "Biology.md")]
    [InlineData("science/Biology", "science/Biology.md")]
    [InlineData("/Desktop/Biology", "Desktop/Biology.md")]
    public async Task DetachedNotesCreateAndAppendWithoutChangingTheSession(string title, string relativePath)
    {
        using var temp = new TempDirectory();
        var home = Path.Combine(temp.Path, "home");
        Directory.CreateDirectory(home);
        using var pipeline = CapturePipeline.Open(Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"),
            TimeZoneInfo.Utc, homeDirectory: home);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        var session = await coordinator.StartSessionAsync("Thermo");
        var sessionUrl = pipeline.Vault.ManagedUrl(session.NotePath);
        var before = File.ReadAllText(sessionUrl);
        var draft = title + "\n\ndetachedneedle";
        var saved = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync(draft, pinOnSave: true, outsideSession: true));
        var expected = Path.Combine(title.StartsWith('/') ? home : pipeline.Vault.Root, relativePath);
        Assert.Equal(Path.GetFullPath(expected), saved.Destination.Url);
        Assert.True(pipeline.Pins.IsPinned(pipeline.Vault.NoteId(saved.Destination.Url)));
        Assert.Equal(before, File.ReadAllText(sessionUrl));
        Assert.Equal(session, pipeline.Sessions.Current());
        Assert.Contains(host.Toasts, toast => toast.Title == "Saved to Biology · Thermo still active");

        var appended = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync(title + "\n\nsecondneedle", outsideSession: true));
        Assert.Equal(saved.Destination.Url, appended.Destination.Url);
        var numbered = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync(draft, newNote: true, outsideSession: true));
        Assert.EndsWith("Biology 2.md", numbered.Destination.Url, StringComparison.Ordinal);
        var normal = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync("next normal quick note"));
        Assert.Equal(sessionUrl, normal.Destination.Url);
        await coordinator.StageAsync(PendingCaptures.Selection("normal capture", new()));
        Assert.Equal(sessionUrl, (await coordinator.CommitPending()!).Destination.Url);
        Assert.Equal(session, pipeline.Sessions.Current());
    }

    [Fact]
    public async Task DetachedBrowseAndInboxNamesRespectExplicitDestinations()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var session = await coordinator.StartSessionAsync("Thermo");
        var destination = new Destination(Path.Combine(pipeline.Vault.Root, "Picked.md"), "Picked", NoteKind.Note);
        var browsed = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync("typed title\nbody", destination, outsideSession: true));
        Assert.Equal(destination, browsed.Destination);
        var inbox = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync("Inbox\n\nInbox body", outsideSession: true));
        Assert.Equal(pipeline.Vault.InboxUrl, inbox.Destination.Url);
        Assert.Equal(session, pipeline.Sessions.Current());
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public async Task OutsideCapturePromptsImmediatelyAndDefaultCommitUsesJournaledInbox(bool image, bool nestedInbox)
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        var session = await coordinator.StartSessionAsync("Inbox");
        var sessionUrl = pipeline.Vault.ManagedUrl(session.NotePath);
        var before = File.ReadAllText(sessionUrl);
        var nestedUrl = Path.Combine(pipeline.Vault.Root, "science", "Inbox.md");
        const string nestedBefore = "# Inbox\n\nKeep this note unchanged.\n";
        if (nestedInbox)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(nestedUrl)!);
            File.WriteAllText(nestedUrl, nestedBefore);
        }
        Guid? requested = null;
        coordinator.ChooseNoteRequested = id => requested = id;
        var capture = (image ? PendingCaptures.Image([137, 80, 78, 71], "OCR text", new())
            : PendingCaptures.Selection("outside capture", new())) with { OutsideSession = true };
        await coordinator.StageAsync(capture);
        Assert.Equal(capture.Id, requested);
        Assert.False(coordinator.HasPendingToast);
        var journaled = pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths())).Prepared.Destination;
        Assert.Equal(new Destination(pipeline.Vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox), journaled);
        Assert.Equal(session, pipeline.Sessions.Current());
        // A default commit keeps the staged destination even if session state changes.
        pipeline.Sessions.End();
        var saved = await coordinator.CommitPending(announce: true)!;
        Assert.Equal(journaled, saved.Destination);
        Assert.Equal(before, File.ReadAllText(sessionUrl));
        Assert.Null(pipeline.Sessions.Current());
        if (nestedInbox) Assert.Equal(nestedBefore, File.ReadAllText(nestedUrl));
        if (image)
        {
            var asset = Assert.Single(Directory.GetFiles(pipeline.Vault.AssetsUrl));
            Assert.Equal(capture.Png, File.ReadAllBytes(asset));
            Assert.Contains("assets/", File.ReadAllText(pipeline.Vault.InboxUrl), StringComparison.Ordinal);
        }
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public async Task OutsideCaptureShutdownAndReplayKeepActualInbox(bool image, bool replay)
    {
        using var temp = new TempDirectory();
        Guid id;
        string sessionUrl;
        string sessionBefore;
        string nestedUrl;
        const string nestedBefore = "# Inbox\n\nPreserve nested Inbox.\n";
        using (var pipeline = Open(temp))
        {
            var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
            var session = await coordinator.StartSessionAsync("Inbox");
            sessionUrl = pipeline.Vault.ManagedUrl(session.NotePath);
            sessionBefore = File.ReadAllText(sessionUrl);
            nestedUrl = Path.Combine(pipeline.Vault.Root, "science", "Inbox.md");
            Directory.CreateDirectory(Path.GetDirectoryName(nestedUrl)!);
            File.WriteAllText(nestedUrl, nestedBefore);
            var capture = (image ? PendingCaptures.Image([137, 80, 78, 71], "recovery OCR", new())
                : PendingCaptures.Selection("outside recovery capture", new())) with { OutsideSession = true };
            id = capture.Id;
            await coordinator.StageAsync(capture);
            var destination = pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths())).Prepared.Destination;
            Assert.Equal(new Destination(pipeline.Vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox), destination);
            if (!replay)
            {
                Assert.True(await coordinator.BeginTermination());
                Assert.Empty(pipeline.Journal.RecordPaths());
                Assert.Equal("Inbox.md", pipeline.Index.Capture(id)?.NotePath);
            }
        }
        using var reopened = Open(temp);
        Assert.Equal(replay ? 1 : 0, await reopened.ReplayUnsavedAsync(TestContext.Current.CancellationToken));
        Assert.Equal("Inbox.md", reopened.Index.Capture(id)?.NotePath);
        Assert.Equal(sessionBefore, File.ReadAllText(sessionUrl));
        Assert.Equal(nestedBefore, File.ReadAllText(nestedUrl));
        Assert.Equal("Inbox", reopened.Sessions.Current()?.Name);
        if (image)
        {
            var asset = Assert.Single(Directory.GetFiles(reopened.Vault.AssetsUrl));
            Assert.Equal(new byte[] { 137, 80, 78, 71 }, File.ReadAllBytes(asset));
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FixedDestinationsBypassRoutingBeforePreparation(bool image)
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var destination = new Destination(pipeline.Vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox);
        var registry = Path.Combine(pipeline.StateDirectory, "external-notes.json");
        const string invalidRegistry = "{invalid JSON";
        var inboxBefore = File.ReadAllText(pipeline.Vault.InboxUrl);
        File.WriteAllText(registry, invalidRegistry);
        var capture = new Capture(Guid.NewGuid(), DateTimeOffset.UtcNow, CaptureContent.Text("routing probe"), new());
        Assert.Throws<ExternalNoteRegistryException>(() => pipeline.Service.Prepare(capture));
        var prepared = image
            ? pipeline.PrepareImage([137, 80, 78, 71], new(), destination: destination)
            : pipeline.PrepareText("fixed capture", new(), destination: destination);
        Assert.Equal(destination, prepared.Prepared.Destination);
        Assert.Equal(invalidRegistry, File.ReadAllText(registry));
        Assert.Equal(inboxBefore, File.ReadAllText(pipeline.Vault.InboxUrl));
        Assert.Empty(Directory.GetFiles(pipeline.Vault.AssetsUrl));
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var outside = (image ? PendingCaptures.Image([137, 80, 78, 71], null, new())
            : PendingCaptures.Selection("outside routing probe", new())) with { OutsideSession = true };
        await coordinator.StageAsync(outside);
        Assert.Equal(destination, pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths())).Prepared.Destination);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task OutsideCaptureChosenTitleWorksWithOrWithoutSession(bool hasSession)
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var session = hasSession ? await coordinator.StartSessionAsync("Thermo") : null;
        await coordinator.StageAsync(PendingCaptures.Selection("chosen title capture", new()) with { OutsideSession = true });
        var saved = await coordinator.CommitPending("science/Biology", true)!;
        Assert.Equal(Path.Combine(pipeline.Vault.Root, "science", "Biology.md"), saved.Destination.Url);
        Assert.Equal(session, pipeline.Sessions.Current());
    }

    [Fact]
    public void EditorDestinationToggleAndBlankNewRestoreTheSession()
    {
        var session = new Destination("session.md", "Thermo", NoteKind.Session);
        var state = new QuickNoteState(session);
        state.ToggleOutsideSession(session);
        Assert.True(state.OutsideSession);
        Assert.Null(state.Destination);
        state.ToggleOutsideSession(session);
        Assert.False(state.OutsideSession);
        Assert.Equal(session, state.Destination);
        state.ToggleOutsideSession(session);
        state.Destination = new("browsed.md", "Browsed", NoteKind.Note);
        state.ReturnToSession(session);
        Assert.False(state.OutsideSession);
        Assert.Equal(session, state.Destination);
        var reopened = new QuickNoteState(session);
        Assert.False(reopened.OutsideSession);
        reopened.ToggleOutsideSession(null);
        Assert.Equal(session, reopened.Destination);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task ChangingDestinationIntentSupersedesADurablyJournaledFailedSave(bool firstOutside, bool browseRetry)
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Requires Windows destination-sharing semantics.");
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var session = await coordinator.StartSessionAsync("Thermo");
        const string draft = "Biology\n\nretryroutingneedle";
        var biologyUrl = Path.Combine(pipeline.Vault.Root, "Biology.md");
        File.WriteAllText(biologyUrl, "# Biology\n\nExisting Biology content.\n");
        var failedUrl = firstOutside ? biologyUrl : pipeline.Vault.ManagedUrl(session.NotePath);
        var failedBefore = File.ReadAllBytes(failedUrl);
        // Permit preparation reads but deny the append, after Journal.Store succeeds.
        using (var destinationLock = new FileStream(failedUrl, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var failure = await Assert.ThrowsAnyAsync<IOException>(() => coordinator.AddNoteAsync(draft, outsideSession: firstOutside));
            Assert.Equal(unchecked((int)0x80070020), failure.HResult); // ERROR_SHARING_VIOLATION at the destination.
        }
        var failed = pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths()));
        Assert.Equal(failedUrl, failed.Prepared.Destination.Url);
        Assert.Equal(firstOutside, failed.NoteOutsideSession);
        Assert.Equal(draft, failed.NoteDraft);
        Assert.Equal(failedBefore, File.ReadAllBytes(failedUrl));

        var picked = browseRetry ? new Destination(Path.Combine(pipeline.Vault.Root, "Picked.md"), "Picked", NoteKind.Note) : null;
        var saved = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync(draft, picked, outsideSession: browseRetry || !firstOutside));
        Assert.Equal(picked?.Url ?? (firstOutside ? pipeline.Vault.ManagedUrl(session.NotePath) : biologyUrl), saved.Destination.Url);
        Assert.NotEqual(failed.Prepared.Capture.Id, saved.CaptureId);
        // Shutdown must not retain and later commit the superseded prepared job.
        Assert.True(await coordinator.BeginTermination());
        Assert.Equal(failedBefore, File.ReadAllBytes(failedUrl));
        Assert.Empty(pipeline.Journal.RecordPaths());
        using var reopened = Open(temp);
        Assert.Equal(0, await reopened.ReplayUnsavedAsync(TestContext.Current.CancellationToken));
        Assert.Null(reopened.Index.Capture(failed.Prepared.Capture.Id));
        Assert.Equal(failedBefore, File.ReadAllBytes(failedUrl));
        Assert.Contains("retryroutingneedle", File.ReadAllText(saved.Destination.Url), StringComparison.Ordinal);
        Assert.DoesNotContain(failed.Prepared.Capture.Id.ToString("D"), File.ReadAllText(saved.Destination.Url), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(session, pipeline.Sessions.Current());
    }

    [Fact]
    public void OutsideIntentRoundTripsInTheJournal()
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        pipeline.Sessions.Start("Thermo");
        var job = pipeline.PrepareNote("Biology\n\nbody", new(), outsideSession: true);
        pipeline.Journal.Store(job);
        var restored = pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths()));
        Assert.True(restored.NoteOutsideSession);
        Assert.Equal(job.Prepared.Destination, restored.Prepared.Destination);
    }

    private static CapturePipeline Open(TempDirectory temp) => CapturePipeline.Open(
        Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
}
