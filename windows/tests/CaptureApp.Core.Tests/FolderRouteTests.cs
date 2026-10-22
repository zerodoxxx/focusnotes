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
    public void FolderSessionsAreAlwaysNewAndSurviveReloadAndConcurrentCollision()
    {
        using var e = new CheckVault(windowsRules: true);
        var folder = new NoteFolder("Work/Project");
        var first = e.Sessions.StartInFolder(folder);
        var second = e.Sessions.StartInFolder(folder);
        Assert.StartsWith("Sessions/Work/Project/Session 2026-10-13 14.30.00", first.NotePath, StringComparison.Ordinal);
        Assert.EndsWith(" 2.md", second.NotePath, StringComparison.Ordinal);
        Assert.False(first.Resumed);
        Assert.False(second.Resumed);
        Assert.Equal(second, new SessionStore(e.State, e.Vault, CheckVault.Zone, CheckVault.Clock).Current());
        Assert.StartsWith("# " + first.Name, File.ReadAllText(e.Vault.ManagedUrl(first.NotePath)), StringComparison.Ordinal);
        var colliding = new SessionStore(e.State, e.Vault, CheckVault.Zone, CheckVault.Clock,
            path => { if (!path.EndsWith(" 2.md", StringComparison.Ordinal)) e.Write(path, "# Concurrent writer\n"); });
        var raced = colliding.StartInFolder(new("Race"));
        Assert.EndsWith(" 2.md", raced.NotePath, StringComparison.Ordinal);
        Assert.Contains("Concurrent writer", File.ReadAllText(e.Vault.ManagedUrl(raced.NotePath.Replace(" 2.md", ".md", StringComparison.Ordinal))), StringComparison.Ordinal);
    }
}
