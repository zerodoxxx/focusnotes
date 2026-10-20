using System.Collections.Frozen;
using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.AppCore;

public sealed record VaultRefreshRequest(bool Notes, bool Assets, IReadOnlySet<string>? RecheckingAssetPaths);

/// Merges watcher notifications and serializes index refresh work.
public sealed class VaultMonitor : IDisposable
{
    private readonly object gate = new();
    private readonly VaultWatcher watcher;
    private readonly SearchIndex index;
    private readonly AppLog logger;
    private readonly Func<Task>? beforeIndexSyncForTesting;
    private readonly Func<Task>? afterIndexSyncForTesting;
    private Task? worker;
    private bool notesDirty;
    private bool assetsDirty;
    private bool fullAssetValidation;
    private bool stopped;
    private readonly HashSet<string> changedAssetPaths = new(StringComparer.Ordinal);

    public event Action<VaultChange>? ChangeReceived;
    public event Action<VaultRefreshRequest>? RefreshRequested;
    public bool IsRunning
    {
        get
        {
            lock (gate) { return !stopped && watcher.IsRunning; }
        }
    }

    public VaultMonitor(Vault vault, SearchIndex index, string stateDirectory, double latency = 1.0,
        Func<Task>? beforeIndexSyncForTesting = null, Func<Task>? afterIndexSyncForTesting = null)
    {
        this.index = index;
        logger = new(stateDirectory, "vault-monitor");
        this.beforeIndexSyncForTesting = beforeIndexSyncForTesting;
        this.afterIndexSyncForTesting = afterIndexSyncForTesting;
        watcher = new(vault, OnChanged, latency);
    }

    public void Start()
    {
        lock (gate) { ObjectDisposedException.ThrowIf(stopped, this); }
        watcher.Start(); // Outside the gate: watcher deliveries take the gate on their own thread.
        bool lostStop;
        lock (gate) { lostStop = stopped; }
        if (lostStop) { watcher.Stop(); } // StopAsync ran while Start was in flight.
    }

    public Task SyncAsync() => QueueRefresh(notes: true, assets: false, fullAssetValidation: false, []);
    public Task BackfillAsync() => QueueRefresh(notes: false, assets: true, fullAssetValidation: true, []);

    public void RefreshExternalRoots()
    {
        lock (gate) { if (stopped) { return; } }
        watcher.RefreshExternalRoots();
    }

    public async Task StopAsync()
    {
        Task? pending;
        lock (gate)
        {
            stopped = true;
            notesDirty = false;
            assetsDirty = false;
            fullAssetValidation = false;
            changedAssetPaths.Clear();
            pending = worker;
        }

        watcher.Stop();
        if (pending is not null)
        {
            await pending.ConfigureAwait(false);
        }
    }

    private void OnChanged(VaultChange change)
    {
        lock (gate)
        {
            if (stopped) { return; }
        }

        try { ChangeReceived?.Invoke(change); }
        catch (Exception error) { logger.Error($"Watcher change observer failed: {error}"); }

        var notes = change.NeedsFullSync || change.NotesChanged.Count != 0;
        var knownAssets = change.AssetsChanged.All(IsKnownAssetPath);
        var fullValidation = change.NeedsFullSync || (change.AssetsChanged.Count != 0 && !knownAssets);
        _ = QueueRefresh(notes, change.NeedsFullSync || notes || change.AssetsChanged.Count != 0,
            fullValidation, change.AssetsChanged);
    }

    private Task QueueRefresh(bool notes, bool assets, bool fullAssetValidation, IEnumerable<string> assetPaths)
    {
        lock (gate)
        {
            if (stopped) { return Task.CompletedTask; }
            notesDirty |= notes;
            assetsDirty |= assets;
            if (assets)
            {
                this.fullAssetValidation |= fullAssetValidation;
                if (this.fullAssetValidation)
                {
                    changedAssetPaths.Clear();
                }
                else
                {
                    changedAssetPaths.UnionWith(assetPaths);
                }
            }

            worker ??= Task.Run(DrainAsync);
            return worker;
        }
    }

    private async Task DrainAsync()
    {
        while (true)
        {
            VaultRefreshRequest request;
            lock (gate)
            {
                if (stopped || (!notesDirty && !assetsDirty))
                {
                    worker = null;
                    return;
                }

                var notes = notesDirty;
                var assets = assetsDirty;
                var full = fullAssetValidation;
                var paths = assets && !full ? changedAssetPaths.ToFrozenSet(StringComparer.Ordinal) : null;
                notesDirty = false;
                assetsDirty = false;
                fullAssetValidation = false;
                changedAssetPaths.Clear();
                request = new(notes, assets, paths);
            }

            try
            {
                if (request.Notes)
                {
                    if (beforeIndexSyncForTesting is not null)
                    {
                        await beforeIndexSyncForTesting().ConfigureAwait(false);
                    }

                    await Task.Run(index.Sync).ConfigureAwait(false);
                    if (afterIndexSyncForTesting is not null)
                    {
                        await afterIndexSyncForTesting().ConfigureAwait(false);
                    }
                }

                try { RefreshRequested?.Invoke(request); }
                catch (Exception error) { logger.Error($"Refresh observer failed: {error}"); }
            }
            catch (Exception error)
            {
                logger.Error($"Index refresh failed: {error}");
            }
        }
    }

    private static bool IsKnownAssetPath(string path)
    {
        var components = path.Split('/', StringSplitOptions.None);
        return !path.StartsWith("/", StringComparison.Ordinal) && components.Length >= 2
            && components[0] == Vault.AssetsDirectoryName
            && components.All(component => component.Length != 0 && component is not ("." or ".."));
    }

    public void Dispose() => StopAsync().GetAwaiter().GetResult();
}
