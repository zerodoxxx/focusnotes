using System.Collections.Frozen;
using CaptureApp.Core.Watching;

namespace CaptureApp.Core;

public sealed class VaultChange : IEquatable<VaultChange>
{
    public IReadOnlySet<string> NotesChanged { get; }
    public IReadOnlySet<string> AssetsChanged { get; }
    public bool NeedsFullSync { get; }
    public ExternalNoteRegistryError? ExternalRegistryError { get; }
    public int? ExternalRegistryErrorVersion { get; }
    public bool ExternalRegistryRecovered { get; }

    public VaultChange(IEnumerable<string> notesChanged, IEnumerable<string> assetsChanged, bool needsFullSync,
        ExternalNoteRegistryError? externalRegistryError = null, bool externalRegistryRecovered = false,
        int? externalRegistryErrorVersion = null)
    {
        NotesChanged = notesChanged.ToFrozenSet(StringComparer.Ordinal);
        AssetsChanged = assetsChanged.ToFrozenSet(StringComparer.Ordinal);
        NeedsFullSync = needsFullSync;
        ExternalRegistryError = externalRegistryError;
        ExternalRegistryRecovered = externalRegistryRecovered;
        ExternalRegistryErrorVersion = externalRegistryErrorVersion;
    }

    public bool Equals(VaultChange? other) => other is not null && NotesChanged.SetEquals(other.NotesChanged)
        && AssetsChanged.SetEquals(other.AssetsChanged) && NeedsFullSync == other.NeedsFullSync
        && ExternalRegistryError == other.ExternalRegistryError && ExternalRegistryErrorVersion == other.ExternalRegistryErrorVersion
        && ExternalRegistryRecovered == other.ExternalRegistryRecovered;
    public override bool Equals(object? obj) => obj is VaultChange other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(NeedsFullSync, ExternalRegistryError, ExternalRegistryErrorVersion,
        ExternalRegistryRecovered, NotesChanged.Aggregate(0, (hash, id) => hash ^ StringComparer.Ordinal.GetHashCode(id)),
        AssetsChanged.Aggregate(0, (hash, id) => hash ^ StringComparer.Ordinal.GetHashCode(id)));
}

/// Watches the vault recursively and only exact registered external paths.
/// All state and callbacks are serialized; healthy watches have no periodic timer.
public sealed class VaultWatcher : IDisposable
{
    internal const int BufferSize = 64 * 1024; // Also valid for UNC/network roots.
    private static readonly StringComparer PathComparer = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
    private static readonly TimeSpan ExternalDebounce = TimeSpan.FromMilliseconds(40);
    private readonly object gate = new();
    private readonly Vault vault;
    private readonly TimeSpan latency;
    private readonly Action<VaultChange> onChange;
    private readonly Dictionary<string, DirectoryWatch> parents = new(PathComparer);
    private readonly Dictionary<string, VaultNoteLocation> external = new(StringComparer.Ordinal);
    private readonly Dictionary<string, WatchSnapshot?> fingerprints = new(StringComparer.Ordinal);
    private readonly HashSet<string> fallbackIds = new(StringComparer.Ordinal);
    private readonly HashSet<string> pendingExternal = new(StringComparer.Ordinal);
    private readonly Dictionary<string, WatcherChangeTypes> pendingRoot = new(StringComparer.Ordinal);
    private readonly HashSet<string> issues = new(StringComparer.Ordinal);
    private readonly HashSet<string> failedParents = new(PathComparer);
    private readonly Dictionary<string, int> parentRetries = new(PathComparer);
    private readonly Queue<VaultChange> deliveries = new();
    private Dictionary<string, WatchSnapshot> rootSnapshot = new(StringComparer.Ordinal);
    private DirectoryWatch? root;
    private Timer? rootTimer, externalTimer, fallbackTimer, deliveryTimer, parentRetryTimer;
    private WatchSnapshot? rootIdentity;
    private WatchSnapshot? registryFingerprint;
    private (WatchSnapshot? Fingerprint, ExternalNoteRegistryError Error, int? Version)? registryFailure;
    private ulong? registryGeneration;
    private string? registryParent;
    private bool registryPending, rootRescanPending, rootFallback, running, disposed;
    private int epoch, streamGeneration, maximumParents = 64, deliveringEpoch = -1;
    private TimeSpan fallbackInterval = TimeSpan.FromSeconds(15);
    private long lastRetry;
    private Func<string, bool>? failWatchForChecks;

