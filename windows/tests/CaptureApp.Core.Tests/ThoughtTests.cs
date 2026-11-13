using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class ThoughtTests
{
    private static readonly Guid Id = Guid.Parse("a1b2c3d4-0000-4000-8000-00000000000f");
    private const string Marker = "<!-- capture:a1b2c3d4-0000-4000-8000-00000000000f at=2026-10-13T14:30:00+05:30 app=\"Safari\" -->";
    private const string Body = "# N\n\n### Safari\n" + Marker + "\n\nHello é  ";
    private const string Next = "### Next\n<!-- capture:00000000-0000-4000-8000-000000000002 at=2026-10-13T14:31:00+05:30 app=\"\" -->\n\nOther\n";
    private static string? Set(string? text, string contents, Guid? id = null) =>
        CaptureFormat.SettingThought(text, id ?? Id, contents, CheckVault.Now, CheckVault.Zone);

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void MarkerExamplesRemainCaptureText(bool fenced)
    {
        var example = "<!-- thought:" + Id.ToString("D") + (fenced ? " at=old -->" : " is an example -->");
        var excerpt = "start\n" + (fenced ? "```\n" : "") + example + "\nrest" + (fenced ? "\n```" : "");
        var original = Marker + "\n\n" + excerpt + "\n";
        Assert.Equal(excerpt, Assert.Single(NoteParser.Parse(original, "N.md", "N", CheckVault.Zone).Blocks).Body);
        Assert.Equal(original, Set(null, Set("reflection", original)!));
    }

    [Fact]
    public void LegacyThoughtBackslashesRemainLiteral()
    {
        var original = Body + "\n\n<!-- thought:" + Id.ToString("D") + " at=old -->\n**My thought**\n\n\\# literal\n\\\\server\n";
        Assert.Equal("\\# literal\n\\\\server", Assert.Single(NoteParser.Parse(original, "N.md", "N", CheckVault.Zone).Blocks).Thought);
    }

    [Fact]
    public void RewriteDeniesExternalWritesUntilReplacement()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var path = e.Write("N.md", Body + "\n");
        var blocked = false;
        try
        {
            NoteFile.ReplaceHook.Value = (temporary, target) =>
            {
                try { using var writer = new FileStream(target, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete); }
                catch (IOException) { blocked = true; }
                File.Move(temporary, target, true);
            };
            e.Writer.SetThought("reflection", Id, path, CheckVault.Now);
        }
        finally { NoteFile.ReplaceHook.Value = null; }
        Assert.True(blocked);
        Assert.Contains("reflection", File.ReadAllText(path));
    }

    [Fact]
    public void StructuralMarkersInThoughtRoundTripWithoutPhantomCaptures()
    {
        var text = Marker + "\nreplacement\n" + Marker.Replace(Id.ToString("D"), "00000000-0000-4000-8000-000000000002", StringComparison.Ordinal)
            + "\nphantom\n<!-- note:" + Id.ToString("D") + " at=old -->\n\\<!-- capture:literal -->";
        var original = Body + "\n";
        var updated = Set(text, original)!;
        var block = Assert.Single(NoteParser.Parse(updated, "N.md", "N", CheckVault.Zone).Blocks);
        Assert.Equal("Hello é  ", block.Body);
        Assert.Equal(text, block.Thought);
        Assert.Equal(original, Set(null, updated));
    }

    [Fact]
    public void ExactBlockAndMiddleInsertionPreserveSuffixAndRoundTrip()
    {
        const string text = "  Reflect é\nnext \n\t";
        const string thought = "<!-- thought:a1b2c3d4-0000-4000-8000-00000000000f at=2026-10-13T14:30:00+05:30 -->\n**My thought**\n\n  Reflect é\nnext";
        Assert.Equal(thought + "\n", CaptureFormat.ThoughtBlock(Id, text, CheckVault.Now, CheckVault.Zone));
        var original = Body + "\n\n\n" + Next;
        var inserted = Body + "\n\n" + thought + "\n\n\n" + Next;
        Assert.Equal(inserted, Set(text, original));
        Assert.Equal(original, Set(null, inserted));
        Assert.Equal(original, Set(null, original));
    }

    [Fact]
    public void LastCaptureReplaceAndBlankRemovalKeepOneFinalNewline()
    {
        var original = Body + "\n";
        var inserted = Set("old", original)!;
        var replaced = Set("new", inserted)!;
        Assert.Equal(Set("new", original), replaced);
        Assert.EndsWith("new\n", replaced);
        Assert.False(replaced.EndsWith("\n\n", StringComparison.Ordinal));
        Assert.DoesNotContain("old", replaced);
        Assert.Equal(original, Set(" \n\t", replaced));
    }

    [Fact]
    public void FoundationWhitespaceIsBlankWhileThoughtBodyPreservesZeroWidthSpace()
    {
        var original = Body + "\n\u200b\n";
        Assert.Equal(original, Set("\u200b", original));
        var inserted = Set("reflect\u200b", original)!;
        Assert.Contains("reflect\u200b", inserted);
        Assert.Equal(original, Set("\u200b\n", inserted));
    }

    [Fact]
    public void MissingAndNoteIdentitiesAreRejectedAndDuplicateEditsOnlyLast()
    {
        Assert.Null(Set("thought", Body, Guid.NewGuid()));
        Assert.Null(Set("thought", Body.Replace("<!-- capture:", "<!-- note:", StringComparison.Ordinal)));
        var first = Body + "\n\n";
        var updated = Set("last", first + Marker + "\n\nsecond\n")!;
        Assert.StartsWith(first, updated);
        var block = Assert.Single(NoteParser.Parse(updated, "N.md", "N", CheckVault.Zone).Blocks);
        Assert.Equal("second", block.Body);
        Assert.Equal("last", block.Thought);
    }

    [Theory]
    [InlineData("hello", "reflect")]
    [InlineData("![](assets/a.png)", "reflect")]
    [InlineData("", "reflect")]
    public void ParserSplitsThoughtAndKeepsEmptyCapture(string body, string thought)
    {
        var contents = Marker + "\n\n" + body + "\n\n" + CaptureFormat.ThoughtBlock(Id, thought, CheckVault.Now, CheckVault.Zone);
        var block = Assert.Single(NoteParser.Parse(contents, "N.md", "N", CheckVault.Zone).Blocks);
        Assert.Equal(body, block.Body);
        Assert.Equal(thought, block.Thought);
        Assert.Equal(body.StartsWith("![](", StringComparison.Ordinal) ? BlockKind.Image : BlockKind.Text, block.Kind);
    }

    [Fact]
    public void WriterCallbacksMissingErrorsAndAppendAfterRewrite()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var path = e.Write("N.md", Body + "\n");
        var callbacks = new List<string>();
        var writer = new NoteWriter(e.Vault, CheckVault.Zone, beforeAppend: p => callbacks.Add("before:" + p),
            afterAppend: p => callbacks.Add("after:" + p));
        writer.SetThought("reflect", Id, path, CheckVault.Now);
        Assert.Equal(new[] { "before:" + path, "after:" + path }, callbacks);
        callbacks.Clear();
        writer.SetThought("reflect", Id, path, CheckVault.Now);
        Assert.Empty(callbacks);
        var before = File.ReadAllBytes(path);
        Assert.Equal(ThoughtWriteError.CaptureNotFound, Assert.Throws<ThoughtWriteException>(() => writer.SetThought("x", Guid.NewGuid(), path, CheckVault.Now)).Kind);
        Assert.Equal(before, File.ReadAllBytes(path));
        var missing = e.Vault.UrlForRelativePath("Missing.md");
        Assert.Throws<FileNotFoundException>(() => writer.SetThought("x", Id, missing, CheckVault.Now));
        Assert.False(File.Exists(missing));
        writer.SetThought(null, Id, path, CheckVault.Now);
        Assert.Equal(Body + "\n", CheckVault.Read(path));
        writer.Append(CheckVault.Capture(), path, "N");
        Assert.StartsWith(Body + "\n", CheckVault.Read(path));
    }

    [Fact]
    public void SearchFindsWordOnlyInThoughtAndDropsItAfterRemoval()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var path = e.Write("N.md", Body + "\n");
        e.Writer.SetThought("thoughtuniqueneedle", Id, path, CheckVault.Now);
        using var index = new SearchIndex(e.Vault, Path.Combine(e.Base, "search.sqlite"), CheckVault.Zone);
        index.Sync();
        Assert.Equal(Id, Assert.Single(index.Search("thoughtuniqueneedle")).CaptureID);
        e.Writer.SetThought(null, Id, path, CheckVault.Now);
        index.Sync();
        Assert.Empty(index.Search("thoughtuniqueneedle"));
    }
}
