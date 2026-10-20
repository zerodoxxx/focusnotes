using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class ParserTests
{
    private static readonly Guid Id = Guid.Parse("0B3C0000-0000-4000-8000-000000000001");
    [Fact]
    public void AllSourceContentDirectoryAndCrlfRoundTrips()
    {
        var sources = new (CaptureSource Source, string? App, string Window)[]
        {
            (new(), null, "Unknown source"),
            (new("  Safari\n Browser  "), "Safari Browser", "Safari Browser"),
            (new(" Safari · Beta ", "  Token\n bucket · Wikipedia  "), "Safari - Beta", "Token bucket - Wikipedia"),
            (new("Preview", new string ('x', 85)), "Preview", new string ('x', 80) + "…")
        };
        var contents = new[]
        {
            CaptureContent.Text("\n  \nFirst paragraph\n\nSecond paragraph with Café 😀  \n\n"),
            CaptureContent.Text("  \n\t"),
            CaptureContent.Text("a\r\nb\n### ordinary body heading\nnot a marker"),
            CaptureContent.Image("assets/my shot.png")
        };
        foreach (var path in new[]
        {
            "Root.md",
            "Sessions/Session.md"
        }

        )
            foreach (var source in sources)
                foreach (var content in contents)
                {
                    var capture = new Capture(Id, CheckVault.Now.AddSeconds(42), content, source.Source);
                    var written = CaptureFormat.Block(capture, path.StartsWith("Sessions/", StringComparison.Ordinal) ? "Sessions" : "", CheckVault.Zone);
                    var markdown = "#   Parsed\t title  \n\n" + written;
                    var parsed = NoteParser.Parse(markdown, path, "Fallback", CheckVault.Zone);
                    Assert.Equal("Parsed title", parsed.Title);
                    var block = Assert.Single(parsed.Blocks);
                    Assert.Equal(Id, block.CaptureId);
                    Assert.Equal(capture.CreatedAt, block.CreatedAt);
                    Assert.Equal(source.App, block.SourceApp);
                    Assert.Equal(source.Window, block.WindowTitle);
                    Assert.Equal(written[(written.IndexOf("\n\n", StringComparison.Ordinal) + 2)..^1], block.Body);
                    Assert.Equal(content.Kind == CaptureContentKind.Image ? BlockKind.Image : BlockKind.Text, block.Kind);
                    Assert.Equal(content.Kind == CaptureContentKind.Image ? "assets/my shot.png" : null, block.AssetPath);
                    var crlf = NoteParser.Parse(markdown.Replace("\n", "\r\n", StringComparison.Ordinal), path, "Fallback", CheckVault.Zone);
                    Assert.Equal(parsed.Title, crlf.Title);
                    Assert.Equal(parsed.Blocks, crlf.Blocks);
                }
    }

    [Fact]
    public void LooseBlocksTitlesBOMChunkingAndMalformedBoundaries()
    {
        var first = new Capture(Id, CheckVault.Now, CaptureContent.Text("first body"), new());
        var second = first with
        {
            Id = Guid.NewGuid(),
            CreatedAt = CheckVault.Now.AddMinutes(1),
            Content = CaptureContent.Text("second body")
        };
        var markdown = "# Mixed\n\nLoose introduction\n### ordinary heading\nstill loose\n\nAnother loose paragraph\n\n" + CaptureFormat.Block(first, "", CheckVault.Zone) + "\nUser text between captures\n### another ordinary heading\n\n" + CaptureFormat.Block(second, "", CheckVault.Zone);
        var mixed = NoteParser.Parse(markdown, "Mixed.md", "Fallback", CheckVault.Zone);
        Assert.Equal(4, mixed.Blocks.Count);
        Assert.Equal(BlockKind.Loose, mixed.Blocks[0].Kind);
        Assert.Null(mixed.Blocks[0].CaptureId);
        Assert.Null(mixed.Blocks[0].CreatedAt);
        Assert.Contains("### ordinary heading", mixed.Blocks[0].Body, StringComparison.Ordinal);
        Assert.Equal("first body\n\nUser text between captures\n### another ordinary heading", mixed.Blocks[2].Body);
        Assert.Equal("second body", mixed.Blocks[3].Body);
        var longText = new string('é', 5000);
        var chunked = NoteParser.Parse("# Long\n\n" + longText + "\n\nShort paragraph", "Long.md", "Fallback", CheckVault.Zone);
        Assert.Equal(new[] { 2000, 2000, 1000, 15 }, chunked.Blocks.Select(b => NoteTitle.Graphemes(b.Body).Count));
        Assert.Equal(longText, string.Concat(chunked.Blocks.Take(3).Select(b => b.Body)));
        var fallback = NoteParser.Parse("No leading title\n\nparagraph", "Fallback.md", "Fallback", CheckVault.Zone);
        Assert.Equal("Fallback", fallback.Title);
        Assert.Equal("No leading title", fallback.Blocks[0].Body);
        Assert.Equal("Stem", NoteParser.Parse("\uFEFF# \t \n\nbody", "Stem.md", "Stem", CheckVault.Zone).Title);
        var malformed = NoteParser.Parse($"# Malformed\n\n### 2026-02-30 10:04\n<!-- capture:{Id:D} -->\n\nBad date\n\n### 2026-10-13 10:04\n<!-- capture:not-a-uuid -->\n\nBad marker", "Malformed.md", "Fallback", CheckVault.Zone);
        Assert.All(malformed.Blocks, b => Assert.Equal(BlockKind.Loose, b.Kind));
    }

    [Fact]
    public void LegacyAndCurrentMarkersInheritanceEscapingAndFences()
    {
        var legacy = $"### 2026-10-13 14:30 · Safari · Page\n<!-- capture:{Id:D} -->\n\nlegacy body\n";
        var next = new Capture(Guid.NewGuid(), CheckVault.Now.AddSeconds(42), CaptureContent.Text("new body"), new("Safari", "Page"));
        var repeat = next with
        {
            Id = Guid.NewGuid(),
            CreatedAt = CheckVault.Now.AddSeconds(43),
            Content = CaptureContent.Text("repeat body")
        };
        var markdown = "# Formats\n\n" + legacy + "\n" + CaptureFormat.Block(next, "", CheckVault.Zone) + "\n" + CaptureFormat.Block(repeat, "", CheckVault.Zone, false);
        var both = NoteParser.Parse(markdown, "Formats.md", "", CheckVault.Zone);
        Assert.Equal(new[] { "legacy body", "new body", "repeat body" }, both.Blocks.Select(b => b.Body));
        Assert.All(both.Blocks, b =>
        {
            Assert.Equal("Page", b.WindowTitle);
            Assert.Equal("Safari", b.SourceApp);
        });
        Assert.Equal(next.CreatedAt, both.Blocks[1].CreatedAt);
        Assert.Equal(repeat.CreatedAt, both.Blocks[2].CreatedAt);
        Assert.Equal("Page", NoteParser.Parse(legacy + "\n" + CaptureFormat.Block(next, "", CheckVault.Zone, false), "Formats.md", "", CheckVault.Zone).Blocks[1].WindowTitle);
        var fake = "\n````markdown\n### Fake\n" + CaptureFormat.Block(repeat, "", CheckVault.Zone) + "```\n````\n";
        var fenced = NoteParser.Parse(markdown + fake, "Formats.md", "", CheckVault.Zone);
        Assert.Equal(3, fenced.Blocks.Count);
        Assert.Equal("Page", fenced.Blocks[^1].WindowTitle);
        var parts = NoteParser.Parse($"### 2026-10-13 14:30 · Safari · One · Two\n<!-- capture:{Id:D} -->\n\nbody", "P.md", "", CheckVault.Zone).Blocks[0];
        Assert.Equal("Safari", parts.SourceApp);
        Assert.Equal("One · Two", parts.WindowTitle);
        var windowOnly = NoteParser.Parse(CaptureFormat.Block(next with { Source = new(WindowTitle: "Window only") }, "", CheckVault.Zone), "P.md", "", CheckVault.Zone).Blocks[0];
        Assert.Null(windowOnly.SourceApp);
        Assert.Equal("Window only", windowOnly.WindowTitle);
    }

    [Fact]
    public void RepeatedLegacyLocalTimeUsesFirstInstant()
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("America/New_York");
        var markdown = $"### 2026-11-01 01:30 · Browser\n<!-- capture:{Id:D} -->\n\nbody";
        var block = Assert.Single(NoteParser.Parse(markdown, "Note.md", "Note", zone).Blocks);
        Assert.Equal(DateTimeOffset.Parse("2026-11-01T05:30:00Z", System.Globalization.CultureInfo.InvariantCulture), block.CreatedAt);
    }

    [Fact]
    public void ImageContainmentForVaultAndExternalFiles()
    {
        using var e = new CheckVault();
        var note = Path.Combine(e.Home, "Desktop/typed note.md");
        var assets = e.Vault.AssetsUrl;
        var capture = new Capture(Id, CheckVault.Now, CaptureContent.Image("assets/shot one.png"), new());
        var block = CaptureFormat.Block(capture, "", CheckVault.Zone, assetPathPrefix: CaptureFormat.RelativePath(Path.GetDirectoryName(note)!, e.Vault.Root));
        var parsed = NoteParser.Parse(block, new Uri(note).AbsoluteUri, "typed note", CheckVault.Zone, assets);
        Assert.Equal(BlockKind.Image, Assert.Single(parsed.Blocks).Kind);
        Assert.Equal("assets/shot one.png", parsed.Blocks[0].AssetPath);
        foreach (var (path, link, assetRoot) in new[]
        {
            (new Uri(note).AbsoluteUri, "../outside.png", assets),
            (new Uri(note).AbsoluteUri, "%2E%2E/%2E%2E/outside.png", assets),
            ("Root.md", "../../outside.png", (string? )null),
            ("Nested/Root.md", "../../assets/shot.png", (string? )null)
        }

        )
        {
            var markdown = $"### 2026-10-13 14:30\n<!-- capture:{Id:D} -->\n\n![]({link})";
            var value = Assert.Single(NoteParser.Parse(markdown, path, "", CheckVault.Zone, assetRoot).Blocks);
            Assert.Equal(BlockKind.Text, value.Kind);
            Assert.Null(value.AssetPath);
        }
    }
}
