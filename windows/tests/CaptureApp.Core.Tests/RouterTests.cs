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
}
