using CaptureApp.Core;

namespace CaptureApp.AppCore;

/// The unsaved-capture ledger: every capture between preparation and the vault, its journal records, the single
/// ordered commit tail, failed captures kept for retry, and the quit drain. Journal writes go through the
/// pipeline's gated path. It never takes the pipeline's capture gate while holding its own lock.
public sealed class UnsavedCaptures
{
    private sealed class Entry
    {
        // The job and store of the last Record for this id.
        public Task<CaptureJob>? Recorded;
        public Task? Stored;
        // The job being committed, or kept for retry once Kept is set.
        public Task<CaptureJob>? Job;
        public bool Kept;
        public long Order;
    }

    private readonly object gate = new();
    private readonly CapturePipeline pipeline;
    private readonly AppLog log;
    private readonly Dictionary<Guid, Entry> entries = [];
    // Destinations of prepared jobs by capture id, so a session rename can relocate work it has not journaled yet.
    private readonly Dictionary<Guid, Destination> destinations = [];
    private Task<SavedCapture>? tail;
    private int generation;
    private long order;

    internal UnsavedCaptures(CapturePipeline pipeline)
    {
        this.pipeline = pipeline;
        log = new(pipeline.StateDirectory, "unsaved");
    }

    public Task? Tail { get { lock (gate) { return tail; } } }

    /// Journals a capture that is not being committed yet. <paramref name="prepare"/> gets the job recorded earlier
    /// for this id, or null. Writes for one id stay in order.
    public Task Record(Guid id, Func<CaptureJob?, CaptureJob> prepare)
    {
        lock (gate)
        {
            var entry = EntryFor(id);
            var previousJob = entry.Recorded;
            var previousStore = entry.Stored;
            var preparation = Task.Run(async () => prepare(await TryResult(previousJob).ConfigureAwait(false)));
            var store = Task.Run(async () =>
            {
                await TryWait(previousStore).ConfigureAwait(false);
                pipeline.Stage(await preparation.ConfigureAwait(false));
            });
            entry.Recorded = preparation;
            entry.Stored = store;
            return store;
        }
    }

    public bool IsRecorded(Guid id)
    {
        lock (gate) { return entries.TryGetValue(id, out var entry) && entry.Recorded is not null; }
    }

    /// The job prepared by the last Record for this id, even if its store failed; null if none or it failed.
    public Task<CaptureJob?> RecordedAsync(Guid id)
    {
        Task<CaptureJob>? recorded;
        lock (gate) { recorded = entries.GetValueOrDefault(id)?.Recorded; }
        return TryResult(recorded);
    }

    /// Commits after every earlier commit. A failed commit keeps its job for retry; a saved one is forgotten.
    public Task<SavedCapture> Commit(Guid id, Task<CaptureJob> preparation, Func<CaptureJob, SavedCapture> save)
    {
        lock (gate)
        {
            var entry = EntryFor(id);
            entry.Job = preparation;
            entry.Kept = false;
            entry.Order = ++order;
            var stored = entry.Stored;
            var previous = tail;
            var current = ++generation;
            var task = Task.Run(async () =>
            {
                try
                {
                    var job = await preparation.ConfigureAwait(false);
                    await TryWait(stored).ConfigureAwait(false);
                    // Journal before waiting for earlier writes, so even queued work is recoverable.
                    pipeline.Stage(job);
                    await TryWait(previous).ConfigureAwait(false);
                    var saved = save(job);
                    lock (gate) { if (entries.GetValueOrDefault(id) is { } done && done.Job == preparation) { entries.Remove(id); } }
                    return saved;
                }
                catch
                {
                    lock (gate) { if (entries.GetValueOrDefault(id) is { } failed && failed.Job == preparation) { failed.Kept = true; } }
                    throw;
                }
                finally
                {
                    // Clear the tail even on failure so it isn't re-awaited later.
                    lock (gate) { if (generation == current) { tail = null; } }
                }
            });
            tail = task;
            return task;
        }
    }

    public Task WaitForCommitsAsync() => TryWait(Tail);

