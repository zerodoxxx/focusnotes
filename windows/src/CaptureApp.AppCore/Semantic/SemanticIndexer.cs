using System.Runtime.ExceptionServices;
using CaptureApp.Core.Index;
using CaptureApp.Embed;

namespace CaptureApp.AppCore.Semantic;

/// Coordinates disposable vectors. Models and runtime stay in the embedding helper process.
/// Platform-neutral: the power gate, clock and embedding backends are all injected.
public sealed class SemanticIndexer
{
    public static readonly IReadOnlyList<TimeSpan> DefaultRetryDelays =
        [TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(300), TimeSpan.FromSeconds(900)];

    public static readonly TimeSpan Debounce = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan SearchDeadline = TimeSpan.FromMilliseconds(350);
    public const int BatchSize = 16;

    private readonly ISemanticSource source;
    private readonly Func<IEmbedService> clientFactory;
    private readonly Func<IVectorStore> storeFactory;
    private readonly Func<bool> imageEmbeddingAllowed;
    private readonly TimeProvider time;
    private readonly IReadOnlyList<TimeSpan> retryDelays;
    private readonly AppLog? log;
    private readonly object gate = new();
    private bool enabled;
    private bool stopped;
    private bool lastImageAllowed;
    private bool rerun;
    private int retryAttempt;
    private IEmbedService? client;
    private IVectorStore? store;
    private CancellationTokenSource? debounce;
    private CancellationTokenSource? retry;
    private CancellationTokenSource? jobCancellation;
    private Task? job;

    /// <param name="enabled">Whether the models are installed. Toggle later with <see cref="SetEnabled"/>.</param>
    /// <param name="imageEmbeddingAllowed">The power gate, re-checked before every image block.</param>
    public SemanticIndexer(ISemanticSource source, Func<IEmbedService> clientFactory, Func<IVectorStore> storeFactory, bool enabled,
        Func<bool>? imageEmbeddingAllowed = null, TimeProvider? timeProvider = null, IReadOnlyList<TimeSpan>? retryDelays = null, AppLog? log = null)
    {
        this.source = source;
        this.clientFactory = clientFactory;
        this.storeFactory = storeFactory;
        this.enabled = enabled;
        this.imageEmbeddingAllowed = imageEmbeddingAllowed ?? (() => true);
        time = timeProvider ?? TimeProvider.System;
        this.retryDelays = retryDelays is { Count: > 0 } ? retryDelays : DefaultRetryDelays;
        this.log = log;
        lastImageAllowed = this.imageEmbeddingAllowed();
    }

    public bool IsEnabled
    {
        get { lock (gate) return enabled && !stopped; }
    }

    public void SetEnabled(bool value)
    {
        IEmbedService? idle = null;
        lock (gate)
        {
            if (stopped || enabled == value)
            {
                return;
            }

            enabled = value;
            if (value)
            {
                Schedule();
                return;
            }

            CancelAndClear(ref debounce);
            CancelAndClear(ref retry);
            jobCancellation?.Cancel();
            rerun = false;
            retryAttempt = 0;
            // Release the embedding helper while disabled; resources recreate it on re-enable.
            idle = client;
            client = null;
        }

        if (idle is not null)
        {
            _ = idle.ShutdownAsync();
        }
    }

    /// Wire to PowerMonitor.ImageEmbeddingAllowedChanged: a false-to-true change resumes image embedding.
    public void ImageEmbeddingAllowedChanged(object? sender, bool allowed)
    {
        bool resume;
        lock (gate)
        {
            resume = allowed && !lastImageAllowed;
            lastImageAllowed = allowed;
        }

        if (resume)
        {
            Schedule();
        }
    }

    /// Replaces pending timers without cancelling an inference already warming the helper.
    public void Schedule()
    {
        CancellationToken token;
        lock (gate)
        {
            if (!enabled || stopped)
            {
                return;
            }

            // A real vault change should get an earlier attempt than a pending backoff.
            CancelAndClear(ref retry);
            CancelAndClear(ref debounce);
            debounce = new CancellationTokenSource();
            token = debounce.Token;
        }

        _ = RunAfterAsync(Debounce, token, () =>
        {
            lock (gate)
            {
                debounce = null;
            }

            StartJob();
        });
    }

