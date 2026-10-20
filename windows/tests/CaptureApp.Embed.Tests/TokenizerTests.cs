using System.Text.Json;
using Xunit;

namespace CaptureApp.Embed.Tests;

public sealed class TokenizerTests
{
    private sealed record Case(string Text, long[] Ids);

    [Fact]
    public void ReproducesTheReferenceTokenizerFixtureExactly()
    {
        var models = Models.Require();
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Repo.Fixtures, "tokenizer.json")));
        var cases = document.RootElement.GetProperty("cases").EnumerateArray()
            .Select(item => new Case(item.GetProperty("text").GetString()!, item.GetProperty("ids").EnumerateArray().Select(id => id.GetInt64()).ToArray()))
            .ToList();
        Assert.NotEmpty(cases);

        var tokenizer = new Tokenizer(Path.Combine(models, "tokenizer.json"));
        for (var i = 0; i < cases.Count; i++)
        {
            var ids = tokenizer.Encode(cases[i].Text);
            Assert.True(cases[i].Ids.SequenceEqual(ids), $"case {i + 1} ({cases[i].Text.Length} chars): expected {cases[i].Ids.Length} ids, got {ids.Length}");
        }
    }

    [Fact]
    public void TruncationKeepsBothTemplateTokens()
    {
        var tokenizer = new Tokenizer(Path.Combine(Models.Require(), "tokenizer.json"));
        var ids = tokenizer.Encode(string.Join(' ', Enumerable.Repeat("hello", 500)), maxLength: 10);
        Assert.Equal(10, ids.Length);
        Assert.Equal((2L, 1L), (ids[0], ids[^1]));
        Assert.Throws<EmbeddingException>(() => tokenizer.Encode("x", maxLength: 1));
    }

    [Fact]
    public void RejectsAnUnsupportedTokenizerConfiguration()
    {
        using var temp = new TempDirectory();
        var path = Path.Combine(temp.Path, "tokenizer.json");
        File.WriteAllText(path, """{"model":{"type":"WordPiece"}}""");
        var error = Assert.Throws<EmbeddingException>(() => new Tokenizer(path));
        Assert.Equal(EmbeddingErrorKind.Invalid, error.Kind);
    }
}
