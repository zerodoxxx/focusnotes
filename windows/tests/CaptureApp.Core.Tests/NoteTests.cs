using System.Text.Json;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class NoteTests
{
    [Fact]
    public void TypedNoteFormatSourceGroupingHeadingsAndInterruptedReplay()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var d = new Destination(e.Vault.InboxUrl, "Inbox", NoteKind.Inbox);
        var id = Guid.Parse("A1B2C3D4-0000-4000-8000-000000000010");
        const string raw = "\n  typednoteneedle **bold**  \n- [ ] task\n\n  tail  \n\t";
        var note = new Capture(id, CheckVault.Now, CaptureContent.Note(raw), new());
        var expected = $"<!-- note:{id:D} at=2026-10-13T14:30:00+05:30 -->\n\n\n  typednoteneedle **bold**  \n- [ ] task\n\n  tail\n";
        Assert.Equal(expected, CaptureFormat.Block(note, "", CheckVault.Zone));
        var source = new CaptureSource("Firefox", "System Design — Mozilla Firefox");
        e.Writer.AppendIfMissing(CheckVault.Capture("first capture") with { Source = source }, d);
        e.Writer.AppendIfMissing(note, d);
        var saved = CheckVault.Read(d.Url);
        e.Writer.AppendIfMissing(note, d);
        Assert.Equal(saved, CheckVault.Read(d.Url));
        e.Writer.AppendIfMissing(CheckVault.Capture("second capture") with { Source = source }, d);
        Assert.Equal(1, Count(CheckVault.Read(d.Url), "### System Design\n"));
        e.Writer.AppendIfMissing(CheckVault.Capture("## Typed heading\nbody", CaptureContentKind.Note), d);
        e.Writer.AppendIfMissing(CheckVault.Capture("third capture") with { Source = source }, d);
        Assert.Equal(2, Count(CheckVault.Read(d.Url), "### System Design\n"));
        var block = NoteParser.Parse(CheckVault.Read(d.Url), "Inbox.md", "", CheckVault.Zone).Blocks.Single(b => b.CaptureId == id);
        Assert.Equal(BlockKind.Note, block.Kind);
        Assert.Equal(CheckVault.Now, block.CreatedAt);
        Assert.Null(block.SourceApp);
        Assert.Null(block.WindowTitle);
        Assert.Equal(CaptureFormat.NoteBody(raw), block.Body);
        var fragment = "# Interrupted\n\n" + expected[..95];
        var broken = e.Write("Interrupted note.md", fragment);
        var brokenDestination = CheckVault.Destination(broken, "Interrupted");
        e.Writer.AppendIfMissing(note, brokenDestination);
        e.Writer.AppendIfMissing(note, brokenDestination);
        Assert.StartsWith(fragment, CheckVault.Read(broken), StringComparison.Ordinal);
        var recovered = NoteParser.Parse(CheckVault.Read(broken), "Interrupted note.md", "", CheckVault.Zone).Blocks;
        Assert.Single(recovered, b => b.CaptureId == id);
        Assert.Equal(CaptureFormat.NoteBody(raw), recovered[^1].Body);
    }

    [Fact]
    public void TitleDerivationAndPhysicalFirstLineRules()
    {
        using var e = new CheckVault();
        var longTitle = string.Join(' ', Enumerable.Repeat("word", 15));
        var cases = new (string Markdown, string Expected)[]
        {
            ("\n## A **clear** _heading_ ##\nbody", "A clear heading"),
            ("  - [x] Review ~~the~~ `plan`", "Review the plan"),
            ("[Link title](https://example.com) <!-- hidden -->", "Link title"),
            ("snake_case and literal ~ tilde", "snake_case and literal ~ tilde"),
            ("> - **Nested** quote", "Nested quote"),
            (" \n\t", "Note 2026-10-13 14.30"),
            ("<!-- only a comment -->", "Note 2026-10-13 14.30"),
            ("# 😀 家族 👨‍👩‍👧‍👦 計画", "😀 家族 👨‍👩‍👧‍👦 計画"),
            (longTitle, string.Join(' ', Enumerable.Repeat("word", 12)) + "…"),
            (new string ('計', 61), new string ('計', 60) + "…"),
            (string.Concat(Enumerable.Repeat("😀", 61)), string.Concat(Enumerable.Repeat("😀", 60)) + "…")
        };
        TypedNote Note(string markdown) => new(markdown, CheckVault.Now, CheckVault.Zone, e.Vault.NamingRules);
        foreach (var row in cases)
        {
            Assert.Equal(row.Expected, Note(row.Markdown).Title);
        }

        Assert.Equal("Title", Note("Title\vbody").Title);
        Assert.Equal("body", Note("Title\vbody").Body);
        Assert.Equal("Title", Note("Title\fbody").Title);
        var nested = Note("# science/math/trigonometry\n\nBody");
        Assert.Equal("science/math/trigonometry", nested.RawName);
        Assert.Equal(new[] { "science", "math", "trigonometry" }, nested.PathName!.Components);
        Assert.Equal("trigonometry", nested.Title);
        Assert.Equal("\nBody", nested.Body);
        var longNested = Note("# science/math/" + longTitle + "\nBody");
        Assert.Equal(longTitle, longNested.PathName!.LeafName);
        Assert.EndsWith("…", longNested.Title, StringComparison.Ordinal);
        foreach (var markdown in new[]
        {
            "- title",
            "* title",
            "+ title",
            "1. title",
            "- [ ] title",
            "- [x] title",
            "> title",
            "`title`",
            "    title",
            "```title"
        }

        )
        {
            Assert.Equal(markdown, Note(markdown).Body);
        }

        foreach (var markdown in new[]
        {
            "Title",
            "# Title",
            "**Title**",
            "[Title](https://example.com)",
            "Title <!-- hidden -->"
        }

        )
        {
            Assert.Empty(Note(markdown).Body);
        }

        Assert.Equal("\n  untouched  \nnext", Note("# Title\n\n  untouched  \nnext  ").Body);
        Assert.Equal("\n# Title\nbody", Note("\n# Title\nbody").Body);
        Assert.Equal(longTitle, Note(longTitle).Body);
        foreach (var (name, stem) in new[]
        {
            ("Read https://example.com", "Read https---example.com"),
            ("TODO/", "TODO-"),
            ("a//b", "a--b"),
            ("pros / cons of X", "pros - cons of X")
        }

        )
        {
            var n = Note("# " + name + "\n\nFallback body");
            Assert.Equal(new[] { stem }, n.PathName!.Components);
            Assert.Equal(name, n.Title);
            Assert.Equal("\nFallback body", n.Body);
            var prepared = e.Service.PrepareNote(CheckVault.Capture("# " + name + "\n\nFallback body", CaptureContentKind.Note), CheckVault.Zone);
            Assert.Equal(stem + ".md", Path.GetFileName(prepared.Destination.Url));
            e.Service.Save(prepared);
            Assert.StartsWith("# " + name + "\n\n<!-- note:", CheckVault.Read(prepared.Destination.Url), StringComparison.Ordinal);
        }
    }

    [Fact]
    public void InvalidExplicitPathsRetainSpecificErrors()
    {
        using var e = new CheckVault();
        var invalid = new[]
        {
            ("science/../escape", NotePathNameError.InvalidComponent),
            ("folder/ ../outside", NotePathNameError.InvalidComponent),
            ("folder/. /outside", NotePathNameError.InvalidComponent),
            ("/Desktop/../escape", NotePathNameError.InvalidComponent),
            ("folder/name\0", NotePathNameError.InvalidComponent),
            ("folder/~$draft", NotePathNameError.InvalidComponent),
            (string.Join('/', Enumerable.Repeat("x", 33)), NotePathNameError.TooDeep),
            (string.Join('/', Enumerable.Repeat(new string ('x', 120), 8)), NotePathNameError.TooLong)
        };
        foreach (var (name, kind) in invalid)
        {
            var note = new TypedNote("# " + name + "\nBody", CheckVault.Now, CheckVault.Zone, e.Vault.NamingRules);
            Assert.Null(note.PathName);
            Assert.Equal(kind, note.PathNameError);
            Assert.Equal(kind, Assert.Throws<NotePathNameException>(() => e.Service.PrepareNote(CheckVault.Capture("# " + name + "\nBody", CaptureContentKind.Note), CheckVault.Zone)).Kind);
        }
    }

    [Fact]
    public void IndependentNotesReserveNamesAppendCollisionsAndReplayAfterEdits()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var pending = CheckVault.Capture("Reserved title", CaptureContentKind.Note);
        var first = e.Service.PrepareNote(pending, CheckVault.Zone);
        var next = e.Service.PrepareNote(pending with { Id = Guid.NewGuid() }, CheckVault.Zone);
        Assert.Equal("Reserved title.md", Path.GetFileName(first.Destination.Url));
        Assert.Equal("Reserved title 2.md", Path.GetFileName(next.Destination.Url));
        var original = CheckVault.Capture("# rootnoteneedle\n\nBody **untouched**", CaptureContentKind.Note);
        var prepared = e.Service.PrepareNote(original, CheckVault.Zone);
        Assert.True(prepared.CreatesNote);
        Assert.Equal("rootnoteneedle.md", Path.GetFileName(prepared.Destination.Url));
        e.Service.Save(prepared);
        var before = CheckVault.Read(prepared.Destination.Url);
        Assert.StartsWith("# rootnoteneedle\n\n<!-- note:", before, StringComparison.Ordinal);
        Assert.DoesNotContain("\n# rootnoteneedle\n", before, StringComparison.Ordinal);
        Assert.Contains("Body **untouched**", before, StringComparison.Ordinal);
        var json = JsonSerializer.Serialize(prepared);
        var journaled = JsonSerializer.Deserialize<PreparedCapture>(json)!;
        e.Service.Save(journaled);
        Assert.Equal(before, CheckVault.Read(prepared.Destination.Url));
        Assert.False(File.Exists(e.Vault.UrlForRelativePath("rootnoteneedle 2.md")));
        var collision = e.Service.PrepareNote(original with { Id = Guid.NewGuid() }, CheckVault.Zone);
        e.Service.Save(collision);
        var collided = CheckVault.Read(prepared.Destination.Url);
        Assert.Equal(prepared.Destination.Url, collision.Destination.Url);
        Assert.NotEqual(true, collision.CreatesNote);
        Assert.True(collision.NoteMarkerIsIdentity);
        Assert.Equal(1, Count(collided, "<!-- note:" + collision.Capture.Id));
        e.Service.Save(JsonSerializer.Deserialize<PreparedCapture>(JsonSerializer.Serialize(collision))!);
        Assert.Equal(collided, CheckVault.Read(prepared.Destination.Url));
        var legacy = JsonSerializer.Deserialize<PreparedCapture>(json.Replace(",\"noteMarkerIsIdentity\":true", "", StringComparison.Ordinal))!;
        Assert.True(legacy.CreatesNote);
        Assert.Null(legacy.NoteMarkerIsIdentity);
        var nested = e.Service.PrepareNote(CheckVault.Capture("# science/math/trigonometry\n\nNested typed body", CaptureContentKind.Note), CheckVault.Zone);
        Assert.Equal("science/math/trigonometry.md", e.Vault.NoteId(nested.Destination.Url));
        Assert.Equal("trigonometry", nested.Destination.Title);
        e.Service.Save(nested);
        Assert.StartsWith("# trigonometry\n", CheckVault.Read(nested.Destination.Url), StringComparison.Ordinal);
        Assert.DoesNotContain("\n# science/math/trigonometry\n", CheckVault.Read(nested.Destination.Url), StringComparison.Ordinal);
        var edited = collided.Replace("Body **untouched**", "Edited body", StringComparison.Ordinal);
        CheckVault.WriteAbsolute(prepared.Destination.Url, edited);
        e.Service.Save(journaled);
        Assert.Equal(edited, CheckVault.Read(prepared.Destination.Url));
        var titleOnly = e.Service.PrepareNote(CheckVault.Capture("# titleonlyneedle", CaptureContentKind.Note), CheckVault.Zone);
        e.Service.Save(titleOnly);
        var block = Assert.Single(NoteParser.Parse(CheckVault.Read(titleOnly.Destination.Url), "titleonlyneedle.md", "", CheckVault.Zone).Blocks);
        Assert.Equal(BlockKind.Note, block.Kind);
        Assert.Empty(block.Body);
        e.Sessions.Start("Typed session");
        var inSession = e.Service.PrepareNote(original, CheckVault.Zone);
        Assert.Equal(NoteKind.Session, inSession.Destination.Kind);
        Assert.Equal(original.Content, inSession.Capture.Content);
        Assert.NotEqual(true, inSession.CreatesNote);
        var explicitTarget = new Destination(e.Vault.InboxUrl, "Inbox", NoteKind.Inbox);
        Assert.Equal(explicitTarget, e.Service.PrepareNote(original, CheckVault.Zone, explicitTarget).Destination);
    }

    private static int Count(string text, string part) => text.Split(part, StringSplitOptions.None).Length - 1;
}
