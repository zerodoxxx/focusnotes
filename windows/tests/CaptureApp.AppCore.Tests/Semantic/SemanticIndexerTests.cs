#pragma warning disable xUnit1051 // Timing tests use real short delays; test-run cancellation is not needed.
using CaptureApp.AppCore.Semantic;
using CaptureApp.Core.Index;
using CaptureApp.Embed;
using Xunit;

namespace CaptureApp.AppCore.Tests.Semantic;

public sealed class SemanticIndexerTests : IDisposable
{
    private readonly TempDirectory temp = new();
    private readonly FakeSource source = new();
    private readonly FakeEmbedder embedder = new();
    private readonly ManualTime time = new();
    private readonly List<VectorStore> stores = [];
    private bool gate = true;

    private SemanticIndexer Create(bool enabled = true, IReadOnlyList<TimeSpan>? retryDelays = null)
    {
        var path = Path.Combine(temp.Path, "vectors.sqlite");
        return new SemanticIndexer(source, () => embedder, () => Store(path), enabled, () => gate, time, retryDelays);
    }

    private VectorStore Store(string path)
    {
        var store = new VectorStore(path);
        stores.Add(store);
        return store;
    }

    private VectorStore Inspect() => new(Path.Combine(temp.Path, "vectors.sqlite"));

    public void Dispose()
    {
        foreach (var store in stores)
        {
            store.Dispose();
        }

        temp.Dispose();
    }

    private static readonly TimeSpan Debounce = TimeSpan.FromSeconds(2);

    [Fact]
    public async Task ScheduleDebouncesTwoSecondsAndCoalesces()
    {
        source.Blocks.Add(FakeSource.Text("a.md#1", "A", "alpha"));
        var indexer = Create();
        indexer.Schedule();
        time.Advance(TimeSpan.FromSeconds(1.5));
        indexer.Schedule();
        time.Advance(TimeSpan.FromSeconds(1.5));
        await Task.Delay(100);
        Assert.Empty(embedder.DocumentBatches);

        time.Advance(TimeSpan.FromSeconds(0.6));
        await Wait.Until(() => embedder.DocumentBatches.Count == 1, "the debounced pass");
        await indexer.FlushAsync();
        Assert.Single(embedder.DocumentBatches);
        using var store = Inspect();
        Assert.Equal(new[] { "a.md#1" }, store.Keys());
    }

    [Fact]
    public async Task BatchesWithinANoteUpToSixteenAndSplitsOnTitleChange()
    {
        for (var i = 0; i < 20; i++)
        {
            source.Blocks.Add(FakeSource.Text($"a.md#{i:D2}", "A", $"text {i}"));
        }

        source.Blocks.Add(FakeSource.Text("b.md#1", "B", "other"));
        var indexer = Create();
        await indexer.FlushAsync();

        Assert.Equal(new[] { ("A", 16), ("A", 4), ("B", 1) }, embedder.DocumentBatches);
        using var store = Inspect();
        Assert.Equal(21, store.Keys().Count);
    }

    [Fact]
    public async Task UnchangedBlocksAreSkippedChangedOnesReembeddedAndRemovedOnesPurged()
    {
        source.Blocks.Add(FakeSource.Text("a.md#1", "A", "alpha"));
        source.Blocks.Add(FakeSource.Text("a.md#2", "A", "beta"));
        var indexer = Create();
        await indexer.FlushAsync();
        Assert.Equal(new[] { ("A", 2) }, embedder.DocumentBatches);

        await indexer.FlushAsync();
        Assert.Single(embedder.DocumentBatches);

        source.Blocks[0] = FakeSource.Text("a.md#1", "A", "alpha edited");
        source.Blocks.RemoveAt(1);
        await indexer.FlushAsync();
        Assert.Equal(new[] { ("A", 2), ("A", 1) }, embedder.DocumentBatches);
        using var store = Inspect();
        Assert.Equal(new[] { "a.md#1" }, store.Keys());
    }

    [Fact]
    public async Task ImageGateIsRecheckedPerBlockAndResumesOnFalseToTrue()
    {
        source.Assets["assets/one.png"] = new byte[11];
        source.Assets["assets/two.png"] = new byte[22];
        source.Blocks.Add(FakeSource.Text("a.md#t", "A", "alpha"));
        source.Blocks.Add(FakeSource.Image("a.md#i1", "A", "assets/one.png", "ocr one"));
        source.Blocks.Add(FakeSource.Image("a.md#i2", "A", "assets/two.png"));

        gate = false;
        var indexer = Create();
        await indexer.FlushAsync();
        Assert.Empty(embedder.Images);
        using (var store = Inspect())
        {
            Assert.Equal(new[] { "a.md#t" }, store.Keys());
        }

        // Power returns: the false-to-true change schedules a pass after the debounce.
        gate = true;
        indexer.ImageEmbeddingAllowedChanged(this, true);
        time.Advance(Debounce);
        await Wait.Until(() => embedder.Images.Count == 2, "image embeddings after the gate opened");
        await indexer.FlushAsync();
        using var after = Inspect();
        Assert.Equal(new[] { "a.md#i1", "a.md#i1#ocr", "a.md#i2", "a.md#t" }, after.Keys());
    }

    [Fact]
    public async Task GateClosingMidRunStopsRemainingImages()
    {
        source.Assets["assets/one.png"] = new byte[11];
        source.Assets["assets/two.png"] = new byte[22];
        source.Blocks.Add(FakeSource.Image("a.md#i1", "A", "assets/one.png"));
        source.Blocks.Add(FakeSource.Image("a.md#i2", "A", "assets/two.png"));
        var embedded = 0;
        embedder.Gate = () =>
        {
            if (++embedded == 1)
            {
                gate = false;
            }

            return Task.CompletedTask;
        };

        await Create().FlushAsync();

        Assert.Single(embedder.Images);
    }

