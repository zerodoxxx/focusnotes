using System.Text;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class NoteTitleTests
{
    private static readonly VaultNamingRules Mac = new()
    {
        WindowsRules = false
    };
    [Fact]
    public void WhitespaceCaseAccentsAndDistinctTitles()
    {
        Assert.Equal("Rate Limiting", NoteTitle.CleanTitle("  Rate   Limiting \n"));
        Assert.Equal(NoteTitle.MatchKey("rate limiting"), NoteTitle.MatchKey("  Rate   Limiting "));
        Assert.Equal(NoteTitle.MatchKey("cafe"), NoteTitle.MatchKey("Café"));
        Assert.Equal(NoteTitle.MatchKey("CAFE"), NoteTitle.MatchKey("Cafe\u0301"));
        Assert.NotEqual(NoteTitle.MatchKey("Foo"), NoteTitle.MatchKey("Foo 2"));
        Assert.Equal("strasse", NoteTitle.MatchKey("Straße"));
        Assert.Equal("σ", NoteTitle.MatchKey("ς"));
        Assert.Equal("ff", NoteTitle.MatchKey("ﬀ"));
        Assert.Equal("a", NoteTitle.MatchKey("Ａ"));
        Assert.Equal("①", NoteTitle.MatchKey("①"));
        Assert.Equal("²", NoteTitle.MatchKey("²"));
    }

    [Theory]
    [InlineData("a/b:c", "a-b-c")]
    [InlineData("a\\b", "a-b")]
    [InlineData("Plan\aX", "Plan-X")]
    [InlineData(".hidden", "hidden")]
    [InlineData("   ", "Untitled")]
    [InlineData("..", "Untitled")]
    public void FileStemReplacements(string raw, string expected) => Assert.Equal(expected, NoteTitle.FileStem(raw));
    [Fact]
    public void PathsAndDisplayTitle()
    {
        var relative = NoteTitle.PathName(" science / math / trigonometry ", Mac);
        Assert.Equal(NotePathScope.Vault, relative.Scope);
        Assert.Equal(["science", "math", "trigonometry"], relative.Components);
        Assert.Equal("trigonometry", relative.DisplayTitle);
        var home = NoteTitle.PathName("/Desktop/science/math/trigonometry", Mac);
        Assert.Equal(NotePathScope.Home, home.Scope);
        Assert.Equal("Desktop/science/math/trigonometry", home.RelativePath);
        Assert.Equal(["science", "math-trig"], NoteTitle.PathName("science/math:trig", Mac).Components);
        Assert.EndsWith("…", NoteTitle.PathName("folder/" + string.Concat(Enumerable.Repeat("word ", 15)), Mac).DisplayTitle, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("")]
    [InlineData("/")]
    [InlineData("science/")]
    [InlineData("science//math")]
    [InlineData("./math")]
    [InlineData("science/../math")]
    [InlineData("math\0x")]
    [InlineData("science/~$draft")]
    public void UnsafePathsFail(string raw) => Assert.Throws<NotePathNameException>(() => NoteTitle.PathName(raw, Mac));
    [Fact]
    public void LimitsAndCombiningClusters()
    {
        Assert.Equal(120, NoteTitle.FileStem(new string('a', 200)).Length);
        Assert.Equal(NotePathNameError.TooDeep, Assert.Throws<NotePathNameException>(() => NoteTitle.PathName(string.Join('/', Enumerable.Repeat("x", 33)), Mac)).Kind);
        Assert.Equal(NotePathNameError.TooLong, Assert.Throws<NotePathNameException>(() => NoteTitle.PathName(string.Join('/', Enumerable.Repeat(new string('x', 120), 8)), Mac)).Kind);
        var accepted = "a" + new string('\u0301', 31);
        Assert.Equal(accepted, NoteTitle.FileStem(accepted));
        Assert.Equal("Untitled", NoteTitle.FileStem("a" + new string('\u0301', 32)));
        Assert.Equal("Untitled", NoteTitle.FileStem("a" + new string('\u0344', 16)));
        using var env = new CheckVault();
        env.Vault.Prepare();
        foreach (var title in new[]
        {
            string.Concat(Enumerable.Repeat("👨‍👩‍👧‍👦", 40)),
            "a" + new string ('\u0301', 500),
            accepted,
            "a" + new string ('\u0301', 32),
            "a" + new string ('\u0344', 16)
        }

        )
        {
            var stem = NoteTitle.FileStem(title);
            Assert.InRange(Encoding.UTF8.GetByteCount(stem), 1, 220);
            var first = env.Vault.UniqueNoteUrl(title);
            CheckVault.WriteAbsolute(first, "# Unicode\n");
            var second = env.Vault.UniqueNoteUrl(title);
            Assert.NotEqual(first, second);
            Assert.True(Encoding.UTF8.GetByteCount(Path.GetFileName(second)) <= 255);
            CheckVault.WriteAbsolute(second, "# Unicode 2\n");
        }
    }
}
