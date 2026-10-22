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
    [InlineData(false)]
    [InlineData(true)]
    public async Task OutsideCapturePromptsImmediatelyAndEscUsesJournaledInbox(bool image)
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        var session = await coordinator.StartSessionAsync("Thermo");
        var sessionUrl = pipeline.Vault.ManagedUrl(session.NotePath);
        var before = File.ReadAllText(sessionUrl);
        Guid? requested = null;
        coordinator.ChooseNoteRequested = id => requested = id;
        var capture = (image ? PendingCaptures.Image([137, 80, 78, 71], "OCR text", new())
            : PendingCaptures.Selection("outside capture", new())) with { OutsideSession = true };
        await coordinator.StageAsync(capture);
        Assert.Equal(capture.Id, requested);
        Assert.False(coordinator.HasPendingToast);
        Assert.Equal(pipeline.Vault.InboxUrl, pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths())).Prepared.Destination.Url);
        var saved = await coordinator.CommitPending(announce: true)!;
        Assert.Equal(pipeline.Vault.InboxUrl, saved.Destination.Url);
        Assert.Equal(before, File.ReadAllText(sessionUrl));
        Assert.Equal(session, pipeline.Sessions.Current());
        if (image)
        {
            var asset = Assert.Single(Directory.GetFiles(pipeline.Vault.AssetsUrl));
            Assert.Equal(capture.Png, File.ReadAllBytes(asset));
            Assert.Contains("assets/", File.ReadAllText(pipeline.Vault.InboxUrl), StringComparison.Ordinal);
        }
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
    [InlineData(false)]
    [InlineData(true)]
    public async Task ChangingOutsideIntentSupersedesAFailedSameTextSave(bool firstOutside)
    {
        using var temp = new TempDirectory();
        using var pipeline = Open(temp);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var session = await coordinator.StartSessionAsync("Thermo");
        const string draft = "Biology\n\nretryroutingneedle";
        File.WriteAllText(pipeline.Journal.DirectoryPath, "block journaling");
        await Assert.ThrowsAnyAsync<IOException>(() => coordinator.AddNoteAsync(draft, outsideSession: firstOutside));
        File.Delete(pipeline.Journal.DirectoryPath);
        Directory.CreateDirectory(pipeline.Journal.DirectoryPath);
        var saved = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync(draft, outsideSession: !firstOutside));
        Assert.Equal(firstOutside ? pipeline.Vault.ManagedUrl(session.NotePath) : Path.Combine(pipeline.Vault.Root, "Biology.md"), saved.Destination.Url);
        Assert.Empty(pipeline.Journal.RecordPaths());
        Assert.Equal(0, await pipeline.ReplayUnsavedAsync(TestContext.Current.CancellationToken));
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