    private sealed class DirectoryWatch(FileSystemWatcher watcher, WatchSnapshot identity)
    {
        internal FileSystemWatcher Watcher { get; } = watcher;
        internal WatchSnapshot Identity { get; } = identity;
        internal int Errors { get; set; }
    }

    public VaultWatcher(Vault vault, Action<VaultChange> onChange, double latency = 1.0)
    {
        this.vault = vault;
        this.onChange = onChange;
        this.latency = TimeSpan.FromSeconds(double.IsFinite(latency) ? Math.Max(0, latency) : 1);
    }

    public VaultWatcher(Vault vault, double latency, Action<VaultChange> onChange) : this(vault, onChange, latency) { }

    public bool IsRunning { get { lock (gate) { return running; } } }

    public void Start()
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (running) { return; }
            root = CreateWatch(vault.Root, recursive: true);
            if (root is null)
            {
                ReportIssue("vault-stream-unavailable");
                return;
            }

            issues.Remove("vault-stream-unavailable");
            running = true;
            streamGeneration++;
            rootSnapshot = ScanRoot();
            ReconcileParents(); // Subscribe before reading the registry, then bracket the read with stats.
            RefreshRegistry(force: true, requestSync: false);
            ReconcileParents();
            UpdateFallbackTimer();
        }
    }

    public void Stop()
    {
        lock (gate)
        {
            epoch++;
            running = false;
            root?.Watcher.Dispose();
            root = null;
            foreach (var watch in parents.Values) { watch.Watcher.Dispose(); }
            parents.Clear();
            rootTimer?.Dispose(); rootTimer = null;
            externalTimer?.Dispose(); externalTimer = null;
            fallbackTimer?.Dispose(); fallbackTimer = null;
            deliveryTimer?.Dispose(); deliveryTimer = null;
            parentRetryTimer?.Dispose(); parentRetryTimer = null; parentRetries.Clear();
            external.Clear(); fingerprints.Clear(); fallbackIds.Clear(); pendingExternal.Clear();
            pendingRoot.Clear(); rootSnapshot.Clear(); issues.Clear(); failedParents.Clear(); deliveries.Clear();
            registryFingerprint = null; registryFailure = null; registryGeneration = null; registryParent = null;
            rootIdentity = null;
            registryPending = false; rootRescanPending = false; rootFallback = false; lastRetry = 0;
        }
    }

    public void RefreshExternalRoots()
    {
        lock (gate)
        {
            if (!running) { return; }
            ReconcileParents();
            RefreshRegistry(force: false, requestSync: true);
            ReconcileParents();
            UpdateFallbackTimer();
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            Stop();
            disposed = true;
        }
    }

    private DirectoryWatch? CreateWatch(string path, bool recursive)
    {
        FileSystemWatcher? watcher = null;
        try
        {
            if (failWatchForChecks?.Invoke(path) == true) { return null; }
            var identity = WatchSnapshot.At(path);
            if (identity is not { IsDirectory: true, IsLink: false, IsPlaceholder: false }) { return null; }
            watcher = new(path)
            {
                IncludeSubdirectories = recursive,
                InternalBufferSize = BufferSize,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite
                    | NotifyFilters.Size | NotifyFilters.Attributes | NotifyFilters.CreationTime
            };
            var watch = new DirectoryWatch(watcher, identity);
            watcher.Created += (_, e) => HandleEvent(watch, recursive, e.FullPath, WatcherChangeTypes.Created);
            watcher.Changed += (_, e) => HandleEvent(watch, recursive, e.FullPath, WatcherChangeTypes.Changed);
            watcher.Deleted += (_, e) => HandleEvent(watch, recursive, e.FullPath, WatcherChangeTypes.Deleted);
            watcher.Renamed += (_, e) =>
            {
                HandleEvent(watch, recursive, e.OldFullPath, WatcherChangeTypes.Renamed);
                HandleEvent(watch, recursive, e.FullPath, WatcherChangeTypes.Renamed);
            };
            watcher.Error += (_, e) => HandleError(watch, recursive, e.GetException());
            watcher.EnableRaisingEvents = true;
            return watch;
        }
        catch (Exception error) when (IsWatchFailure(error))
        {
            watcher?.Dispose();
            return null;
        }
    }

    private bool IsCurrent(DirectoryWatch watch, bool recursive) => recursive ? ReferenceEquals(root, watch)
        : parents.TryGetValue(watch.Watcher.Path, out var current) && ReferenceEquals(current, watch);

    private void HandleEvent(DirectoryWatch watch, bool recursive, string path, WatcherChangeTypes kind)
    {
        lock (gate)
        {
            if (!running || !IsCurrent(watch, recursive)) { return; }
            if (recursive)
            {
                var relative = vault.RelativePath(path);
                if (relative is not null)
                {
                    pendingRoot[relative] = pendingRoot.GetValueOrDefault(relative) | kind;
                    ScheduleRoot();
                }
            }
            else
            {
                foreach (var location in external.Values)
                {
                    if (Affects(path, location.Url)) { pendingExternal.Add(location.Id); }
                }

                if (vault.ExternalNoteRegistry is { } registry && Affects(path, registry.Url)) { registryPending = true; }
                if (pendingExternal.Count != 0 || registryPending) { ScheduleExternal(); }
            }
        }
    }

    private static bool Affects(string path, string target)
    {
        var prefix = Path.EndsInDirectorySeparator(path) ? path : path + Path.DirectorySeparatorChar;
        return PathComparer.Equals(path, target) || target.StartsWith(prefix,
            OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    }

    private void HandleError(DirectoryWatch watch, bool recursive, Exception error)
    {
        lock (gate)
        {
            if (!running || !IsCurrent(watch, recursive)) { return; }
            watch.Errors++;
            if (recursive)
            {
                rootRescanPending = true;
                ScheduleRoot();
            }
            else
            {
                pendingExternal.UnionWith(external.Keys);
                registryPending = true;
                ScheduleExternal();
            }

            // An overflow loses event details but does not stop the native watcher.
            // Other errors can stop it; recreate it immediately, or enter fallback.
            if (watch.Errors >= 3 || error is not InternalBufferOverflowException)
            {
                var path = watch.Watcher.Path;
                watch.Watcher.Dispose();
                var replacement = watch.Errors < 3 ? CreateWatch(path, recursive) : null;
                if (replacement is not null) { replacement.Errors = watch.Errors; }
                if (recursive)
                {
                    root = replacement;
                    rootFallback = replacement is null;
                }
                else
                {
                    parents.Remove(path);
                    // A watched directory deleted and recreated in place races this handler (Windows reports
                    // access-denied on deletion). Let ReconcileParents decide so a missing path is not poisoned.
                    if (replacement is not null) { parents[path] = replacement; }
                    else if (watch.Errors >= 3) { failedParents.Add(path); }
                }

                if (replacement is null && (recursive || watch.Errors >= 3)) { ReportIssue("watch-unavailable:" + path); }
                ReconcileParents();
                UpdateFallbackTimer();
            }
        }
    }

    private Dictionary<string, WatchSnapshot> ScanRoot()
    {
        var result = new Dictionary<string, WatchSnapshot>(StringComparer.Ordinal);
        void Visit(string directory)
        {
            try
            {
                foreach (var path in Directory.EnumerateFileSystemEntries(directory))
                {
                    var relative = vault.RelativePath(path)!;
                    var value = WatchSnapshot.At(path);
                    if (value is null || value.IsLink) { continue; }
                    if (value.IsDirectory)
                    {
                        result[relative] = value;
                        if (!Path.GetFileName(path).StartsWith('.') && !value.IsPlaceholder) { Visit(path); }
                    }
                    else if (IsReportable(relative)) { result[relative] = value; }
                }
            }
            catch (Exception error) when (IsWatchFailure(error))
            {
                // Keep the previous subtree on a failed enumeration; do not turn
                // access errors into a batch of fictitious deletions.
                foreach (var pair in rootSnapshot.Where(p => Affects(directory, vault.UrlForRelativePath(p.Key))))
                {
                    result.TryAdd(pair.Key, pair.Value);
                }
                // Reported once per directory: clearing it on the next good scan made transient Windows
                // failures (entries pending delete mid-write) republish a full sync on every batch.
                ReportIssue("scan:" + directory);
            }
        }

        try
        {
            var rootValue = WatchSnapshot.At(vault.Root);
            rootIdentity = rootValue;
            if (rootValue is { IsDirectory: true, IsLink: false, IsPlaceholder: false })
            {
                issues.Remove("vault-root-unavailable");
                Visit(vault.Root);
            }
            else if (running) { ReportIssue("vault-root-unavailable"); }
        }
        catch (Exception error) when (IsWatchFailure(error))
        {
            ReportIssue("vault-root-unavailable");
            return new(rootSnapshot, StringComparer.Ordinal);
        }
        return result;
    }

    private void FlushRoot()
    {
        var previousRoot = rootIdentity;
        var current = ScanRoot();
        var notes = new HashSet<string>(StringComparer.Ordinal);
        var assets = new HashSet<string>(StringComparer.Ordinal);
        // Dropped root events have Swift's must-scan/full-sync semantics even
        // when the metadata diff is empty (asset digests may still need work).
        var fullSync = rootRescanPending || (previousRoot is null ? rootIdentity is not null
            : rootIdentity is null || !previousRoot.SameDirectory(rootIdentity));
        foreach (var path in rootSnapshot.Keys.Concat(current.Keys).Distinct(StringComparer.Ordinal))
        {
            rootSnapshot.TryGetValue(path, out var before);
            current.TryGetValue(path, out var after);
            if (before == after) { continue; }
            if (before?.IsDirectory == true || after?.IsDirectory == true)
            {
                if (before?.IsDirectory == true && (after is null || !before.SameDirectory(after))) { fullSync = true; }
                if (IsAsset(path)) { Classify(path, notes, assets); }
            }
            else { Classify(path, notes, assets); }
        }

        foreach (var (path, kind) in pendingRoot)
        {
            rootSnapshot.TryGetValue(path, out var before);
            current.TryGetValue(path, out var after);
            if (before?.IsDirectory == true || after?.IsDirectory == true)
            {
                if ((kind & (WatcherChangeTypes.Deleted | WatcherChangeTypes.Renamed)) != 0) { fullSync = true; }
                if (IsAsset(path)) { Classify(path, notes, assets); }
            }
            else { Classify(path, notes, assets); }
        }

        rootSnapshot = current;
        pendingRoot.Clear();
        rootRescanPending = false;
        Publish(notes, assets, fullSync);
    }

    private static bool IsAsset(string path) => path.Split('/')[0].Equals(Vault.AssetsDirectoryName, StringComparison.OrdinalIgnoreCase);
    private static bool IsReportable(string path)
    {
        var parts = path.Split('/');
        var name = parts[^1];
        return !parts.Any(p => p.StartsWith('.')) && !name.StartsWith("~$", StringComparison.Ordinal)
            && !name.EndsWith(".swp", StringComparison.OrdinalIgnoreCase) && !name.EndsWith(".icloud", StringComparison.OrdinalIgnoreCase)
            && (IsAsset(path) ? parts.Length >= 2 : Path.GetExtension(name).Equals(".md", StringComparison.OrdinalIgnoreCase));
    }

    private static void Classify(string path, HashSet<string> notes, HashSet<string> assets)
    {
        if (!IsReportable(path)) { return; }
        if (IsAsset(path)) { assets.Add(path); }
        else { notes.Add(path); }
    }

    private void RefreshRegistry(bool force, bool requestSync)
    {
        if (vault.ExternalNoteRegistry is not { } registry) { return; }
        WatchSnapshot? before = null;
        try
        {
            before = WatchSnapshot.At(registry.Url);
            if (!force && before == registryFingerprint && registryFailure is null) { return; }
            for (var attempt = 0; attempt < 3; attempt++)
            {
                if (before is { IsLink: true } or { IsPlaceholder: true })
                {
                    throw new ExternalNoteRegistryException(ExternalNoteRegistryError.UnreadableRegistry);
                }

                vault.InvalidateExternalRegistryCache();
                ExternalNoteRegistry.Snapshot? snapshot;
                try { snapshot = vault.ExternalRegistrySnapshot(); }
                catch (ExternalNoteRegistryException)
                {
                    var afterFailure = WatchSnapshot.At(registry.Url);
                    if (before == afterFailure) { throw; }
                    before = afterFailure;
                    continue;
                }

                var after = WatchSnapshot.At(registry.Url);
                if (before != after) { before = after; continue; }
                registryFingerprint = after;
                var recovered = registryFailure is not null;
                if (registryGeneration != snapshot?.Generation || recovered)
                {
                    // Location resolution does not open note files. Snapshot
                    // failures belong to individual notes, not to the registry.
                    var locations = vault.ExternalNoteLocations(snapshot);

                    external.Clear(); fingerprints.Clear(); pendingExternal.Clear();
                    foreach (var location in locations)
                    {
                        external[location.Id] = location;
                        fingerprints[location.Id] = ExternalSnapshot(location);
                    }
                    registryGeneration = snapshot?.Generation ?? 0;
                    registryFailure = null;
                    issues.Remove("registry-snapshot");
                    ReconcileParents();
                    if (requestSync || recovered) { Publish([], [], true, recovered: recovered); }
                }

                return;
            }

            throw new ExternalNoteRegistryException(ExternalNoteRegistryError.UnreadableRegistry);
        }
        catch (Exception error) when (IsWatchFailure(error))
        {
            var typed = error as ExternalNoteRegistryException;
            var failure = (before, typed?.Kind ?? ExternalNoteRegistryError.UnreadableRegistry, typed?.Version);
            registryFingerprint = before;
            if (registryFailure == failure) { return; }
            registryFailure = failure;
            vault.InvalidateExternalRegistryCache();
            external.Clear(); fingerprints.Clear(); pendingExternal.Clear();
            issues.Add("registry-snapshot");
            Publish([], [], true, failure.Item2, version: failure.Item3);
        }
    }

    private WatchSnapshot? ExternalSnapshot(VaultNoteLocation location)
    {
        try
        {
            var value = WatchSnapshot.Managed(vault.HomeRoot, location.RelativePath);
            if (value?.IsDirectory == true) { throw new VaultFileException(VaultFileError.PermissionDenied); }
            issues.Remove("snapshot:" + location.Id);
            return value;
        }
        catch (Exception error) when (IsWatchFailure(error))
        {
            ReportIssue("snapshot:" + location.Id);
            return fingerprints.GetValueOrDefault(location.Id);
        }
    }

    private string? NearestParent(string target, string boundary, bool managed = true)
    {
        var candidate = Path.GetDirectoryName(target);
        while (candidate is not null && Affects(boundary, candidate))
        {
            try
            {
                var value = !managed || PathComparer.Equals(candidate, boundary) ? WatchSnapshot.At(candidate)
                    : WatchSnapshot.Managed(boundary, Path.GetRelativePath(boundary, candidate).Replace(Path.DirectorySeparatorChar, '/'), directory: true);
                value?.Metadata?.Validate(directory: true);
                if (value is { IsDirectory: true, IsLink: false, IsPlaceholder: false }) { return candidate; }
            }
            catch (Exception error) when (IsWatchFailure(error)) { }
            candidate = Path.GetDirectoryName(candidate);
        }
        return null;
    }

    private void ReconcileParents()
    {
        var desired = new HashSet<string>(PathComparer);
        registryParent = vault.ExternalNoteRegistry is { } registry
            ? NearestParent(registry.Url, Path.GetPathRoot(registry.Url)!, managed: false) : null;
        if (registryParent is not null) { desired.Add(registryParent); }
        var parentById = external.Values.ToDictionary(l => l.Id, l => NearestParent(l.Url, vault.HomeRoot), StringComparer.Ordinal);
        foreach (var path in parentById.Values.OfType<string>().Distinct(PathComparer).Order(StringComparer.Ordinal).Take(maximumParents))
        {
            desired.Add(path);
        }
        failedParents.RemoveWhere(path => !desired.Contains(path));

        foreach (var (path, watch) in parents.ToArray())
        {
            WatchSnapshot? current = null;
            try { current = WatchSnapshot.At(path); }
            catch (Exception error) when (IsWatchFailure(error)) { }
            if (!desired.Contains(path) || current is null || !watch.Identity.SameDirectory(current))
            {
                parents.Remove(path);
                watch.Watcher.Dispose();
            }
        }

        foreach (var path in desired.Where(p => !parents.ContainsKey(p) && !failedParents.Contains(p)))
        {
            var watch = CreateWatch(path, recursive: false);
            if (watch is null)
            {
                failedParents.Add(path);
                ReportIssue("watch-unavailable:" + path);
                ScheduleParentRetry(path);
            }
            else { parents[path] = watch; parentRetries.Remove(path); issues.Remove("watch-unavailable:" + path); }
        }

        fallbackIds.Clear();
        foreach (var (id, path) in parentById)
        {
            if (path is null || !parents.ContainsKey(path) || issues.Contains("snapshot:" + id)) { fallbackIds.Add(id); }
        }
        if (parentById.Values.OfType<string>().Distinct(PathComparer).Count() > maximumParents) { ReportIssue("parent-watch-cap"); }
        else { issues.Remove("parent-watch-cap"); }
    }

    private void FlushExternal()
    {
        if (registryPending) { registryPending = false; RefreshRegistry(force: false, requestSync: true); }
        var changed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in pendingExternal.ToArray())
        {
            if (!external.TryGetValue(id, out var location)) { continue; }
            var current = ExternalSnapshot(location);
            if (fingerprints.GetValueOrDefault(id) != current) { fingerprints[id] = current; changed.Add(id); }
        }
        pendingExternal.Clear();
        ReconcileParents();
        UpdateFallbackTimer();
        Publish(changed, [], false);
    }

    private void PollFallbacks()
    {
        if (rootFallback) { FlushRoot(); }
        if (vault.ExternalNoteRegistry is not null && (registryParent is null || !parents.ContainsKey(registryParent)))
        {
            RefreshRegistry(force: false, requestSync: true);
        }
        pendingExternal.UnionWith(fallbackIds);
        FlushExternal();
        if (Environment.TickCount64 - lastRetry >= Math.Max(30000, fallbackInterval.TotalMilliseconds * 4))
        {
            lastRetry = Environment.TickCount64;
            failedParents.Clear();
            if (rootFallback)
            {
                root = CreateWatch(vault.Root, recursive: true);
                rootFallback = root is null;
                if (!rootFallback) { issues.Remove("watch-unavailable:" + vault.Root); }
            }
            ReconcileParents();
            UpdateFallbackTimer();
        }
    }

    private void UpdateFallbackTimer()
    {
        var needed = rootFallback || fallbackIds.Count != 0 || vault.ExternalNoteRegistry is not null
            && (registryParent is null || !parents.ContainsKey(registryParent));
        if (!needed) { fallbackTimer?.Dispose(); fallbackTimer = null; return; }
        if (fallbackTimer is not null || !running) { return; }
        var generation = epoch;
        fallbackTimer = new Timer(_ =>
        {
            lock (gate)
            {
                if (generation == epoch && running && fallbackTimer is not null) { PollFallbacks(); }
            }
        }, null, fallbackInterval, fallbackInterval);
    }

    // A parent can fail transiently (directory recreated while the old handle is closing); retry briefly.
    private void ScheduleParentRetry(string path)
    {
        var attempts = parentRetries.GetValueOrDefault(path);
        if (attempts >= 5) { return; }
        parentRetries[path] = attempts + 1;
        if (parentRetryTimer is not null) { return; }
        var generation = epoch;
        parentRetryTimer = new Timer(_ =>
        {
            lock (gate)
            {
                if (generation != epoch || !running) { return; }
                parentRetryTimer?.Dispose(); parentRetryTimer = null;
                failedParents.RemoveWhere(p => parentRetries.GetValueOrDefault(p) is > 0 and < 5);
                ReconcileParents();
                UpdateFallbackTimer();
            }
        }, null, TimeSpan.FromMilliseconds(100), Timeout.InfiniteTimeSpan);
    }

    private void ScheduleRoot()
    {
        if (rootTimer is not null) { return; }
        var generation = epoch;
        rootTimer = new Timer(_ =>
        {
            lock (gate)
            {
                if (generation != epoch || !running) { return; }
                rootTimer?.Dispose(); rootTimer = null;
                if (rootRescanPending || pendingRoot.Count != 0) { FlushRoot(); }
            }
        }, null, latency, Timeout.InfiniteTimeSpan);
    }

    private void ScheduleExternal()
    {
        if (externalTimer is not null) { return; }
        var generation = epoch;
        externalTimer = new Timer(_ =>
        {
            lock (gate)
            {
                if (generation != epoch || !running) { return; }
                externalTimer?.Dispose(); externalTimer = null;
                FlushExternal();
            }
        }, null, ExternalDebounce, Timeout.InfiniteTimeSpan);
    }

    private void ReportIssue(string key)
    {
        if (issues.Add(key)) { Publish([], [], true); }
    }

    private void Publish(IEnumerable<string> notes, IEnumerable<string> assets, bool fullSync,
        ExternalNoteRegistryError? error = null, bool recovered = false, int? version = null)
    {
        var change = new VaultChange(notes, assets, fullSync, error, recovered, version);
        if (!fullSync && change.NotesChanged.Count == 0 && change.AssetsChanged.Count == 0 && error is null && !recovered) { return; }
        deliveries.Enqueue(change);
        if (deliveryTimer is not null) { return; }
        var generation = epoch;
        deliveryTimer = new Timer(_ =>
        {
            lock (gate)
            {
                if (generation != epoch) { return; }
                deliveryTimer?.Dispose(); deliveryTimer = null;
                if (deliveringEpoch == generation) { return; } // The active loop drains the queue.
                deliveringEpoch = generation;
            }

            // Deliver outside the lock so observers can call back into the watcher.
            while (true)
            {
                VaultChange next;
                lock (gate)
                {
                    // Release ownership in the same lock as the empty check, or a concurrent Publish is stranded.
                    if (generation != epoch || !deliveries.TryDequeue(out next!))
                    {
                        if (deliveringEpoch == generation) { deliveringEpoch = -1; }
                        return;
                    }
                }

                // An observer failure must not crash the timer thread or stall later deliveries.
                try { onChange(next); }
                catch (Exception) { }
            }
        }, null, TimeSpan.Zero, Timeout.InfiniteTimeSpan);
    }

    private static bool IsWatchFailure(Exception error) => error is IOException or UnauthorizedAccessException or ArgumentException
        or System.ComponentModel.Win32Exception or NotSupportedException;

    internal int StreamGenerationForChecks { get { lock (gate) { return streamGeneration; } } }
    internal int ParentWatcherCountForChecks { get { lock (gate) { return parents.Count; } } }
    internal int PollingFallbackCountForChecks { get { lock (gate) { return fallbackIds.Count; } } }
    internal bool HasPollingTimerForChecks { get { lock (gate) { return fallbackTimer is not null; } } }
    internal IReadOnlySet<string> ParentPathsForChecks { get { lock (gate) { return parents.Keys.ToFrozenSet(PathComparer); } } }
    internal IReadOnlySet<string> ReportedWatchIssuesForChecks { get { lock (gate) { return issues.ToFrozenSet(); } } }
    internal void ConfigureWatchFallbackForChecks(int maximumParentWatchers, double interval, Func<string, bool>? failWatch = null)
    {
        lock (gate)
        {
            if (running) { throw new InvalidOperationException("Configure watches before Start()."); }
            maximumParents = Math.Max(0, maximumParentWatchers);
            fallbackInterval = TimeSpan.FromSeconds(Math.Max(0.01, interval));
            failWatchForChecks = failWatch;
        }
    }

    internal void SimulateErrorForChecks(string? parent = null, Exception? error = null)
    {
        lock (gate)
        {
            var watch = parent is null ? root : parents.GetValueOrDefault(parent);
            if (watch is null) { throw new InvalidOperationException("No watch for the supplied path."); }
            HandleError(watch, parent is null, error ?? new InternalBufferOverflowException());
        }
    }

    internal void SetNativeEventsEnabledForChecks(bool enabled)
    {
        lock (gate)
        {
            if (root is not null) { root.Watcher.EnableRaisingEvents = enabled; }
            foreach (var watch in parents.Values) { watch.Watcher.EnableRaisingEvents = enabled; }
        }
    }
}
