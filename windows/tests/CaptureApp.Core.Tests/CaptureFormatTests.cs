using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class CaptureFormatTests
{
    private static readonly Guid Id = Guid.Parse("A1B2C3D4-0000-4000-8000-00000000000F");
    private static string Marker(string app = "") => $"<!-- capture:{Id:D} at=2026-10-13T14:30:00+05:30 app=\"{app}\" -->";
    private static string Block(CaptureContent content, CaptureSource? source = null, string dir = "") => CaptureFormat.Block(new(Id, CheckVault.Now, content, source ?? new()), dir, CheckVault.Zone);
    [Fact]
    public void ExactFormatCasesFromSwift()
    {
        var cases = new (string Actual, string Expected)[]
        {
            (Block(CaptureContent.Text("Hello\nworld"), new("Safari", "Docs — Safari")), $"### Docs\n{Marker("Safari")}\n\nHello\nworld\n"),
            (Block(CaptureContent.Text("Hello"), new("Safari")), $"### Safari\n{Marker("Safari")}\n\nHello\n"),
            (Block(CaptureContent.Text("Hello")), $"### Unknown source\n{Marker()}\n\nHello\n"),
            (Block(CaptureContent.Text("Hello"), new(WindowTitle: "Plan · draft\nline two " + new string ('x', 85))), $"### Plan - draft line two {new string ('x', 58)}…\n{Marker()}\n\nHello\n"),
            (Block(CaptureContent.Image("assets/shot.png")), $"### Unknown source\n{Marker()}\n\n![](assets/shot.png)\n"),
            (Block(CaptureContent.Image("assets/my shot.png"), dir: "Sessions"), $"### Unknown source\n{Marker()}\n\n![](../assets/my%20shot.png)\n"),
            (Block(CaptureContent.Text("\n  \nFirst\n\nSecond  \n\t\n")), $"### Unknown source\n{Marker()}\n\nFirst\n\nSecond\n"),
            (Block(CaptureContent.Text(" \n\t")), $"### Unknown source\n{Marker()}\n\n(empty)\n"),
            (Block(CaptureContent.Text("one\r\ntwo\r\n")), $"### Unknown source\n{Marker()}\n\none\ntwo\n")
        };
        foreach (var (actual, expected) in cases)
        {
            Assert.Equal(expected, actual);
        }

        foreach (var suffix in new[]
        {
            " — Mozilla Firefox",
            " - Google Chrome",
            " - Brave",
            " — Safari"
        }

        )
        {
            Assert.Equal("Page", CaptureFormat.SourceHeading(new(WindowTitle: "Page" + suffix)));
        }

        var capture = new Capture(Id, CheckVault.Now, CaptureContent.Image("assets/shot.png"), new());
        Assert.Contains("![](../../My%20Vault/assets/shot.png)", CaptureFormat.Block(capture, "Deep/Folder", CheckVault.Zone, assetPathPrefix: "../../My Vault"), StringComparison.Ordinal);
        const string app = "A \"quoted\" -- app --> &quot;";
        var escaped = Block(CaptureContent.Text("Hello"), new(app));
        Assert.Equal(Marker("A &quot;quoted&quot; &#45;&#45; app &#45;&#45;&gt; &amp;quot;"), escaped.Split('\n')[1]);
        Assert.DoesNotContain("--", escaped.Split('\n')[1][4..^3], StringComparison.Ordinal);
        Assert.Equal(app, NoteParser.Parse(escaped, "N.md", "N", CheckVault.Zone).Blocks[0].SourceApp);
        Assert.Equal("Plan next", CaptureFormat.CleanSubheading("  ###  Plan\n next  "));
        Assert.Equal("# Plan\n", CaptureFormat.NoteHeader("Plan"));
    }
}
