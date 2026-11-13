using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class ThoughtTests
{
    [Fact]
    public async Task PipelineSavesThoughtWhenSearchIndexUnavailable()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var saved = pipeline.Commit(pipeline.PrepareText("capture", new()));
        pipeline.Index.Dispose();
        await pipeline.SetThoughtAsync("persisted", saved.CaptureId, saved.Destination.Url);
        Assert.Equal("persisted", await pipeline.SavedThoughtAsync(saved.CaptureId, saved.Destination.Url));
    }

    [Fact]
    public async Task ConfirmedDiskAbsenceClearsSavedCacheButPreservesDrafts()
    {
        var composer = new ThoughtComposer((_, _, _) => Task.CompletedTask);
        var id = Guid.NewGuid();
        Func<Task<string>> destination = () => Task.FromResult("a.md");
        composer.Begin(id, "saved", destination);
        Assert.IsType<ThoughtSaveOutcome.Saved>(await composer.SaveAsync(id, "saved"));
        Assert.Equal("saved", composer.Begin(id, null, destination));
        Assert.Equal("", composer.Begin(id, null, destination, savedStateLoaded: true));
        composer.Close(id, "draft");
        Assert.Equal("draft", composer.Begin(id, null, destination, savedStateLoaded: true));
    }

    [Fact]
    public async Task ThoughtSaveRecoversRenameBeforeResolvingDestination()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var session = pipeline.Sessions.Start("Standup");
        var saved = pipeline.Commit(pipeline.PrepareText("capture", new()));
        File.Delete(pipeline.Sessions.StateFileUrl);
        Directory.CreateDirectory(pipeline.Sessions.StateFileUrl);
        var outcome = pipeline.RenameSession(new(session.Name, session.NotePath, DateTimeOffset.UtcNow), "Moved");
        Assert.True(outcome.IdentityUpdatePending);
        var moved = pipeline.Vault.ManagedUrl(outcome.Session.NotePath);
        var before = File.ReadAllBytes(moved);
        await Assert.ThrowsAnyAsync<Exception>(() => pipeline.SetThoughtAsync("blocked", saved.CaptureId, moved));
        Assert.Equal(before, File.ReadAllBytes(moved));
        Directory.Delete(pipeline.Sessions.StateFileUrl);
        await pipeline.SetThoughtAsync("recovered", saved.CaptureId, saved.Destination.Url);
        Assert.Equal("recovered", await pipeline.SavedThoughtAsync(saved.CaptureId, moved));
        Assert.False(pipeline.Pins.IsPinned(session.NotePath));
    }

    [Fact]
    public async Task PipelineRejectsThoughtReadOutsideManagedVault()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var id = Guid.NewGuid();
        var outside = Path.Combine(temp.Path, "outside.md");
        File.WriteAllText(outside, "<!-- capture:" + id.ToString("D") + " at=2026-10-13T14:30:00Z app=\"\" -->\n\nbody\n\n"
            + CaptureFormat.ThoughtBlock(id, "private", DateTimeOffset.Now, TimeZoneInfo.Utc));
        var link = Path.Combine(pipeline.Vault.Root, "Swapped.md");
        File.CreateSymbolicLink(link, outside);
        await Assert.ThrowsAnyAsync<Exception>(() => pipeline.SavedThoughtAsync(id, link));
    }

    [Fact]
    public async Task OnlyStagedSuccessToastsOfferThoughts()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var host = new HeadlessCaptureHost(presentsUi: true);
        var coordinator = new CaptureCoordinator(pipeline, host);
        await coordinator.AddNoteAsync("ordinary note");
        Assert.All(host.Toasts, toast => Assert.Null(toast.Action));
        Assert.NotEmpty(host.Toasts);
        await coordinator.StageAsync(PendingCaptures.Selection("excerpt", new()));
        Assert.Equal("Add a thought", host.Toasts.Last().Action?.Title);
        await coordinator.CommitPending()!;
    }

    [Fact]
    public async Task ThoughtActionCommitsOnceAndCarriesTheOriginalCapture()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var host = new HeadlessCaptureHost(presentsUi: true);
        var coordinator = new CaptureCoordinator(pipeline, host);
        var capture = PendingCaptures.Selection("excerpt", new("Browser", "Page title", "https://example.com/page"));
        ThoughtTarget? target = null;
        coordinator.ThoughtRequested += value => target = value;
        await coordinator.StageAsync(capture);
        var action = Assert.IsType<AppToastAction>(host.Toasts.Last().Action);
        action.Invoke();
        var request = Assert.IsType<ThoughtTarget>(target);
        Assert.Equal(capture.Id, request.CaptureId);
        Assert.Equal("Page title", request.SourceTitle);
        Assert.Equal("Browser · example.com", request.SourceDetail);
        Assert.Equal("excerpt", request.ExcerptText);
        Assert.Null(request.ExcerptImagePng);
        var saved = await Assert.IsAssignableFrom<Task<SavedCapture>>(request.Commit);
        Assert.Null(coordinator.Pending);
        Assert.False(coordinator.HasPendingToast);
        coordinator.ToastExpired();
        action.Invoke();
        Assert.Null(target!.Commit);
        Assert.Null(coordinator.CommitPending());
        Assert.Equal(1, File.ReadAllText(saved.Destination.Url).Split(capture.Id.ToString("D")).Length - 1);
    }

    [Fact]
    public async Task StaleActionLeavesNewerPendingCaptureAlone()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var host = new HeadlessCaptureHost(presentsUi: true);
        var coordinator = new CaptureCoordinator(pipeline, host);
        var old = PendingCaptures.Selection("old", new());
        var newer = PendingCaptures.Selection("new", new());
        ThoughtTarget? target = null;
        coordinator.ThoughtRequested += value => target = value;
        await coordinator.StageAsync(old);
        var action = host.Toasts.Last().Action!;
        await coordinator.StageAsync(newer);
        action.Invoke();
        Assert.Equal(old.Id, target!.CaptureId);
        Assert.Null(target.Commit);
        Assert.Equal(newer.Id, coordinator.Pending?.Id);
        Assert.True(coordinator.HasPendingToast);
        await coordinator.CommitPending()!;
    }

    [Fact]
    public async Task ImageActionBeforeCommitStillCarriesTheImage()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var host = new HeadlessCaptureHost(presentsUi: true);
        var coordinator = new CaptureCoordinator(pipeline, host);
        var capture = PendingCaptures.Image([137, 80, 78, 71], null, new("Image app"));
        ThoughtTarget? target = null;
        coordinator.ThoughtRequested += value => target = value;
        await coordinator.StageAsync(capture);
        host.Toasts.Last().Action!.Invoke();
        Assert.Equal(capture.Png, target!.ExcerptImagePng);
        await target.Commit!;
    }

    [Fact]
    public async Task ImageActionCarriesThePngAfterCommitAndNoTextExcerpt()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var host = new HeadlessCaptureHost(presentsUi: true);
        var coordinator = new CaptureCoordinator(pipeline, host);
        var capture = PendingCaptures.Image([137, 80, 78, 71], null, new("Image app"));
        ThoughtTarget? target = null;
        coordinator.ThoughtRequested += value => target = value;
        await coordinator.StageAsync(capture);
        var action = host.Toasts.Last().Action!;
        await coordinator.CommitPending()!;
        action.Invoke();
        Assert.Equal("Image app", target!.SourceTitle);
        Assert.Equal("Image app", target.SourceDetail);
        Assert.Null(target.ExcerptText);
        Assert.Null(target.Commit);
        Assert.Equal(capture.Png, target.ExcerptImagePng);
    }

    [Fact]
    public async Task SavingWhileAnotherCaptureOpensKeepsTheOriginalDestination()
    {
        var destination = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var writes = new List<(string? Text, Guid Id, string Path)>();
        var composer = new ThoughtComposer((text, id, path) => { writes.Add((text, id, path)); return Task.CompletedTask; });
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        composer.Begin(a, null, () => destination.Task);
        composer.Close(a, "A draft");
        var saving = composer.SaveAsync(a, "A text");
        composer.Begin(b, null, () => Task.FromResult("b.md"));
        composer.Close(b, "B draft");
        destination.SetResult("a.md");
        Assert.IsType<ThoughtSaveOutcome.Saved>(await saving);
        Assert.Equal(("A text", a, "a.md"), Assert.Single(writes));
        Assert.False(composer.Drafts.ContainsKey(a));
        Assert.Equal("B draft", composer.Drafts[b]);
    }

    [Fact]
    public void ComposerRestoresDraftBeforeDifferentSavedTextAndDropsUnchangedDraft()
    {
        var composer = new ThoughtComposer((_, _, _) => Task.CompletedTask);
        var id = Guid.NewGuid();
        Assert.Equal("saved", composer.Begin(id, "saved", () => Task.FromResult("a.md")));
        composer.Close(id, "draft");
        Assert.Equal("draft", composer.Begin(id, "different saved", () => Task.FromResult("a.md")));
        composer.Close(id, "different saved");
        Assert.Empty(composer.Drafts);
        Assert.Equal("different saved", composer.Begin(id, null, () => Task.FromResult("a.md")));
        var empty = Guid.NewGuid();
        Assert.Equal("", composer.Begin(empty, null, () => Task.FromResult("b.md")));
        composer.Close(empty, "");
        Assert.Empty(composer.Drafts);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ComposerPreservesFailedTextAndExplainsFailure(bool missing)
    {
        var composer = new ThoughtComposer((_, _, _) => Task.FromException(missing
            ? new ThoughtWriteException(ThoughtWriteError.CaptureNotFound) : new IOException("unavailable")));
        var id = Guid.NewGuid();
        composer.Begin(id, null, () => Task.FromResult("a.md"));
        var outcome = Assert.IsType<ThoughtSaveOutcome.Failed>(await composer.SaveAsync(id, "keep me"));
        Assert.Equal(missing ? ThoughtComposer.CaptureNotFoundMessage : ThoughtComposer.SaveFailedMessage, outcome.Message);
        Assert.Equal("keep me", composer.Drafts[id]);
        Assert.Equal("keep me", composer.Begin(id, null, () => Task.FromResult("a.md")));
    }

    [Fact]
    public async Task ComposerSavesToEachCapturesDestinationAndRemovesWhitespaceThoughts()
    {
        var writes = new List<(string? Text, Guid Id, string Path)>();
        var composer = new ThoughtComposer((text, id, path) => { writes.Add((text, id, path)); return Task.CompletedTask; });
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        composer.Begin(a, "old", () => Task.FromResult("a.md"));
        composer.Close(a, "new");
        composer.Begin(b, null, () => Task.FromResult("b.md"));
        composer.Close(b, "b draft");
        Assert.IsType<ThoughtSaveOutcome.Saved>(await composer.SaveAsync(a, "new"));
        Assert.Equal(("new", a, "a.md"), Assert.Single(writes));
        Assert.False(composer.Drafts.ContainsKey(a));
        Assert.Equal("b draft", composer.Drafts[b]);
        Assert.Equal("new", composer.Begin(a, null, () => Task.FromResult("a.md")));
        Assert.IsType<ThoughtSaveOutcome.Saved>(await composer.SaveAsync(a, " \n\t"));
        Assert.Null(writes.Last().Text);
        Assert.Equal("", composer.Begin(a, null, () => Task.FromResult("a.md")));
    }

    [Fact]
    public async Task PipelineWritesReadsReindexesAndRemovesThought()
    {
        using var temp = new TempDirectory();
        using var pipeline = TestPipeline.Open(temp);
        var saved = pipeline.Commit(pipeline.PrepareText("original capture", new()));
        Assert.Equal(pipeline.Vault.NoteId(saved.Destination.Url), pipeline.NotePathFor(saved.CaptureId));
        Assert.Null(pipeline.NotePathFor(Guid.NewGuid()));
        await pipeline.SetThoughtAsync("thoughtuniqueneedle", saved.CaptureId, saved.Destination.Url);
        Assert.Contains("<!-- thought:" + saved.CaptureId.ToString("D"), File.ReadAllText(saved.Destination.Url));
        Assert.Equal("thoughtuniqueneedle", await pipeline.SavedThoughtAsync(saved.CaptureId, saved.Destination.Url));
        Assert.Contains(pipeline.Index.Search("thoughtuniqueneedle"), hit => hit.NotePath == pipeline.NotePathFor(saved.CaptureId));
        await pipeline.SetThoughtAsync(null, saved.CaptureId, saved.Destination.Url);
        Assert.Null(await pipeline.SavedThoughtAsync(saved.CaptureId, saved.Destination.Url));
        Assert.DoesNotContain("<!-- thought:", File.ReadAllText(saved.Destination.Url));
        Assert.Empty(pipeline.Index.Search("thoughtuniqueneedle"));
        await Assert.ThrowsAsync<FileNotFoundException>(() => pipeline.SavedThoughtAsync(saved.CaptureId, Path.Combine(pipeline.Vault.Root, "missing.md")));
    }
}
