using System.Globalization;
using System.Text.Json;
using Xunit;

namespace CaptureApp.Embed.Tests;

/// Parity against the reference vectors the Mac checks use (Sources/EmbedChecks/Fixtures/embeddings.json).
public sealed class EmbeddingParityTests
{
    private static float Cosine(float[] a, float[] b) => a.Zip(b, (x, y) => x * y).Sum() / (MathF.Sqrt(a.Sum(x => x * x)) * MathF.Sqrt(b.Sum(y => y * y)));

    private static float[] Vector(JsonElement element) => element.EnumerateArray().Select(value => value.GetSingle()).ToArray();

    private static void Report(string message) => TestContext.Current.TestOutputHelper?.WriteLine(message);

    [Fact]
    public void TextAndImageVectorsMatchTheReferenceAtOrAbove099()
    {
        var models = Models.Require();
        using var fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(Repo.Fixtures, "embeddings.json")));
        using var embedder = new Embedder(models);

        var minText = 1f;
        foreach (var item in fixture.RootElement.GetProperty("texts").EnumerateArray())
        {
            var title = item.GetProperty("title").GetString();
            var kind = item.GetProperty("kind").GetString() == "query" ? EmbeddingKind.Query : EmbeddingKind.Document(title);
            var vector = embedder.Embed([item.GetProperty("text").GetString()!], kind).Single();
            Assert.Equal(256, vector.Length);
            Assert.Equal(1f, MathF.Sqrt(vector.Sum(x => x * x)), 1e-4f);
            var score = Cosine(vector, Vector(item.GetProperty("vector")));
            minText = Math.Min(minText, score);
            Assert.True(score >= 0.99f, $"text cosine {score:F6}");
        }

        Assert.False(embedder.VisionLoaded);
        var image = fixture.RootElement.GetProperty("image");
        var png = File.ReadAllBytes(Path.Combine(Repo.Fixtures, image.GetProperty("file").GetString()!));
        var imageVector = embedder.Embed(png);
        var minImage = Cosine(imageVector, Vector(image.GetProperty("vector")));
        Assert.True(minImage >= 0.99f, $"image cosine {minImage:F6}");
        Assert.True(embedder.VisionLoaded);
        Report(string.Create(CultureInfo.InvariantCulture, $"PARITY min text cosine {minText:F6}; image cosine {minImage:F6}"));
    }

    [Fact]
    public async Task HelperProcessMatchesDirectInferenceAndRanksTheCorpus()
    {
        var models = Models.Require();
        using var embedder = new Embedder(models);
        await using var client = new EmbedClient(Helper.Path, models, idleSeconds: 30);
        const string query = "how do token buckets limit requests";
        var viaClient = await client.EmbedQueryAsync(query);
        Assert.True(Cosine(viaClient, embedder.Embed([query], EmbeddingKind.Query).Single()) > 0.9999f);
        Assert.False((await client.PingAsync()).VisionLoaded);

        var diagram = File.ReadAllBytes(Path.Combine(Repo.Fixtures, "token-bucket.png"));
        Assert.True(Cosine(await client.EmbedImageAsync(diagram), embedder.Embed(diagram)) > 0.9999f);
        Assert.True((await client.PingAsync()).VisionLoaded);

        var corpus = new (string Key, string Title, string Text)[]
        {
            ("token-bucket", "Token bucket", "Token buckets limit requests. Tokens refill at a fixed rate into a bucket with a maximum capacity. Each request consumes a token; reject or delay requests when no tokens remain."),
            ("rust-lifetimes", "Rust lifetimes", "Async Rust borrow problems arise when references cross await boundaries or async tasks outlive borrowed values."),
            ("sourdough", "Sourdough", "Bread fermentation with sourdough uses wild yeast and lactic acid bacteria. Feed the starter, ferment the dough, proof the loaf and bake."),
            ("kubernetes", "Kubernetes", "Kubernetes schedules container pods on a cluster. Deployments manage replicas and services route traffic."),
        };
        using var temp = new TempDirectory();
        using var store = new VectorStore(Path.Combine(temp.Path, "vectors.sqlite"));
        foreach (var (key, title, text) in corpus)
        {
            store.Upsert(key, (await client.EmbedDocumentsAsync([text], title)).Single());
        }

        foreach (var (search, expected) in new[] { (query, "token-bucket"), ("async rust borrow problems", "rust-lifetimes"), ("bread fermentation", "sourdough") })
        {
            Assert.Equal(expected, store.Nearest(await client.EmbedLatestQueryAsync(search), 1).Single().Key);
        }

        await Assert.ThrowsAsync<EmbeddingException>(() => client.EmbedImageAsync("not a png"u8.ToArray()));
        Assert.NotNull(client.ProcessId());
    }
}
