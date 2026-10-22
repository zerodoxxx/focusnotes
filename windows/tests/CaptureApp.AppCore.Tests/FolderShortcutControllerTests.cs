using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class FolderShortcutControllerTests
{
    [Fact]
    public async Task FolderNoteOverridesSessionAndBrowseOverridesFolder()
    {
        using var temp = new TempDirectory();
        using var pipeline = CapturePipeline.Open(Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var active = await coordinator.StartSessionAsync("Existing");
        var before = File.ReadAllText(pipeline.Vault.ManagedUrl(active.NotePath));
        var folder = new NoteFolder("Work/Research");
        var saved = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync("Biology\n\nfolder body", folder: folder));
        Assert.Equal(Path.Combine(pipeline.Vault.Root, "Work", "Research", "Biology.md"), saved.Destination.Url);
        Assert.Equal(active, pipeline.Sessions.Current());
        Assert.Equal(before, File.ReadAllText(pipeline.Vault.ManagedUrl(active.NotePath)));
        Assert.Empty(pipeline.Drafts.Load());
        var picked = new Destination(Path.Combine(pipeline.Vault.Root, "Chosen.md"), "Chosen", NoteKind.Note);
        var browsed = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync("different\n\nbody", picked, folder: folder));
        Assert.Equal(picked, browsed.Destination);
        var numbered = Assert.IsType<SavedCapture>(await coordinator.AddNoteAsync("Biology\n\nnew body", newNote: true, folder: folder));
        Assert.EndsWith("Biology 2.md", numbered.Destination.Url, StringComparison.Ordinal);
    }

    [Fact]
    public async Task NamedFolderSessionsCreateResumeAndEditorNewRetainsFolder()
    {
        using var temp = new TempDirectory();
        using var pipeline = CapturePipeline.Open(Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var first = await coordinator.StartFolderSessionAsync("Work/Calls", "Planning");
        var second = await coordinator.StartFolderSessionAsync("Work/Calls", "Review");
        Assert.StartsWith("Sessions/Work/Calls/", first.NotePath);
        Assert.NotEqual(first.NotePath, second.NotePath);
        Assert.Equal(second, pipeline.Sessions.Current());
        var resumed = await coordinator.StartFolderSessionAsync("Work/Calls", "Planning");
        Assert.Equal(first.NotePath, resumed.NotePath);
        Assert.True(resumed.Resumed);
        var before = File.ReadAllBytes(pipeline.Vault.ManagedUrl(resumed.NotePath));
        foreach (var invalid in new[] { "", "   ", "../Elsewhere", "nested/name", "nested\\name" })
            await Assert.ThrowsAsync<NotePathNameException>(() => coordinator.StartFolderSessionAsync("Work/Calls", invalid));
        Assert.Equal(resumed, pipeline.Sessions.Current());
        Assert.Equal(resumed, coordinator.ActiveSession);
        Assert.Equal(before, File.ReadAllBytes(pipeline.Vault.ManagedUrl(resumed.NotePath)));
        await coordinator.StartFolderSessionAsync("Other", "Outside");
        await coordinator.StartFolderSessionAsync("Work/Calls/Nested", "Nested");
        var suggestions = await coordinator.FolderSessionSuggestionsAsync("work/calls");
        Assert.Equal(new[] { "Planning", "Review" }, suggestions.Select(s => s.Title).Order().ToArray());
        Assert.All(suggestions, suggestion => Assert.StartsWith("Sessions/Work/Calls/", suggestion.Path));
        var folder = new NoteFolder("Work/Research");
        var state = new QuickNoteState(null, folder: folder);
        state.Destination = new Destination(pipeline.Vault.InboxUrl, "Inbox", NoteKind.Inbox);
        state.ReturnToSession(new Destination(pipeline.Vault.ManagedUrl(second.NotePath), second.Name, NoteKind.Session));
        Assert.Null(state.Destination);
        Assert.Equal(folder, state.Folder);
        Assert.True(state.OutsideSession);
        Assert.Equal("Folder: Work/Research", state.DestinationLabel);
    }
}
