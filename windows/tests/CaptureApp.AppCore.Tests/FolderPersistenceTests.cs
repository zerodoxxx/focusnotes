using System.Text.Json;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class FolderPersistenceTests
{
    [Fact]
    public void DraftPreservesFolderAcrossScheduledPinFlushAndCompletion()
    {
        using var temp = new TempDirectory();
        using var drafts = new NoteDraftStore(temp.Path, debounceInterval: TimeSpan.FromMinutes(1));
        var a = new NoteFolder("Work/A");
        var b = new NoteFolder("Work/B");
        drafts.ScheduleStore("older", folder: a);
        drafts.ScheduleStore("same text", pinOnSave: true, folder: b);
        drafts.SetPinOnSave(false);
        drafts.SetPinOnSave(true);
        Assert.Equal(new("same text", true, b), drafts.LoadSnapshot());
        using var reopened = new NoteDraftStore(temp.Path);
        Assert.Equal(new("same text", true, b), reopened.LoadSnapshot());
        bool? intent = null;
        drafts.CompleteSave("same text", null, pin => intent = pin, folder: a);
        Assert.False(intent);
        Assert.Equal(b, drafts.LoadSnapshot().Folder);
        drafts.CompleteSave("same text", null, pin => intent = pin);
        Assert.False(intent);
        Assert.Equal(b, drafts.LoadSnapshot().Folder);
        drafts.ClearIfMatching("same text", a);
        Assert.Equal(b, drafts.LoadSnapshot().Folder);
        drafts.CompleteSave("same text\n", null, pin => intent = pin, folder: b);
        Assert.True(intent);
        Assert.Equal(new("", false), drafts.LoadSnapshot());
        drafts.Store("legacy JSON", true);
        drafts.CompleteSave("legacy JSON", null, pin => intent = pin);
        Assert.True(intent);
        Assert.Equal(new("", false), drafts.LoadSnapshot());
        drafts.Store("scoped", folder: a);
        drafts.FlushScheduledStore("ordinary");
        Assert.Null(drafts.LoadSnapshot().Folder);
        drafts.Store("scoped", folder: a);
        drafts.ScheduleStore("ordinary");
        Assert.Null(drafts.LoadSnapshot().Folder);
        drafts.Store("blank", folder: a);
        drafts.FlushScheduledStore(" \n", folder: a);
        Assert.False(File.Exists(drafts.Url));
        Assert.Null(drafts.LoadSnapshot().Folder);
    }

    [Fact]
    public void UnsafeSerializedFolderIsQuarantinedAndLegacyDraftStillLoads()
    {
        using var temp = new TempDirectory();
        using var drafts = new NoteDraftStore(temp.Path);
        File.WriteAllText(drafts.Url, "{\"text\":\"unsafe\",\"pinOnSave\":true,\"folder\":{\"rawValue\":\"../escape\"}}");
        Assert.Empty(drafts.Load());
        Assert.True(File.Exists(Path.Combine(temp.Path, "draft-note.corrupt.json")));
        File.WriteAllText(drafts.Url, "{\"text\":\"legacy\",\"pinOnSave\":true}");
        Assert.Equal(new("legacy", true), drafts.LoadSnapshot());
    }

    [Fact]
    public async Task JournalReplayKeepsFolderIdentityAndDoesNotConsumeAnotherFoldersDraft()
    {
        using var temp = new TempDirectory();
        var state = Path.Combine(temp.Path, "state");
        var vault = Path.Combine(temp.Path, "vault");
        var a = new NoteFolder("Work/A");
        var b = new NoteFolder("Work/B");
        const string draft = "Topic\nreplayneedle";
        // Recovery dates use double seconds since 2001; whole seconds round-trip exactly.
        var createdAt = new DateTimeOffset(2026, 10, 22, 14, 30, 0, TimeSpan.Zero);
        CaptureJob original;
        using (var pipeline = CapturePipeline.Open(vault, state, TimeZoneInfo.Utc))
        {
            pipeline.Sessions.Start("Active");
            original = pipeline.PrepareNote(draft, new(), createdAt: createdAt, folder: a);
            Assert.Equal(a, original.NoteFolder);
            pipeline.Journal.Store(original);
            pipeline.Drafts.Store(draft, true, b);
        }
        using var reopened = CapturePipeline.Open(vault, state, TimeZoneInfo.Utc);
        var loaded = reopened.Journal.Load(Assert.Single(reopened.Journal.RecordPaths()));
        Assert.Equal(a, loaded.NoteFolder);
        Assert.Equal(original.Prepared, loaded.Prepared);
        reopened.Sessions.Start("Changed");
        Assert.Equal(1, await reopened.ReplayUnsavedAsync(TestContext.Current.CancellationToken));
        Assert.Equal(b, reopened.Drafts.LoadSnapshot().Folder);
        Assert.Equal(draft, reopened.Drafts.Load());
        Assert.False(reopened.Pins.IsPinned(reopened.Vault.NoteId(original.Prepared.Destination.Url)));
        Assert.Contains("replayneedle", File.ReadAllText(original.Prepared.Destination.Url), StringComparison.Ordinal);
        Assert.Empty(reopened.Journal.RecordPaths());
        var matching = reopened.PrepareNote(draft, new(), folder: b);
        reopened.Journal.Store(matching);
        Assert.Equal(1, await reopened.ReplayUnsavedAsync(TestContext.Current.CancellationToken));
        Assert.Empty(reopened.Drafts.Load());
        Assert.True(reopened.Pins.IsPinned(reopened.Vault.NoteId(matching.Prepared.Destination.Url)));
    }
}
