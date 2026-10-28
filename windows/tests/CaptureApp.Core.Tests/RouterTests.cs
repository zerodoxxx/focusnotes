using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class RouterTests
{
    [Fact]
    public void AllRoutingPrioritiesAndCanonicalPaths()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        foreach (var file in new Dictionary<string, string>
        {
            ["Foo.md"] = "# Something Else\n",
            ["Bar.md"] = "# Bar\n",
            ["Science/Math/Trigonometry.md"] = "# Existing nested note\n",
            ["Sessions/2026-10-13 Design.md"] = "# 2026-10-13 Design\n",
            ["Sessions/2026-10-13 Standup.md"] = "# Standup\n"
        }

        )
        {
            e.Write(file.Key, file.Value);
        }

        var notes = e.Vault.ListNotes();
        var session = new Session("Standup", "Sessions/2026-10-13 Standup.md", CheckVault.Now);
        var cases = new (string? Title, Session? Session, string Path, string Display, NoteKind Kind)[]
        {
            ("Bar", null, "Bar.md", "Bar", NoteKind.Note),
            ("  bar  ", null, "Bar.md", "Bar", NoteKind.Note),
            ("Something Else", null, "Foo.md", "Something Else", NoteKind.Note),
            ("Foo", null, "Foo.md", "Foo", NoteKind.Note),
            ("Standup", null, session.NotePath, "Standup", NoteKind.Session),
            ("Inbox", session, "Inbox.md", "Inbox", NoteKind.Inbox),
            ("", session, session.NotePath, "Standup", NoteKind.Session),
            (null, null, "Inbox.md", "Inbox", NoteKind.Inbox),
            (" \t ", null, "Inbox.md", "Inbox", NoteKind.Inbox),
            ("New title", session, "New title.md", "New title", NoteKind.Note),
            ("science/math/trigonometry", session, "Science/Math/Trigonometry.md", "trigonometry", NoteKind.Note)
        };
        foreach (var row in cases)
        {
            var result = Router.Destination(row.Title, row.Session, notes, e.Vault);
            Assert.Equal(e.Vault.UrlForRelativePath(row.Path), result.Url);
            Assert.Equal(row.Display, result.Title);
            Assert.Equal(row.Kind, result.Kind);
        }

        e.Write("Root standup.md", "# Standup\n");
        Assert.Equal(NoteKind.Note, Router.Destination("Standup", null, e.Vault.ListNotes(), e.Vault).Kind);
        var home = Router.Destination("/Desktop/science/math/trigonometry", null, notes, e.Vault);
        Assert.Equal(Path.GetFullPath(Path.Combine(e.Home, "Desktop/science/math/trigonometry.md")), home.Url);
        Assert.Equal("trigonometry", home.Title);
        Assert.Equal(NoteKind.Note, home.Kind);
        Assert.Throws<NotePathNameException>(() => Router.Destination("science/../escape", null, notes, e.Vault));
    }

    [Fact]
    public void RootNoteBeatsAnEarlierNestedNoteWithTheSameTitle()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        e.Write("Archive/Ideas.md", "# Ideas\n");
        e.Write("Ideas.md", "# Ideas\n");
        var result = Router.Destination("ideas", null, e.Vault.ListNotes(), e.Vault);
        Assert.Equal(e.Vault.UrlForRelativePath("Ideas.md"), result.Url);
        Assert.Equal(NoteKind.Note, result.Kind);
    }

    [Fact]
    public void BareTitleOfANestedOrHomeNoteCreatesARootNote()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        e.Write("Archive/Ideas.md", "# Ideas\n");
        e.Write("Archive/More/Ideas.md", "# Ideas\n");
        e.Write("Desktop/Journal.md", "# Journal\n", true);
        e.Vault.ExternalNoteRegistry!.Register("Desktop/Journal.md");
        var notes = e.Vault.ListNotes();
        Assert.Contains(notes, n => n.Title == "Journal");
        var nested = Router.Destination("Ideas", null, notes, e.Vault);
        Assert.Equal(e.Vault.UrlForRelativePath("Ideas.md"), nested.Url);
        Assert.Equal("Ideas", nested.Title);
        var home = Router.Destination("Journal", null, notes, e.Vault);
        Assert.Equal(e.Vault.UrlForRelativePath("Journal.md"), home.Url);
        Assert.Equal(NoteKind.Note, home.Kind);
    }

    [Fact]
    public void DuplicateRootTitlesAreAmbiguousWithSortedCandidates()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        e.Write("Ideas.md", "# Ideas\n");
        e.Write("Ideas 2.md", "# Ideas\n");
        e.Write("Archive/Ideas.md", "# Ideas\n");
        var failure = Assert.Throws<RouterAmbiguousException>(() => Router.Destination(" IDEAS ", null, e.Vault.ListNotes(), e.Vault));
        Assert.Equal(new[] { e.Vault.UrlForRelativePath("Ideas 2.md"), e.Vault.UrlForRelativePath("Ideas.md") }, failure.Candidates.Select(c => c.Url));
        Assert.All(failure.Candidates, c => Assert.Equal(NoteKind.Note, c.Kind));
    }

    [Fact]
    public void DuplicateSessionTitlesAreAmbiguousUnlessARootNoteMatchesFirst()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        e.Write("Sessions/2026-10-13 Standup.md", "# Standup\n");
        e.Write("Sessions/2026-10-14 Standup.md", "# Standup\n");
        var failure = Assert.Throws<RouterAmbiguousException>(() => Router.Destination("standup", null, e.Vault.ListNotes(), e.Vault));
        Assert.Equal(new[] { e.Vault.UrlForRelativePath("Sessions/2026-10-13 Standup.md"), e.Vault.UrlForRelativePath("Sessions/2026-10-14 Standup.md") },
            failure.Candidates.Select(c => c.Url));
        Assert.All(failure.Candidates, c => Assert.Equal(NoteKind.Session, c.Kind));
        e.Write("Team standup.md", "# Standup\n");
        var root = Router.Destination("standup", null, e.Vault.ListNotes(), e.Vault);
        Assert.Equal(e.Vault.UrlForRelativePath("Team standup.md"), root.Url);
        Assert.Equal(NoteKind.Note, root.Kind);
    }

    [Fact]
    public void ExplicitPathReachesANestedNoteSharingItsTitleWithARootNote()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        e.Write("Archive/Ideas.md", "# Ideas\n");
        e.Write("Ideas.md", "# Ideas\n");
        var result = Router.Destination("archive/ideas", null, e.Vault.ListNotes(), e.Vault);
        Assert.Equal(e.Vault.UrlForRelativePath("Archive/Ideas.md"), result.Url);
        Assert.Equal("ideas", result.Title);
        Assert.Equal(NoteKind.Note, result.Kind);
    }

    [Theory]
    [InlineData("pros / cons", "pros - cons.md")]
    [InlineData("pros \\ cons", "pros - cons.md")]
    [InlineData("TODO/", "TODO-.md")]
    [InlineData("a//b", "a--b.md")]
    [InlineData("https://example.com/page", "https---example.com-page.md")]
    public void MalformedSlashFormsKeepTheFlatFileName(string title, string file)
    {
        using var e = new CheckVault(windowsRules: true);
        e.Vault.Prepare();
        var result = Router.Destination(title, null, e.Vault.ListNotes(), e.Vault);
        Assert.Equal(e.Vault.UrlForRelativePath(file), result.Url);
        Assert.Equal(NoteTitle.CleanTitle(title), result.Title);
        Assert.Equal(NoteKind.Note, result.Kind);
    }

    [Theory]
    [InlineData("..")]
    [InlineData("a/..")]
    [InlineData("CON")]
    [InlineData("C:\\Notes\\a")]
    public void UnsafeNamesStillThrow(string title)
    {
        using var e = new CheckVault(windowsRules: true);
        e.Vault.Prepare();
        Assert.Throws<NotePathNameException>(() => Router.Destination(title, null, e.Vault.ListNotes(), e.Vault));
    }
}