    /// Permanently stops retries and in-flight work when the owning app accepts termination.
    public async Task StopAsync()
    {
        Task? active;
        IEmbedService? current;
        lock (gate)
        {
            if (stopped)
            {
                current = client;
                active = null;
            }
            else
            {
                stopped = true;
                enabled = false;
                CancelAndClear(ref debounce);
                CancelAndClear(ref retry);
                rerun = false;
                jobCancellation?.Cancel();
                active = job;
                current = client;
            }
        }

        // Warmup and search may have obtained the client before the stop; closing interrupts their on-wire waits.
        if (current is not null)
        {
            await current.CloseAsync().ConfigureAwait(false);
        }

        if (active is not null)
        {
            await active.ConfigureAwait(false);
        }
    }

    /// Runs one pass now and waits for it (self-tests); production never waits for backfill.
    public async Task FlushAsync()
    {
        lock (gate)
        {
            CancelAndClear(ref debounce);
        }

        await WaitForJobAsync().ConfigureAwait(false);
        StartJob();
        await WaitForJobAsync().ConfigureAwait(false);
    }

    public async Task WarmAsync()
    {
        if (!IsEnabled)
        {
            return;
        }

        try
        {
            await Resources().Client.PingAsync().ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            log?.Error($"Helper warmup failed: {error.Message}");
        }
    }

    public Task<SemanticHits> SearchAsync(string query, TimeSpan? timeout = null, CancellationToken cancellationToken = default) =>
        SemanticDeadline.RunAsync(timeout ?? SearchDeadline, SemanticHits.Empty, token => SearchWorkAsync(query, token), cancellationToken, time);

