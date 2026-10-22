using System.Text.Json;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class TypedNoteCollisionTests
{
    [Fact]
    public void DefaultSaveUsesTheExactPathWithoutMatchingOtherFoldersOrHeaders()
    {
        using var e = new CheckVault(windowsRules: true);
        var archived = e.Write("Archive/Foo.md", "# A different header\n\nExisting body\n");
        e.Write("Other.md", "# Header only match\n");

        var nested = Prepare(e, "archive/foo\n\nAppended body");
        Assert.Equal(archived, nested.Destination.Url);
        Assert.Null(nested.CreatesNote);
        Assert.True(nested.NoteMarkerIsIdentity);
        Assert.Equal("\nAppended body", nested.Capture.Content.Value);
        Assert.Equal(nested.Destination, Target(e, "archive/foo"));

        var bare = Prepare(e, "Foo\n\nRoot body");
        Assert.Equal(e.Vault.UrlForRelativePath("Foo.md"), bare.Destination.Url);
        Assert.True(bare.CreatesNote);
        Assert.Equal(bare.Destination, Target(e, "Foo"));
        var header = Prepare(e, "Header only match\n\nIndependent body");
        Assert.Equal(e.Vault.UrlForRelativePath("Header only match.md"), header.Destination.Url);
        Assert.True(header.CreatesNote);
        Assert.Null(Target(e, "Missing/Foo"));

        e.Service.Save(nested);
        var contents = CheckVault.Read(archived);
        Assert.StartsWith("# A different header\n\nExisting body\n", contents, StringComparison.Ordinal);
        Assert.Equal(1, contents.Split("<!-- note:" + nested.Capture.Id, StringSplitOptions.None).Length - 1);
        e.Service.Save(JsonSerializer.Deserialize<PreparedCapture>(JsonSerializer.Serialize(nested))!);
        Assert.Equal(contents, CheckVault.Read(archived));
        Assert.False(File.Exists(e.Vault.UrlForRelativePath("Archive/Foo 2.md")));
    }

    [Fact]
    public void UnsavedReservationsIgnoreCaseAndForceNewSkipsEveryReservedSuffix()
    {
        using var e = new CheckVault(windowsRules: true);
        var first = Prepare(e, "Archive/Casefoo\n\nFirst body");
        var append = Prepare(e, "archive/casefoo\n\nSecond body");
        Assert.True(first.CreatesNote);
        Assert.Null(append.CreatesNote);
        Assert.Equal(first.Destination.Url, append.Destination.Url);
        Assert.Equal(first.Destination.Url, Target(e, "ARCHIVE/CASEFOO")!.Url);
        Assert.Single(e.Service.ReservedNoteUrls);
        Assert.False(Directory.Exists(e.Vault.Root));

        var second = Prepare(e, "archive/casefoo\n\nAs new", newNote: true);
        var third = Prepare(e, "ARCHIVE/CASEFOO\n\nAnother new", newNote: true);
        Assert.Equal("casefoo 2.md", Path.GetFileName(second.Destination.Url), ignoreCase: true);
        Assert.Equal("casefoo 3.md", Path.GetFileName(third.Destination.Url), ignoreCase: true);
        Assert.True(second.CreatesNote);
        Assert.True(third.CreatesNote);
        Assert.Equal(first.Destination.Url, Prepare(e, "archive/casefoo\n\nStill append").Destination.Url);

        e.Service.Save(first);
        e.Service.Save(append);
        Assert.DoesNotContain(first.Destination.Url, e.Service.ReservedNoteUrls);
        Assert.Equal(first.Destination.Url, Target(e, "archive/casefoo")!.Url);
        Assert.Contains("Second body", CheckVault.Read(first.Destination.Url), StringComparison.Ordinal);
    }

    [Fact]
    public void InboxAndTitleOnlyAppendsKeepTheirTextWhileNewTitleOnlyNotesKeepAnEmptyBody()
    {
        using var e = new CheckVault(windowsRules: true);
        var inbox = Prepare(e, "inbox");
        Assert.Equal(new Destination(e.Vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox), inbox.Destination);
        Assert.Null(inbox.CreatesNote);
        Assert.Equal("inbox", inbox.Capture.Content.Value);
        Assert.Equal(inbox.Destination, Target(e, "Inbox"));
        e.Service.Save(inbox);
        Assert.Contains("\n\ninbox\n", CheckVault.Read(e.Vault.InboxUrl), StringComparison.Ordinal);

        var path = e.Write("Buy milk.md", "# Buy milk\n");
        var append = Prepare(e, "# Buy milk");
        Assert.Equal(path, append.Destination.Url);
        Assert.Null(append.CreatesNote);
        Assert.Equal("# Buy milk", append.Capture.Content.Value);
        e.Service.Save(append);
        Assert.Contains("\n\n# Buy milk\n", CheckVault.Read(path), StringComparison.Ordinal);

        var created = Prepare(e, "New title only");
        Assert.True(created.CreatesNote);
        Assert.Empty(created.Capture.Content.Value);
        var forced = Prepare(e, "# Buy milk", newNote: true);
        Assert.True(forced.CreatesNote);
        Assert.Empty(forced.Capture.Content.Value);
        Assert.Equal("Buy milk 2.md", Path.GetFileName(forced.Destination.Url));
    }

    [Fact]
    public void GeneratedTitlesAlwaysCreateAndNumberOnBothReservedAndExistingCollisions()
    {
        using var e = new CheckVault(windowsRules: true);
        var generated = new TypedNote("<!-- hidden -->", CheckVault.Now, CheckVault.Zone, e.Vault.NamingRules);
        Assert.True(generated.IsGeneratedTitle);
        Assert.False(new TypedNote("\n\nFirst text line", CheckVault.Now, CheckVault.Zone).IsGeneratedTitle);
        Assert.Null(Target(e, "<!-- hidden -->"));
        var first = Prepare(e, "<!-- hidden -->");
        var second = Prepare(e, "\n\n");
        Assert.True(first.CreatesNote);
        Assert.True(second.CreatesNote);
        Assert.Equal("Note 2026-10-13 14.30.md", Path.GetFileName(first.Destination.Url));
        Assert.Equal("Note 2026-10-13 14.30 2.md", Path.GetFileName(second.Destination.Url));
        e.Service.Save(first);
        e.Service.Save(second);
        var third = Prepare(e, "\n\n");
        Assert.True(third.CreatesNote);
        Assert.Equal("Note 2026-10-13 14.30 3.md", Path.GetFileName(third.Destination.Url));
        Assert.Null(Target(e, "\n\n"));
    }

    [Fact]
    public void ForceNewKeepsTheFolderAndSkipsExistingFilesAndDirectories()
    {
        using var e = new CheckVault(windowsRules: true);
        var original = e.Write("Archive/Foo.md", "# Foo\n\nOriginal body\n");
        e.Write("Archive/Foo 2.md", "# Second\n");
        Directory.CreateDirectory(e.Vault.UrlForRelativePath("Archive/Foo 3.md"));
        var prepared = Prepare(e, "archive\\foo\n\nIndependent body", newNote: true);
        Assert.True(prepared.CreatesNote);
        Assert.Equal(e.Vault.UrlForRelativePath("Archive/foo 4.md"), prepared.Destination.Url);
        Assert.Equal("foo 4", prepared.Destination.Title);
        e.Service.Save(prepared);
        Assert.Contains("Independent body", CheckVault.Read(prepared.Destination.Url), StringComparison.Ordinal);
        Assert.Equal("# Foo\n\nOriginal body\n", CheckVault.Read(original));
    }

    [Fact]
    public void HomeRelativeWindowsPathsAppendAndCreateNumberedExternalNotes()
    {
        using var e = new CheckVault(registry: true, windowsRules: true);
        var original = e.Write("Desktop/External.md", "# External\n\nOriginal external body\n", home: true);
        var append = Prepare(e, "/desktop\\external\n\nAppended external body");
        Assert.Equal(original, append.Destination.Url);
        Assert.Null(append.CreatesNote);
        Assert.Equal(original, Target(e, "/DESKTOP/EXTERNAL")!.Url);
        e.Service.Save(append);
        var forced = Prepare(e, "/desktop\\external\n\nIndependent external body", newNote: true);
        Assert.True(forced.CreatesNote);
        Assert.Equal(Path.Combine(e.Home, "Desktop", "external 2.md"), forced.Destination.Url);
        e.Service.Save(forced);
        Assert.Equal(new[] { "Desktop/External.md", "Desktop/external 2.md" }, e.Vault.ExternalNoteRegistry!.Paths());
        Assert.Contains("Appended external body", CheckVault.Read(original), StringComparison.Ordinal);
        Assert.DoesNotContain("Independent external body", CheckVault.Read(original), StringComparison.Ordinal);
        Assert.Contains("Independent external body", CheckVault.Read(forced.Destination.Url), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("CON")]
    [InlineData("folder/NUL.md")]
    [InlineData("folder\\LPT1")]
    [InlineData("folder/name.")]
    public void AppendResolverAndForceNewBothRejectWindowsReservedNames(string name)
    {
        using var e = new CheckVault(windowsRules: true);
        Assert.Throws<NotePathNameException>(() => Target(e, name));
        Assert.Throws<NotePathNameException>(() => Prepare(e, name, newNote: true));
        Assert.Empty(e.Service.ReservedNoteUrls);
        Assert.False(Directory.Exists(e.Vault.Root));
    }

    private static PreparedCapture Prepare(CheckVault e, string markdown, bool newNote = false) =>
        e.Service.PrepareNote(CheckVault.Capture(markdown, CaptureContentKind.Note), CheckVault.Zone, newNote: newNote);

    private static Destination? Target(CheckVault e, string markdown) => CaptureService.AppendTarget(
        new TypedNote(markdown, CheckVault.Now, CheckVault.Zone, e.Vault.NamingRules), e.Service.ReservedNoteUrls, e.Vault);
}
