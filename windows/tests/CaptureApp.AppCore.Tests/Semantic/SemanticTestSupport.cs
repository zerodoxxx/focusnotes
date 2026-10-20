using CaptureApp.AppCore.Semantic;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using CaptureApp.Embed;

namespace CaptureApp.AppCore.Tests.Semantic;

/// A clock the test advances by hand; Task.Delay(TimeProvider) timers fire inside Advance.
internal sealed class ManualTime : TimeProvider
{
    private readonly object gate = new();
    private readonly List<ManualTimer> timers = [];
    private DateTimeOffset now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public override DateTimeOffset GetUtcNow()
    {
        lock (gate) return now;
    }

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ManualTimer(this, callback, state);
        timer.Change(dueTime, period);
        return timer;
    }

    public void Advance(TimeSpan amount)
    {
        DateTimeOffset target;
        lock (gate) target = now + amount;
        while (true)
        {
            ManualTimer? next;
            lock (gate)
            {
                next = timers.Where(t => t.Due <= target).OrderBy(t => t.Due).FirstOrDefault();
                if (next is null)
                {
                    now = target;
                    return;
                }

                now = next.Due > now ? next.Due : now;
                next.Fired();
            }

            next.Callback(next.State);
        }
    }

    public int PendingTimers
    {
        get { lock (gate) return timers.Count; }
    }

    private sealed class ManualTimer(ManualTime owner, TimerCallback callback, object? state) : ITimer
    {
        private TimeSpan period = Timeout.InfiniteTimeSpan;

        public DateTimeOffset Due { get; private set; } = DateTimeOffset.MaxValue;

        public TimerCallback Callback => callback;

        public object? State => state;

        public bool Change(TimeSpan dueTime, TimeSpan newPeriod)
        {
            lock (owner.gate)
            {
                owner.timers.Remove(this);
                period = newPeriod;
                if (dueTime != Timeout.InfiniteTimeSpan)
                {
                    Due = owner.now + dueTime;
                    owner.timers.Add(this);
                }
            }

            return true;
        }

        public void Fired()
        {
            owner.timers.Remove(this);
            if (period != Timeout.InfiniteTimeSpan && period > TimeSpan.Zero)
            {
                Due = owner.now + period;
                owner.timers.Add(this);
            }
        }

        public void Dispose()
        {
            lock (owner.gate) owner.timers.Remove(this);
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}

internal sealed class FakeSource : ISemanticSource
{
    public List<EmbeddableBlock> Blocks { get; } = [];

    public Dictionary<string, SearchHit> HitsByKey { get; } = [];

    public Dictionary<string, byte[]> Assets { get; } = [];

    public IReadOnlyList<EmbeddableBlock> EmbeddableBlocks()
    {
        lock (Blocks) return [.. Blocks];
    }

    public IReadOnlyDictionary<string, SearchHit> Hits(IEnumerable<string> keys) =>
        keys.Where(HitsByKey.ContainsKey).ToDictionary(key => key, key => HitsByKey[key]);

    public VaultFileSnapshot? FileSnapshot(string relativePath, bool includingContents) =>
        Assets.TryGetValue(relativePath, out var bytes) ? new VaultFileSnapshot(includingContents ? bytes : null, bytes.Length, 0, 0, 1_700_000_000, 0, 0, 0) : null;

    public string UrlForRelativePath(string relativePath) => Path.Combine(Path.GetTempPath(), "vault", relativePath);

    public static EmbeddableBlock Text(string key, string title, string body) => new(key, body, title, BlockKind.Text, null, "");

    public static EmbeddableBlock Image(string key, string title, string asset, string ocr = "") => new(key, "image", title, BlockKind.Image, asset, ocr);

    public static SearchHit Hit(string key, BlockKind kind) =>
        new(key, 1, "body", "n.md", "Note", NoteKind.Note, null, kind, null, null, null, null, "snippet", []);
}

/// One-hot vectors derived from the text, so equal texts match exactly and different ones do not.
internal sealed class FakeEmbedder : IEmbedService
{
    private readonly object gate = new();

    public int Dimensions => 256;

    public List<(string Title, int Count)> DocumentBatches { get; } = [];

    public List<int> Images { get; } = [];

    public Func<Task>? Gate { get; set; }

    public Exception? Failure { get; set; }

    public int ShutdownCalls { get; private set; }

    public int CloseCalls { get; private set; }

    public static float[] Vector(string text)
    {
        var vector = new float[256];
        vector[(int)(Fnv(text) % 256)] = 1;
        return vector;
    }

    private static uint Fnv(string text) => text.Aggregate(2166136261u, (hash, c) => (hash ^ c) * 16777619u);

    private async Task Enter()
    {
        if (Failure is { } failure)
        {
            throw failure;
        }

        if (Gate is { } gateTask)
        {
            await gateTask();
        }
    }

    public async Task<float[]> EmbedQueryAsync(string text, CancellationToken cancellationToken = default)
    {
        await Enter();
        return Vector(text);
    }

    public Task<float[]> EmbedLatestQueryAsync(string text, CancellationToken cancellationToken = default) => EmbedQueryAsync(text, cancellationToken);

    public async Task<IReadOnlyList<float[]>> EmbedDocumentsAsync(IReadOnlyList<string> texts, string? title = null, CancellationToken cancellationToken = default)
    {
        await Enter();
        lock (gate) DocumentBatches.Add((title ?? "", texts.Count));
        return [.. texts.Select(Vector)];
    }

    public async Task<float[]> EmbedImageAsync(byte[] imagePng, CancellationToken cancellationToken = default)
    {
        await Enter();
        lock (gate) Images.Add(imagePng.Length);
        return Vector("image" + imagePng.Length);
    }

    public Task<EmbedResponse> PingAsync(CancellationToken cancellationToken = default) => Task.FromResult(EmbedResponse.Create("p", 256));

    public Task ShutdownAsync()
    {
        ShutdownCalls++;
        return Task.CompletedTask;
    }

    public Task CloseAsync()
    {
        CloseCalls++;
        return Task.CompletedTask;
    }
}

internal static class Wait
{
    public static async Task Until(Func<bool> condition, string what)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException("Timed out waiting for " + what);
            }

            await Task.Delay(10);
        }
    }
}
