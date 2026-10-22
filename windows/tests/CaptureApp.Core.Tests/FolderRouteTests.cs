using System.Text.Json;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class FolderRouteTests
{
    [Theory]
    [InlineData("")]
    [InlineData("/Users/me")]
    [InlineData("~/Notes")]
    [InlineData("C:/Notes")]
    [InlineData("a\\b")]
    [InlineData("a//b")]
    [InlineData("a/")]
    [InlineData(".hidden")]
    [InlineData("a/../b")]
    [InlineData("a/./b")]
    [InlineData(" a")]
    [InlineData("a:b")]
    [InlineData("a\n")]
    [InlineData("CON")]
    [InlineData("a.")]
    public void FolderRejectsUnsafeOrSanitizedPaths(string raw)
        => Assert.Throws<NotePathNameException>(() => new NoteFolder(raw));

    [Fact]
    public void FolderBoundsAndDecodingCannotBypassValidation()
    {
        Assert.Throws<NotePathNameException>(() => new NoteFolder(string.Join('/', Enumerable.Repeat("x", 31))));
        Assert.Throws<NotePathNameException>(() => new NoteFolder(new string('x', 121)));
        Assert.Throws<NotePathNameException>(() => new NoteFolder(string.Join('/', Enumerable.Repeat(new string('x', 120), 6))));
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<NoteFolder>("{\"rawValue\":\"../escape\"}"));
        var folder = new NoteFolder("Work/Project");
        Assert.Equal(folder, JsonSerializer.Deserialize<NoteFolder>(JsonSerializer.Serialize(folder)));
    }

    [Fact]
    public void FolderNotesOverrideSessionAndKeepPreparedIdentity()
    {
        using var e = new CheckVault(windowsRules: true);
        var active = e.Sessions.Start("Active");
        var folder = new NoteFolder("Work/Project");
        var draft = CheckVault.Capture("Topic\nbody", CaptureContentKind.Note);
        var prepared = e.Service.PrepareNote(draft, CheckVault.Zone, folder: folder);
        Assert.EndsWith(Path.Combine("Work", "Project", "Topic.md"), prepared.Destination.Url, StringComparison.Ordinal);
        Assert.Equal(CaptureContent.Note("body"), prepared.Capture.Content);
        var reserved = e.Service.PrepareNote(draft, CheckVault.Zone, folder: folder);
        Assert.Equal(prepared.Destination, reserved.Destination);
        Assert.Null(reserved.CreatesNote);
        Assert.Equal(prepared.Destination, CaptureService.AppendTarget(
            new("Topic\nbody", draft.CreatedAt, CheckVault.Zone, e.Vault.NamingRules), e.Service.ReservedNoteUrls, e.Vault, folder));
        var fresh = e.Service.PrepareNote(draft, CheckVault.Zone, newNote: true, folder: folder);
        Assert.Equal("Topic 2.md", Path.GetFileName(fresh.Destination.Url));
        var browse = new Destination(e.Vault.InboxUrl, "Inbox", NoteKind.Inbox);
        Assert.Equal(browse, e.Service.PrepareNote(draft, CheckVault.Zone, destination: browse, folder: folder).Destination);
        Assert.Throws<NotePathNameException>(() => e.Service.PrepareNote(
            CheckVault.Capture("/outside/Topic\nbody", CaptureContentKind.Note), CheckVault.Zone, folder: folder));
        Assert.Equal(NoteKind.Session, e.Service.PrepareNote(draft, CheckVault.Zone).Destination.Kind);
        Assert.Equal(active, e.Sessions.Current());
        e.Sessions.Start("Changed");
        e.Service.Save(prepared);
        var existing = e.Service.PrepareNote(draft, CheckVault.Zone, folder: folder);
        Assert.Equal(prepared.Destination, existing.Destination);
        Assert.Null(existing.CreatesNote);
        var inbox = e.Service.PrepareNote(CheckVault.Capture("Inbox\nscoped", CaptureContentKind.Note), CheckVault.Zone, folder: folder);
        Assert.Equal(NoteKind.Note, inbox.Destination.Kind);
        Assert.EndsWith(Path.Combine("Work", "Project", "Inbox.md"), inbox.Destination.Url, StringComparison.Ordinal);
        var nested = e.Service.PrepareNote(CheckVault.Capture("nested/Child\nchild", CaptureContentKind.Note), CheckVault.Zone, folder: folder);
        Directory.Delete(Path.GetDirectoryName(prepared.Destination.Url)!, true);
        e.Service.Save(nested);
        Assert.Contains("child", File.ReadAllText(nested.Destination.Url), StringComparison.Ordinal);
        Assert.Equal(nested.Destination, e.Service.Save(nested).Destination);
    }

    [Fact]
    public void NamedFolderSessionsResumeOnlyInsideTheirDirectFolder()
    {
        using var e = new CheckVault(windowsRules: true);
        var folder = new NoteFolder("Work/Project");
        var first = e.Sessions.StartInFolder(folder, "  Planning  ");
        var second = e.Sessions.StartInFolder(new("work/project"), "planning");
        Assert.Equal("Sessions/Work/Project/Planning.md", first.NotePath);
        Assert.Equal(first.NotePath, second.NotePath);
        Assert.False(first.Resumed);
        Assert.True(second.Resumed);
        Assert.Equal("Planning", first.Name);
        Assert.Equal(second, new SessionStore(e.State, e.Vault, CheckVault.Zone, CheckVault.Clock).Current());
        Assert.StartsWith("# Planning", File.ReadAllText(e.Vault.ManagedUrl(first.NotePath)), StringComparison.Ordinal);
        var elsewhere = e.Sessions.StartInFolder(new("Other"), "Planning");
        Assert.Equal("Sessions/Other/Planning.md", elsewhere.NotePath);
        Assert.False(elsewhere.Resumed);
        var datedPath = "Sessions/Work/Project/2026-10-21 Review.md";
        e.Write(datedPath, "# Existing review\n");
        var dated = e.Sessions.StartInFolder(folder, "review");
        Assert.Equal(datedPath, dated.NotePath);
        Assert.True(dated.Resumed);
        e.Write("Sessions/Work/Project/Child/Review.md", "# Nested review\n");
        Assert.Equal(datedPath, e.Sessions.StartInFolder(folder, "review").NotePath);
        var current = e.Sessions.Current();
        var bytes = File.ReadAllBytes(e.Sessions.StateFileUrl);
        foreach (var invalid in new[] { "", " \n\t", "../escape", "/outside", "Child/escape", "Child\\escape", ".hidden", "~home", "bad\0name", "CON" })
            Assert.Throws<NotePathNameException>(() => e.Sessions.StartInFolder(folder, invalid));
        Assert.Equal(current, e.Sessions.Current());
        Assert.Equal(bytes, File.ReadAllBytes(e.Sessions.StateFileUrl));
        e.Write("Sessions/Work/Project/2026-10-20 Review.md", "# Second review\n");
        var ambiguity = Assert.Throws<SessionStoreException>(() => e.Sessions.StartInFolder(folder, "Review"));
        Assert.Equal(SessionStoreError.Ambiguous, ambiguity.Kind);
        Assert.Equal(2, ambiguity.Candidates.Count);
        Assert.All(ambiguity.Candidates, candidate => Assert.Equal("Sessions/Work/Project", string.Join('/', candidate.NotePath.Split('/').SkipLast(1))));
        Assert.Equal(current, e.Sessions.Current());
        Assert.Equal(bytes, File.ReadAllBytes(e.Sessions.StateFileUrl));
    }

    [Fact]
    public void BlankSessionNamesDoNotCreateVaultOrState()
    {
        using var e = new CheckVault(windowsRules: true);
        var folder = new NoteFolder("Work/Project");
        foreach (var blank in new[] { "", "   ", "\n\t" })
        {
            Assert.Equal(NotePathNameError.EmptyPath, Assert.Throws<NotePathNameException>(() => e.Sessions.Start(blank)).Kind);
            Assert.Equal(NotePathNameError.EmptyPath, Assert.Throws<NotePathNameException>(() => e.Sessions.StartInFolder(folder, blank)).Kind);
        }
        Assert.Null(e.Sessions.Current());
        Assert.False(Directory.Exists(e.Vault.Root));
        Assert.False(Directory.Exists(e.State));
    }
}
