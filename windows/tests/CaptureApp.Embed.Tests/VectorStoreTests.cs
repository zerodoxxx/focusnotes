using Xunit;

namespace CaptureApp.Embed.Tests;

public sealed class VectorStoreTests
{
    private static float[] Basis(int index, int dimensions = 256)
    {
        var vector = new float[dimensions];
        vector[index] = 1;
        return vector;
    }

    [Fact]
    public void NearestRanksByCosineWithStableTieOrderAndPersists()
    {
        using var temp = new TempDirectory();
        var path = Path.Combine(temp.Path, "state", "vectors.sqlite");
        using (var store = new VectorStore(path))
        {
            store.Upsert("b", Basis(1));
            store.Upsert("a", Basis(1));
            store.Upsert("far", Basis(2));
            var near = Basis(1);
            near[2] = 0.1f;
            var hits = store.Nearest(near, 3);
            Assert.Equal(new[] { "a", "b", "far" }, hits.Select(hit => hit.Key));
            Assert.Equal(0.995f, hits[0].Score, 1e-3f);
            Assert.Equal(hits[0].Score, hits[1].Score);
            Assert.Empty(store.Nearest(near, 0));
            Assert.Throws<EmbeddingException>(() => store.Nearest([1f], 1));
        }

        using var reopened = new VectorStore(path);
        Assert.Equal(new[] { "a", "b", "far" }, reopened.Keys());
        Assert.Equal("a", reopened.Nearest(Basis(1), 1).Single().Key);
    }

    [Fact]
    public void WritesFromAnotherConnectionInvalidateTheCache()
    {
        using var temp = new TempDirectory();
        var path = Path.Combine(temp.Path, "vectors.sqlite");
        using var first = new VectorStore(path);
        using var second = new VectorStore(path);
        first.Upsert("one", Basis(0));
        Assert.Equal(new[] { "one" }, second.Keys());
        first.Upsert("two", Basis(1));
        Assert.Equal(new[] { "one", "two" }, second.Keys());
        first.Remove(["one", "absent"]);
        Assert.Equal(new[] { "two" }, second.Keys());
        first.Upsert("two", Basis(3));
        Assert.Equal("two", first.Nearest(Basis(3), 1).Single().Key);
    }

    [Fact]
    public void FingerprintsRoundTripAndOmitMissingOnes()
    {
        using var temp = new TempDirectory();
        using var store = new VectorStore(Path.Combine(temp.Path, "vectors.sqlite"));
        store.Upsert("with", Basis(0), "fp-1");
        store.Upsert("without", Basis(1));
        Assert.Equal(new Dictionary<string, string> { ["with"] = "fp-1" }, store.Fingerprints());
        store.Upsert("with", Basis(0), "fp-2");
        Assert.Equal("fp-2", store.Fingerprints()["with"]);
        Assert.Throws<EmbeddingException>(() => store.Upsert("", Basis(0)));
        Assert.Throws<EmbeddingException>(() => store.Upsert("k", Basis(0, 128)));
    }

    [Fact]
    public void StoresAreIsolatedByModelAndDimensions()
    {
        using var temp = new TempDirectory();
        var path = Path.Combine(temp.Path, "vectors.sqlite");
        using (var store = new VectorStore(path))
        {
            store.Upsert("k", Basis(0));
        }

        using (var other = new VectorStore(path, "different-model"))
        {
            Assert.Empty(other.Keys());
        }

        using var again = new VectorStore(path, dimensions: 128);
        Assert.Empty(again.Keys());
    }

    [Fact]
    public void ChangedModelFileSizesClearVectorsButUnchangedOnesKeepThem()
    {
        using var temp = new TempDirectory();
        string[] ModelFiles(string name, int extra)
        {
            var directory = Path.Combine(temp.Path, name);
            Directory.CreateDirectory(directory);
            var files = new[] { "text.onnx", "text.onnx_data", "vision.onnx", "vision.onnx_data" }.Select(file => Path.Combine(directory, file)).ToArray();
            for (var i = 0; i < files.Length; i++)
            {
                File.WriteAllBytes(files[i], new byte[10 + i + extra]);
            }

            return files;
        }

        var path = Path.Combine(temp.Path, "identity.sqlite");
        using (var a = new VectorStore(path, modelFiles: ModelFiles("a", 0)))
        {
            a.Upsert("v", Basis(0));
        }

        using (var b = new VectorStore(path, modelFiles: ModelFiles("b", 5)))
        {
            Assert.Empty(b.Keys());
            b.Upsert("v", Basis(0));
        }

        using (var stable = new VectorStore(path, modelFiles: ModelFiles("b", 5)))
        {
            Assert.Equal(new[] { "v" }, stable.Keys());
        }

        // Omitting the files retains the stored stamp.
        using var unstamped = new VectorStore(path);
        Assert.Equal(new[] { "v" }, unstamped.Keys());
    }

    [Fact]
    public void CancelledSearchThrows()
    {
        using var temp = new TempDirectory();
        using var store = new VectorStore(Path.Combine(temp.Path, "vectors.sqlite"));
        store.Upsert("k", Basis(0));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => store.Nearest(Basis(0), 1, cancelled.Token));
    }
}