    /// Reciprocal-rank fusion of keyword, semantic text and semantic image lists.
    public static IReadOnlyList<SearchHit> Fuse(IReadOnlyList<SearchHit> keyword, SemanticHits semantic, int limit = 40)
    {
        var scores = new Dictionary<string, double>(StringComparer.Ordinal);
        var hits = new Dictionary<string, SearchHit>(StringComparer.Ordinal);
        var order = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var list in new[] { keyword, semantic.Text, semantic.Images })
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            for (var rank = 0; rank < list.Count; rank++)
            {
                var key = list[rank].EmbeddingKey;
                if (!seen.Add(key))
                {
                    continue;
                }

                scores[key] = scores.GetValueOrDefault(key) + 1.0 / (60 + rank + 1);
                if (hits.TryAdd(key, list[rank]))
                {
                    order[key] = order.Count;
                }
            }
        }

        return [.. scores.Keys.OrderByDescending(key => scores[key]).ThenBy(key => order[key]).Take(Math.Max(0, limit)).Select(key => hits[key])];
    }

    private async Task WaitForJobAsync()
    {
        while (true)
        {
            Task? active;
            lock (gate)
            {
                active = job;
            }

            if (active is null)
            {
                return;
            }

            await active.ConfigureAwait(false);
        }
    }

    private void StartJob()
    {
        lock (gate)
        {
            debounce = null;
            if (!enabled || stopped)
            {
                return;
            }

            CancelAndClear(ref retry);
            if (job is not null)
            {
                rerun = true;
                return;
            }

            jobCancellation = new CancellationTokenSource();
            var token = jobCancellation.Token;
            job = Task.Run(async () =>
            {
                var failed = false;
                try
                {
                    await ReconcileAsync(token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                }
                catch (Exception error) when (error is not OutOfMemoryException)
                {
                    if (!token.IsCancellationRequested)
                    {
                        log?.Error($"Embedding deferred: {error.Message}");
                        failed = true;
                    }
                }

                FinishedJob(failed);
            });
        }
    }

    private void FinishedJob(bool failed)
    {
        lock (gate)
        {
            job = null;
            if (stopped)
            {
                rerun = false;
                return;
            }

            // Changed-event reruns must not turn a persistent helper failure into a tight loop.
            if (failed)
            {
                rerun = false;
                ScheduleRetry();
                return;
            }

            // A successful pass, including one followed by a queued rerun, starts a fresh retry budget
            // if that rerun encounters a new failure.
            retryAttempt = 0;
            if (rerun)
            {
                rerun = false;
                StartJob();
            }
        }
    }

    private void ScheduleRetry()
    {
        CancellationToken token;
        TimeSpan delay;
        lock (gate)
        {
            if (!enabled || stopped)
            {
                return;
            }

            CancelAndClear(ref retry);
            delay = retryDelays[Math.Min(retryAttempt, retryDelays.Count - 1)];
            retryAttempt++;
            retry = new CancellationTokenSource();
            token = retry.Token;
        }

        _ = RunAfterAsync(delay, token, () =>
        {
            lock (gate)
            {
                retry = null;
                if (!enabled || stopped)
                {
                    return;
                }
            }

            StartJob();
        });
    }

    private async Task RunAfterAsync(TimeSpan delay, CancellationToken token, Action action)
    {
        try
        {
            await Task.Delay(delay, time, token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        if (!token.IsCancellationRequested)
        {
            action();
        }
    }

    private static void CancelAndClear(ref CancellationTokenSource? source)
    {
        source?.Cancel();
        source = null;
    }

    private (IEmbedService Client, IVectorStore Store) Resources()
    {
        lock (gate)
        {
            client ??= clientFactory();
            store ??= storeFactory();
            return (client, store);
        }
    }

    private (IEmbedService Client, IVectorStore Store)? ActiveResources(CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (!enabled || stopped || cancellationToken.IsCancellationRequested)
            {
                return null;
            }
        }

        return Resources();
    }

    private bool IsActive()
    {
        lock (gate)
        {
            return enabled && !stopped;
        }
    }

    private async Task ReconcileAsync(CancellationToken cancellationToken)
    {
        if (!IsActive())
        {
            return;
        }

        var blocks = source.EmbeddableBlocks();
        if (ActiveResources(cancellationToken) is not var (client, store))
        {
            return;
        }

        var existing = store.Keys().ToHashSet(StringComparer.Ordinal);
        var fingerprints = store.Fingerprints();
        var expected = new HashSet<string>(blocks.Select(block => block.Key), StringComparer.Ordinal);
        foreach (var block in blocks.Where(block => block.Kind == BlockKind.Image && block.OcrText.Trim().Length > 0))
        {
            expected.Add(block.Key + "#ocr");
        }

        store.Remove([.. existing.Except(expected)]);

        // Each request has one title, so batch within a note (at most 16).
        var batch = new List<PendingEmbedding>();
        async Task AddAsync(string key, string body, string title)
        {
            if (batch.Count > 0 && (batch[0].Title != title || batch.Count == BatchSize))
            {
                await EmbedBatchAsync(batch, client, store, cancellationToken).ConfigureAwait(false);
                batch.Clear();
            }

            batch.Add(new PendingEmbedding(key, body, title, EmbeddingFingerprint.Document(body, title)));
        }

        foreach (var block in blocks)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsActive())
            {
                return;
            }

            if (block.Kind == BlockKind.Image)
            {
                if (!imageEmbeddingAllowed())
                {
                    continue;
                }

                if (block.OcrText.Trim().Length > 0
                    && !IsCurrent(fingerprints, block.Key + "#ocr", EmbeddingFingerprint.Document(block.OcrText, block.NoteTitle)))
                {
                    await AddAsync(block.Key + "#ocr", block.OcrText, block.NoteTitle).ConfigureAwait(false);
                }
            }
            else if (!IsCurrent(fingerprints, block.Key, EmbeddingFingerprint.Document(block.Body, block.NoteTitle)))
            {
                await AddAsync(block.Key, block.Body, block.NoteTitle).ConfigureAwait(false);
            }
        }

        await EmbedBatchAsync(batch, client, store, cancellationToken).ConfigureAwait(false);

        Exception? deferredImageError = null;
        foreach (var block in blocks.Where(block => block.Kind == BlockKind.Image))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsActive() || !imageEmbeddingAllowed())
            {
                return;
            }

            if (block.AssetPath is not { } path)
            {
                continue;
            }

            try
            {
                var metadata = source.FileSnapshot(path, false) ?? throw new FileNotFoundException(path);
                var assetPath = Path.GetFullPath(source.UrlForRelativePath(path));
                if (IsCurrent(fingerprints, block.Key, EmbeddingFingerprint.Image(assetPath, metadata.Size, metadata.ModifiedAt)))
                {
                    continue;
                }

                var snapshot = source.FileSnapshot(path, true);
                var png = snapshot?.Contents ?? throw new FileNotFoundException(path);
                var snapshotFingerprint = EmbeddingFingerprint.Image(assetPath, snapshot.Size, snapshot.ModifiedAt);
                if (IsCurrent(fingerprints, block.Key, snapshotFingerprint))
                {
                    continue;
                }

                var vector = await client.EmbedImageAsync(png, cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                store.Upsert(block.Key, vector, snapshotFingerprint);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                cancellationToken.ThrowIfCancellationRequested();
                log?.Error($"Image embedding deferred for {block.Key}: {error.Message}");
                deferredImageError ??= error;
            }
        }

        if (deferredImageError is not null)
        {
            ExceptionDispatchInfo.Capture(deferredImageError).Throw();
        }
    }

    private static bool IsCurrent(IReadOnlyDictionary<string, string> fingerprints, string key, string fingerprint) =>
        fingerprints.TryGetValue(key, out var stored) && stored == fingerprint;

    private static async Task EmbedBatchAsync(List<PendingEmbedding> batch, IEmbedService client, IVectorStore store, CancellationToken cancellationToken)
    {
        if (batch.Count == 0)
        {
            return;
        }

        cancellationToken.ThrowIfCancellationRequested();
        var vectors = await client.EmbedDocumentsAsync([.. batch.Select(item => item.Body)], batch[0].Title, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        for (var i = 0; i < batch.Count; i++)
        {
            store.Upsert(batch[i].Key, vectors[i], batch[i].Fingerprint);
        }
    }

    private async Task<SemanticHits> SearchWorkAsync(string query, CancellationToken cancellationToken)
    {
        try
        {
            if (ActiveResources(cancellationToken) is not var (client, store))
            {
                return SemanticHits.Empty;
            }

            var vector = await client.EmbedLatestQueryAsync(query, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            var nearest = store.Nearest(vector, 40, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            var scores = new Dictionary<string, float>(StringComparer.Ordinal);
            foreach (var (key, score) in nearest)
            {
                var block = key.EndsWith("#ocr", StringComparison.Ordinal) ? key[..^4] : key;
                scores[block] = scores.TryGetValue(block, out var best) ? Math.Max(best, score) : score;
            }

            var ranked = scores.Keys.OrderByDescending(key => scores[key]).ThenBy(key => key, StringComparer.Ordinal).ToList();
            var hits = source.Hits(ranked);
            cancellationToken.ThrowIfCancellationRequested();
            var text = new List<SearchHit>();
            var images = new List<SearchHit>();
            foreach (var key in ranked)
            {
                if (!hits.TryGetValue(key, out var hit))
                {
                    continue;
                }

                (hit.BlockKind == BlockKind.Image ? images : text).Add(hit);
            }

            return new SemanticHits(text, images);
        }
        catch (OperationCanceledException)
        {
            return SemanticHits.Empty;
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            log?.Error($"Semantic query skipped: {error.Message}");
            return SemanticHits.Empty;
        }
    }

    private sealed record PendingEmbedding(string Key, string Body, string Title, string Fingerprint);
}