    /// Over failed captures, oldest first: discards each one <paramref name="superseded"/> accepts, then returns the
    /// first one <paramref name="equivalent"/> accepts, so the caller can recommit it under its id.
    public async Task<CaptureJob?> FindRetryAsync(Func<CaptureJob, bool> equivalent, Func<CaptureJob, bool>? superseded = null)
    {
        KeyValuePair<Guid, Task<CaptureJob>>[] kept;
        lock (gate) { kept = KeptJobs(); }
        CaptureJob? retry = null;
        var discarded = new List<KeyValuePair<Guid, Task<CaptureJob>>>();
        foreach (var candidate in kept)
        {
            if (await TryResult(candidate.Value).ConfigureAwait(false) is not { } job) { continue; }
            if (superseded?.Invoke(job) == true) { discarded.Add(candidate); continue; }
            if (equivalent(job)) { retry = job; break; }
        }

        // Remove the durable record first. If removal fails, the old job stays retryable.
        foreach (var (id, job) in discarded)
        {
            pipeline.Discard(id);
            lock (gate) { if (entries.GetValueOrDefault(id) is { } entry && entry.Job == job) { entries.Remove(id); } }
        }

        return retry;
    }

    /// Keeps the recorded job for the quit drain, e.g. when a commit failed in preparation and a newer capture took its place.
    public void Keep(Guid id)
    {
        lock (gate)
        {
            if (!entries.TryGetValue(id, out var entry) || entry.Recorded is null) { return; }
            entry.Job = entry.Recorded;
            entry.Kept = true;
            entry.Order = ++order;
        }
    }

    /// Drops the commit job for this id in memory only; its record and journal file stay.
    public void Forget(Guid id)
    {
        lock (gate)
        {
            if (!entries.TryGetValue(id, out var entry)) { return; }
            entry.Job = null;
            entry.Kept = false;
            if (entry.Recorded is null) { entries.Remove(id); }
        }
    }

    /// Every recorded store, failures swallowed.
    public Task WhenRecorded()
    {
        Task[] stores;
        lock (gate) { stores = Stores(); }
        return Task.WhenAll(stores.Select(TryWait));
    }

    /// At quit: waits for recorded stores and the commit tail, then retries each kept job in order unless <paramref name="stopped"/>.
    public async Task DrainAsync(Func<CaptureJob, SavedCapture> save, Func<bool> stopped)
    {
        Task[] stores;
        lock (gate) { stores = Stores(); }
        foreach (var store in stores)
        {
            try { await store.ConfigureAwait(false); }
            catch (Exception error) { log.Error($"Shutdown recovery journal failed: {error.GetType().Name}"); }
        }

        await WaitForCommitsAsync().ConfigureAwait(false);
        if (stopped()) { return; }
        // A journal write itself may have failed earlier: retry the exact prepared capture.
        KeyValuePair<Guid, Task<CaptureJob>>[] kept;
        lock (gate) { kept = KeptJobs(); }
        foreach (var (id, preparation) in kept)
        {
            try
            {
                var job = await preparation.ConfigureAwait(false);
                pipeline.Stage(job);
                save(job);
                lock (gate) { if (entries.GetValueOrDefault(id) is { } entry && entry.Job == preparation) { entries.Remove(id); } }
            }
            catch (Exception error) { log.Error($"Shutdown save retained in journal: {error.GetType().Name}"); }
        }
    }

    // Rename support; called by the pipeline under its capture gate.
    internal void Prepared(Guid id, Destination destination)
    {
        lock (gate) { destinations[id] = destination; }
    }

    internal Guid[] PreparedTargeting(Func<Destination, bool> matches)
    {
        lock (gate) { return destinations.Where(pair => matches(pair.Value)).Select(pair => pair.Key).ToArray(); }
    }

    internal void Relocate(IEnumerable<Guid> ids, Destination destination)
    {
        lock (gate)
        {
            foreach (var id in ids)
            {
                if (destinations.ContainsKey(id)) { destinations[id] = destination; }
            }
        }
    }

    internal void Saved(Guid id)
    {
        lock (gate) { destinations.Remove(id); }
    }

    private Entry EntryFor(Guid id)
    {
        if (!entries.TryGetValue(id, out var entry))
        {
            entry = new() { Order = ++order };
            entries[id] = entry;
        }

        return entry;
    }

    private KeyValuePair<Guid, Task<CaptureJob>>[] KeptJobs() => entries
        .Where(pair => pair.Value.Kept && pair.Value.Job is not null)
        .OrderBy(pair => pair.Value.Order)
        .Select(pair => KeyValuePair.Create(pair.Key, pair.Value.Job!))
        .ToArray();

    private Task[] Stores() => entries.Values.Select(entry => entry.Stored).OfType<Task>().ToArray();

    private static async Task TryWait(Task? task)
    {
        if (task is null) { return; }
        try { await task.ConfigureAwait(false); }
        catch (Exception) { }
    }

    private static async Task<T?> TryResult<T>(Task<T>? task) where T : class
    {
        if (task is null) { return null; }
        try { return await task.ConfigureAwait(false); }
        catch (Exception) { return null; }
    }
}