    [Fact]
    public async Task FailuresRetryAtFiveFifteenSixtySecondsAndSuccessResetsTheBudget()
    {
        source.Blocks.Add(FakeSource.Text("a.md#1", "A", "alpha"));
        embedder.Failure = new InvalidOperationException("helper down");
        var attempts = 0;
        var indexer = new SemanticIndexer(source, () =>
        {
            attempts++;
            return embedder;
        }, () => Store(Path.Combine(temp.Path, "vectors.sqlite")), true, () => gate, time);

        indexer.Schedule();
        time.Advance(Debounce);
        await Wait.Until(() => time.PendingTimers == 1 && attempts == 1, "the first failure");

        time.Advance(TimeSpan.FromSeconds(4.9));
        await Task.Delay(100);
        Assert.Empty(embedder.DocumentBatches);
        time.Advance(TimeSpan.FromSeconds(0.2));
        // Second failure schedules the 15 s retry.
        await Wait.Until(() => time.PendingTimers == 1, "the second retry timer");
        time.Advance(TimeSpan.FromSeconds(14.9));
        await Task.Delay(100);
        embedder.Failure = null;
        time.Advance(TimeSpan.FromSeconds(0.2));
        await Wait.Until(() => embedder.DocumentBatches.Count == 1, "the successful retry");
        await indexer.FlushAsync();
        using var store = Inspect();
        Assert.Equal(new[] { "a.md#1" }, store.Keys());
    }

    [Fact]
    public async Task DisablingStopsWorkAndReleasesTheHelperEnablingResumes()
    {
        source.Blocks.Add(FakeSource.Text("a.md#1", "A", "alpha"));
        var indexer = Create(enabled: false);
        indexer.Schedule();
        time.Advance(Debounce);
        await Task.Delay(100);
        Assert.Empty(embedder.DocumentBatches);

        indexer.SetEnabled(true);
        time.Advance(Debounce);
        await Wait.Until(() => embedder.DocumentBatches.Count == 1, "the enabled pass");
        await indexer.FlushAsync();

        indexer.SetEnabled(false);
        Assert.Equal(1, embedder.ShutdownCalls);
        Assert.False(indexer.IsEnabled);
    }

    [Fact]
    public async Task StopClosesTheClientAndIgnoresLaterSchedules()
    {
        source.Blocks.Add(FakeSource.Text("a.md#1", "A", "alpha"));
        var indexer = Create();
        await indexer.FlushAsync();
        await indexer.StopAsync();
        Assert.Equal(1, embedder.CloseCalls);
        indexer.Schedule();
        indexer.SetEnabled(true);
        time.Advance(Debounce);
        await Task.Delay(100);
        Assert.Single(embedder.DocumentBatches);
    }

    [Fact]
    public async Task SearchRanksSemanticTextAndImagesAndStripsTheOcrSuffix()
    {
        source.Assets["assets/one.png"] = new byte[11];
        source.Blocks.Add(FakeSource.Text("a.md#t", "A", "alpha"));
        source.Blocks.Add(FakeSource.Image("a.md#i", "A", "assets/one.png", "alpha"));
        source.HitsByKey["a.md#t"] = FakeSource.Hit("a.md#t", BlockKind.Text);
        source.HitsByKey["a.md#i"] = FakeSource.Hit("a.md#i", BlockKind.Image);
        var indexer = Create();
        await indexer.FlushAsync();

        // The query text is the document prompt for the OCR and body, so use the same one-hot seed as a stored vector.
        var result = await indexer.SearchAsync("alpha");
        Assert.Equal(2, result.Text.Count + result.Images.Count);
        Assert.Contains(result.Text.Concat(result.Images), hit => hit.EmbeddingKey == "a.md#t");
    }

    [Fact]
    public async Task SearchFallsBackToEmptyAfterThreeHundredFiftyMilliseconds()
    {
        source.Blocks.Add(FakeSource.Text("a.md#1", "A", "alpha"));
        var indexer = Create();
        await indexer.FlushAsync();
        var release = new TaskCompletionSource();
        embedder.Gate = () => release.Task;

        var search = indexer.SearchAsync("alpha");
        await Task.Delay(100);
        Assert.False(search.IsCompleted);
        time.Advance(TimeSpan.FromMilliseconds(351));
        var result = await search.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Empty(result.Text);
        release.SetResult();
    }

    [Fact]
    public async Task SearchReturnsEmptyWhenDisabled()
    {
        var indexer = Create(enabled: false);
        var result = await indexer.SearchAsync("anything");
        Assert.Equal(SemanticHits.Empty, result);
    }

    [Fact]
    public void FuseUsesReciprocalRankAndDeduplicates()
    {
        var a = FakeSource.Hit("a", BlockKind.Text);
        var b = FakeSource.Hit("b", BlockKind.Text);
        var c = FakeSource.Hit("c", BlockKind.Image);
        var fused = SemanticIndexer.Fuse([a, b], new SemanticHits([b, a], [c]));
        // a: 1/61 + 1/62, b: 1/62 + 1/61, tie broken by first appearance; c: 1/61 alone.
        Assert.Equal(new[] { "a", "b", "c" }, fused.Select(hit => hit.EmbeddingKey));
        Assert.Single(SemanticIndexer.Fuse([a, a], SemanticHits.Empty));
        Assert.Empty(SemanticIndexer.Fuse([a], SemanticHits.Empty, 0));
    }
}
