using System.Diagnostics;
using CaptureApp.Core.Watching;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class WatcherTests
{
    private sealed class Recorder
    {
        private readonly object gate = new();
        private readonly List<VaultChange> changes = [];
        internal int CallbackThread { get; private set; }
        internal int Count { get { lock (gate) { return changes.Count; } } }
        internal VaultChange[] Changes { get { lock (gate) { return changes.ToArray(); } } }
        internal void Append(VaultChange change)
        {
            lock (gate)
            {
                CallbackThread = Environment.CurrentManagedThreadId;
                changes.Add(change);
                Monitor.PulseAll(gate);
            }
        }

        internal VaultChange Wait(Func<VaultChange, bool> predicate, int offset = 0)
        {
            var elapsed = Stopwatch.StartNew();
            lock (gate)
            {
                while (true)
                {
                    var match = changes.Skip(offset).FirstOrDefault(predicate);
                    if (match is not null) { return match; }
                    var remaining = TimeSpan.FromSeconds(5) - elapsed.Elapsed;
                    Assert.True(remaining > TimeSpan.Zero, "Timed out waiting for watcher change. Recorded: " +
                        string.Join("; ", changes.Skip(offset).Select(c => $"notes=[{string.Join(',', c.NotesChanged)}] assets=[{string.Join(',', c.AssetsChanged)}] full={c.NeedsFullSync} error={c.ExternalRegistryError}")));
                    Monitor.Wait(gate, remaining);
                }
            }
        }

        internal bool Quiet(double seconds = 0.25)
        {
            lock (gate)
            {
                var count = changes.Count;
                var elapsed = Stopwatch.StartNew();
                var duration = TimeSpan.FromSeconds(seconds);
                while (elapsed.Elapsed < duration)
                {
                    var remaining = duration - elapsed.Elapsed;
                    if (remaining <= TimeSpan.Zero) { break; }
                    Monitor.Wait(gate, remaining);
                    if (changes.Count != count) { return false; }
                }
                return true;
            }
        }

        internal void Drain()
        {
            var elapsed = Stopwatch.StartNew();
            while (!Quiet()) { Assert.True(elapsed.Elapsed < TimeSpan.FromSeconds(5), "Watcher did not settle."); }
        }
    }

    private static void Eventually(Func<bool> predicate) => Assert.True(SpinWait.SpinUntil(predicate, TimeSpan.FromSeconds(5)), "Watcher state did not converge.");
    private static void Registry(CheckVault e, params string[] paths) => CheckVault.AtomicReplace(e.Registry, CheckVault.Json(new { version = 1, paths }));

    [Fact]
    public void WatcherChangeIsAnImmutableValueWithScopedIdsAndTypedErrors()
    {
        var notes = new HashSet<string> { "A.md", "B.md" };
        var change = new VaultChange(notes, ["assets/a.png"], true, ExternalNoteRegistryError.UnsupportedVersion, false, 2);
        notes.Clear();
        var equal = new VaultChange(["B.md", "A.md"], ["assets/a.png"], true, ExternalNoteRegistryError.UnsupportedVersion, false, 2);
        Assert.Equal(equal, change);
        Assert.Equal(equal.GetHashCode(), change.GetHashCode());
        Assert.Equal(2, change.NotesChanged.Count);
        Assert.Equal(2, change.ExternalRegistryErrorVersion);
        Assert.NotEqual(change, new VaultChange(["A.md"], [], false));
        Assert.Equal(64 * 1024, VaultWatcher.BufferSize);
    }

    [Fact]
    public void WatcherReportsRecursiveNotesOwnWritesRenamesDeletesAndAssets()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.08, recorder.Append);
        Assert.False(watcher.IsRunning);
        watcher.Start();
        watcher.Start();
        Assert.True(watcher.IsRunning);
        Assert.Equal(1, watcher.StreamGenerationForChecks);
        Assert.False(watcher.HasPollingTimerForChecks);
        recorder.Drain();

        foreach (var path in new[] { "Foo.md", "Sessions/S.md", "science/math/Trigonometry.md" })
        {
            var offset = recorder.Count;
            e.Write(path, "# First\n");
            recorder.Wait(c => c.NotesChanged.Contains(path), offset);
        }
        var thread = Environment.CurrentManagedThreadId;
        var start = recorder.Count;
        var file = e.Write("Coalesced.md", "app append\n");
        File.AppendAllText(file, "external edit\n");
        recorder.Wait(c => c.NotesChanged.Contains("Coalesced.md"), start);
        Assert.NotEqual(thread, recorder.CallbackThread);

        recorder.Drain();
        start = recorder.Count;
        File.Move(file, e.Vault.UrlForRelativePath("Renamed.md"));
        recorder.Wait(c => c.NotesChanged.Contains("Coalesced.md"), start);
        recorder.Wait(c => c.NotesChanged.Contains("Renamed.md"), start);
        start = recorder.Count;
        File.Delete(e.Vault.UrlForRelativePath("Renamed.md"));
        recorder.Wait(c => c.NotesChanged.Contains("Renamed.md"), start);

        foreach (var path in new[] { "assets/image.png", "ASSETS/Upper.png", "ASSETS/Note.md" })
        {
            start = recorder.Count;
            e.Write(path, "asset bytes");
            recorder.Wait(c => c.AssetsChanged.Any(p => p.Equals(path, StringComparison.OrdinalIgnoreCase)), start);
        }
        recorder.Drain();
        Assert.DoesNotContain(recorder.Changes, c => c.NotesChanged.Any(p => p.StartsWith("ASSETS/", StringComparison.OrdinalIgnoreCase)));
        Assert.DoesNotContain(recorder.Changes, c => c.NeedsFullSync);
        Assert.False(watcher.HasPollingTimerForChecks);
    }

    [Fact]
    public void WatcherIgnoresHiddenMetadataTemporaryAndUnrelatedFiles()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.08, recorder.Append);
        watcher.Start();
        // A quiet gap cannot drain FileSystemWatcher's native event queue. Start with a fresh
        // watcher so a late duplicate from an earlier real write cannot fail this negative check.
        e.Write(".DS_Store", "metadata");
        e.Write("Foo.md.swp", "swap");
        e.Write("~$draft.md", "lock");
        e.Write(".hidden/Secret.md", "hidden");
        e.Write("assets/.hidden.png", "hidden asset");
        e.Write("assets/a.icloud", "placeholder metadata");
        e.Write("plain.txt", "unrelated");
        Assert.True(recorder.Quiet(0.4));
        Assert.Empty(recorder.Changes);
        Assert.False(watcher.HasPollingTimerForChecks);
    }

    [Fact]
    public void WatcherCoalescesAtLatencyAndCancelsPendingBatchesOnStop()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.25, recorder.Append);
        watcher.Start();
        recorder.Drain();
        var offset = recorder.Count;
        e.Write("One.md", "one");
        e.Write("Two.md", "two");
        Assert.True(recorder.Quiet(0.08));
        var batch = recorder.Wait(c => c.NotesChanged.Contains("One.md") && c.NotesChanged.Contains("Two.md"), offset);
        Assert.False(batch.NeedsFullSync);
        recorder.Drain();
        e.Write("Pending.md", "pending");
        watcher.Stop();
        Assert.False(watcher.IsRunning);
        Assert.False(watcher.HasPollingTimerForChecks);
        Assert.True(recorder.Quiet(0.4));
        watcher.Start();
        Assert.Equal(2, watcher.StreamGenerationForChecks);
        offset = recorder.Count;
        e.Write("Restart.md", "restart");
        recorder.Wait(c => c.NotesChanged.Contains("Restart.md"), offset);
        watcher.Stop();
        offset = recorder.Count;
        e.Write("AfterStop.md", "stopped");
        Assert.True(recorder.Quiet(0.35));
        Assert.Equal(offset, recorder.Count);
    }

    [Fact]
    public void WatcherFailedRootStartRequestsSyncAndAllowsExplicitRetry()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.05, recorder.Append);
        var fail = true;
        watcher.ConfigureWatchFallbackForChecks(64, 0.05, path => path == e.Vault.Root && fail);
        watcher.Start();
        Assert.False(watcher.IsRunning);
        Assert.False(watcher.HasPollingTimerForChecks);
        recorder.Wait(c => c.NeedsFullSync);
        Assert.Contains("vault-stream-unavailable", watcher.ReportedWatchIssuesForChecks);
        watcher.Start();
        Assert.True(recorder.Quiet(0.15));
        fail = false;
        watcher.Start();
        Assert.True(watcher.IsRunning);
        Assert.Equal(1, watcher.StreamGenerationForChecks);
        Assert.DoesNotContain("vault-stream-unavailable", watcher.ReportedWatchIssuesForChecks);
        e.Write("Retry.md", "retry");
        recorder.Wait(c => c.NotesChanged.Contains("Retry.md"));
    }

    [Fact]
    public void WatcherExternalExactPathsHandleAtomicReplacementMissingParentsAndSiblingNoise()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        var direct = e.Write("Direct.md", "direct", true);
        var deep = e.Write("Projects/Research/Science/Deep.md", "deep", true);
        var added = e.Write("Added/Folder/Added.md", "added", true);
        e.WriteRegistry(CheckVault.Json(new { version = 1, paths = new[] { "Direct.md", "Projects/Research/Science/Deep.md" } }));
        _ = e.Vault.ListNotes(); // Warm cache is deliberately stale at subscription.
        Registry(e, "Direct.md", "Projects/Research/Science/Deep.md", "Added/Folder/Added.md");
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.08, recorder.Append);
        watcher.Start();
        Assert.Equal(0, watcher.PollingFallbackCountForChecks);
        Assert.False(watcher.HasPollingTimerForChecks);
        foreach (var path in new[] { added, direct, deep })
        {
            var offset = recorder.Count;
            File.WriteAllText(path, "edited " + path);
            recorder.Wait(c => c.NotesChanged.Contains(e.Vault.NoteId(path)), offset);
        }
        var id = e.Vault.NoteId(deep);
        var start = recorder.Count;
        CheckVault.AtomicReplace(deep, "atomic replacement");
        recorder.Wait(c => c.NotesChanged.Contains(id), start);
        start = recorder.Count;
        File.Delete(deep);
        recorder.Wait(c => c.NotesChanged.Contains(id), start);
        start = recorder.Count;
        File.WriteAllText(deep, "recreated");
        recorder.Wait(c => c.NotesChanged.Contains(id), start);

        start = recorder.Count;
        Directory.Delete(Path.Combine(e.Home, "Projects"), true);
        recorder.Wait(c => c.NotesChanged.Contains(id), start);
        Eventually(() => watcher.ParentPathsForChecks.Contains(e.Home));
        foreach (var directory in new[] { "Projects", "Projects/Research", "Projects/Research/Science" })
        {
            var parent = Path.Combine(e.Home, directory.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(parent);
            Eventually(() => watcher.ParentPathsForChecks.Contains(parent));
            recorder.Drain();
        }
        start = recorder.Count;
        File.WriteAllText(deep, "parent tree recreated");
        recorder.Wait(c => c.NotesChanged.Contains(id), start);

        var immediate = Path.GetDirectoryName(deep)!;
        start = recorder.Count;
        Directory.Delete(immediate, true);
        Directory.CreateDirectory(immediate);
        recorder.Wait(c => c.NotesChanged.Contains(id), start);
        recorder.Drain();
        start = recorder.Count;
        File.WriteAllText(deep, "same-path parent recreated");
        recorder.Wait(c => c.NotesChanged.Contains(id), start);
        recorder.Drain();
        e.Write("Unregistered.md", "sibling", true);
        e.Write("Projects/Research/Science/Unregistered.md", "deep sibling", true);
        e.Write("Library/Caches/Level/Churn.data", "nested churn", true);
        Assert.True(recorder.Quiet(0.4));
        Assert.DoesNotContain(recorder.Changes, c => c.NotesChanged.Any(note => !note.StartsWith("file:", StringComparison.Ordinal)));
        Assert.False(watcher.HasPollingTimerForChecks);
    }

    [Fact]
    public void WatcherRegistryMembershipRefreshPreservesRootAndAddsLocalAndRemoteNotes()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        Directory.CreateDirectory(e.State);
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.06, recorder.Append);
        watcher.Start();
        var generation = watcher.StreamGenerationForChecks;
        var local = e.Write("Direct.md", "initial", true);
        e.Vault.ExternalNoteRegistry!.Register("Direct.md");
        watcher.RefreshExternalRoots();
        recorder.Wait(c => c.NeedsFullSync);
        recorder.Drain();
        watcher.RefreshExternalRoots();
        Assert.True(recorder.Quiet());
        var offset = recorder.Count;
        File.WriteAllText(local, "local edit");
        recorder.Wait(c => c.NotesChanged.Contains(e.Vault.NoteId(local)), offset);
        var remote = e.Write("Late/Note.md", "initial", true);
        offset = recorder.Count;
        Registry(e, "Direct.md", "Late/Note.md");
        recorder.Wait(c => c.NeedsFullSync, offset);
        offset = recorder.Count;
        File.WriteAllText(remote, "remote registration edit");
        recorder.Wait(c => c.NotesChanged.Contains(e.Vault.NoteId(remote)), offset);
        Assert.Equal(generation, watcher.StreamGenerationForChecks);
        recorder.Drain();
        Registry(e, "Direct.md", "Late/Note.md");
        Assert.True(recorder.Quiet(0.3));
        offset = recorder.Count;
        Registry(e, "Late/Note.md");
        recorder.Wait(c => c.NeedsFullSync, offset);
        recorder.Drain();
        File.WriteAllText(local, "unregistered now");
        Assert.True(recorder.Quiet(0.3));
        Assert.False(watcher.HasPollingTimerForChecks);
    }

    [Fact]
    public void WatcherRegistryErrorsFailClosedAreDeduplicatedAndRecoverIncludingSymlinks()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        var note = e.Write("Direct.md", "initial", true);
        e.WriteRegistry("{\"version\":1,\"paths\":[\"Direct.md\"]}");
        var id = e.Vault.NoteId(note);
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.06, recorder.Append);
        watcher.Start();
        recorder.Drain();
        var offset = recorder.Count;
        CheckVault.AtomicReplace(e.Registry, "{\"version\":2,\"paths\":[\"Direct.md\"]}");
        var warning = recorder.Wait(c => c.ExternalRegistryError == ExternalNoteRegistryError.UnsupportedVersion, offset);
        Assert.True(warning.NeedsFullSync);
        Assert.Equal(2, warning.ExternalRegistryErrorVersion);
        recorder.Drain();
        CheckVault.WriteAbsolute(Path.Combine(e.State, "session.json"), "unrelated");
        File.WriteAllText(note, "invalid registry must detach external watches");
        watcher.RefreshExternalRoots(); // The same damaged fingerprint emits no duplicate warning.
        Assert.True(recorder.Quiet(0.3));
        offset = recorder.Count;
        CheckVault.AtomicReplace(e.Registry, "{bad json");
        recorder.Wait(c => c.ExternalRegistryError == ExternalNoteRegistryError.MalformedRegistry, offset);
        offset = recorder.Count;
        Registry(e, "Direct.md");
        recorder.Wait(c => c.NeedsFullSync && c.ExternalRegistryRecovered, offset);
        offset = recorder.Count;
        File.WriteAllText(note, "recovered edit");
        recorder.Wait(c => c.NotesChanged.Contains(id), offset);

        var target = Path.Combine(e.Base, "registry-target.json");
        CheckVault.WriteAbsolute(target, "{\"version\":1,\"paths\":[\"Direct.md\"]}");
        offset = recorder.Count;
        File.Delete(e.Registry);
        CheckVault.SymbolicLink(e.Registry, target);
        recorder.Wait(c => c.NeedsFullSync && c.ExternalRegistryError == ExternalNoteRegistryError.UnreadableRegistry, offset);
        recorder.Drain();
        watcher.RefreshExternalRoots();
        CheckVault.WriteAbsolute(Path.Combine(e.State, "session.json"), "unrelated again");
        Assert.True(recorder.Quiet(0.3));
        offset = recorder.Count;
        File.Delete(e.Registry);
        recorder.Wait(c => c.NeedsFullSync && c.ExternalRegistryRecovered, offset);
        offset = recorder.Count;
        Registry(e, "Direct.md");
        recorder.Wait(c => c.NeedsFullSync, offset);
        offset = recorder.Count;
        File.WriteAllText(note, "restored after unsafe registry");
        recorder.Wait(c => c.NotesChanged.Contains(id), offset);
    }

    [Fact]
    public void WatcherParentCapSharesDirectoriesPollsExactFilesAndRecoversCapacity()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        e.Write("One/First.md", "first", true);
        e.Write("One/Sibling.md", "sibling", true);
        var polled = e.Write("Two/Second.md", "second", true);
        e.WriteRegistry("{\"version\":1,\"paths\":[\"One/First.md\",\"One/Sibling.md\",\"Two/Second.md\"]}");
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.06, recorder.Append);
        watcher.ConfigureWatchFallbackForChecks(1, 0.05);
        watcher.Start();
        Assert.Equal(2, watcher.ParentWatcherCountForChecks); // Registry + one shared external parent.
        Assert.Equal(1, watcher.PollingFallbackCountForChecks);
        Assert.True(watcher.HasPollingTimerForChecks);
        Assert.Contains("parent-watch-cap", watcher.ReportedWatchIssuesForChecks);
        recorder.Wait(c => c.NeedsFullSync);
        var id = e.Vault.NoteId(polled);
        var offset = recorder.Count;
        CheckVault.AtomicReplace(polled, "fallback edit");
        recorder.Wait(c => c.NotesChanged.Contains(id), offset);
        offset = recorder.Count;
        File.Delete(polled);
        recorder.Wait(c => c.NotesChanged.Contains(id), offset);
        offset = recorder.Count;
        File.WriteAllText(polled, "recreated via poll");
        recorder.Wait(c => c.NotesChanged.Contains(id), offset);
        recorder.Drain();
        e.Write("Two/Unregistered.md", "noise", true);
        Assert.True(recorder.Quiet(0.2));
        offset = recorder.Count;
        Registry(e, "Two/Second.md");
        recorder.Wait(c => c.NeedsFullSync, offset);
        Eventually(() => watcher.PollingFallbackCountForChecks == 0 && !watcher.HasPollingTimerForChecks);
        Assert.DoesNotContain("parent-watch-cap", watcher.ReportedWatchIssuesForChecks);
        offset = recorder.Count;
        File.WriteAllText(polled, "recovered native edit");
        recorder.Wait(c => c.NotesChanged.Contains(id), offset);
        recorder.Drain();
        Assert.True(recorder.Quiet(0.3));
    }

    [Fact]
    public void WatcherFailedExternalDirectoryCreationUsesOnlyExactPathFallback()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        var note = e.Write("Projects/Note.md", "initial", true);
        e.WriteRegistry("{\"version\":1,\"paths\":[\"Projects/Note.md\"]}");
        var parent = Path.GetDirectoryName(note)!;
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.05, recorder.Append);
        watcher.ConfigureWatchFallbackForChecks(64, 0.05, path => path == parent);
        watcher.Start();
        Assert.True(watcher.IsRunning);
        Assert.Equal(1, watcher.PollingFallbackCountForChecks);
        Assert.True(watcher.HasPollingTimerForChecks);
        recorder.Wait(c => c.NeedsFullSync);
        var offset = recorder.Count;
        File.WriteAllText(note, "fallback edit");
        recorder.Wait(c => c.NotesChanged.Contains(e.Vault.NoteId(note)), offset);
        recorder.Drain();
        e.Write("Projects/Sibling.md", "noise", true);
        Assert.True(recorder.Quiet(0.2));
        watcher.Stop();
        Assert.False(watcher.HasPollingTimerForChecks);
        File.WriteAllText(note, "after stop");
        Assert.True(recorder.Quiet(0.2));
    }

    [Fact]
    public void WatcherExternalSnapshotFailuresKeepRegistryValidAndRecoverWithoutIdlePolling()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        var note = e.Write("Projects/Note.md", "initial", true);
        var target = Path.Combine(e.Base, "Target.md");
        CheckVault.WriteAbsolute(target, "unsafe hard-linked note");
        File.Delete(note);
        CheckVault.HardLink(note, target);
        e.WriteRegistry("{\"version\":1,\"paths\":[\"Projects/Note.md\"]}");
        var id = e.Vault.NoteId(note);
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.05, recorder.Append);
        watcher.ConfigureWatchFallbackForChecks(64, 0.05);
        watcher.Start();
        var warning = recorder.Wait(c => c.NeedsFullSync);
        Assert.Null(warning.ExternalRegistryError);
        Assert.Contains("snapshot:" + id, watcher.ReportedWatchIssuesForChecks);
        Assert.Equal(1, watcher.PollingFallbackCountForChecks);
        var offset = recorder.Count;
        File.Delete(note);
        File.WriteAllText(note, "safe replacement");
        recorder.Wait(c => c.NotesChanged.Contains(id), offset);
        Eventually(() => !watcher.HasPollingTimerForChecks);
        Assert.DoesNotContain("snapshot:" + id, watcher.ReportedWatchIssuesForChecks);
        Assert.DoesNotContain(recorder.Changes, c => c.ExternalRegistryError is not null);
    }

    [Fact]
    public void WatcherOverflowRescansSnapshotForMissedWritesRenamesDeletesAndIdentityChanges()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var replaced = e.Write("Replaced.md", "same");
        var written = File.GetLastWriteTimeUtc(replaced);
        e.Write("Deleted.md", "deleted");
        var renamed = e.Write("Before.md", "renamed");
        e.Write("assets/deleted.png", "deleted image");
        Directory.CreateDirectory(e.Vault.UrlForRelativePath("assets/old-directory"));
        e.Write("Folder/Child.md", "child");
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.05, recorder.Append);
        watcher.Start();
        recorder.Drain();
        watcher.SetNativeEventsEnabledForChecks(false);
        var offset = recorder.Count;
        CheckVault.AtomicReplace(replaced, "size");
        File.SetLastWriteTimeUtc(replaced, written); // Same size + mtime, different identity/ctime.
        File.Delete(e.Vault.UrlForRelativePath("Deleted.md"));
        File.Move(renamed, e.Vault.UrlForRelativePath("After.md"));
        File.Delete(e.Vault.UrlForRelativePath("assets/deleted.png"));
        Directory.Delete(e.Vault.UrlForRelativePath("assets/old-directory"));
        Directory.Delete(e.Vault.UrlForRelativePath("Folder"), true);
        e.Write("New/Nested.md", "created without event delivery");
        e.Write("ASSETS/New.png", "new image");
        Directory.CreateDirectory(e.Vault.UrlForRelativePath("assets/new-directory"));
        e.Write("~$Ignored.md", "noise");
        Assert.True(recorder.Quiet(0.1));
        watcher.SimulateErrorForChecks();
        var batch = recorder.Wait(c => c.NotesChanged.Contains("Replaced.md"), offset);
        Assert.True(batch.NotesChanged.SetEquals(["Replaced.md", "Deleted.md", "Before.md", "After.md", "Folder/Child.md", "New/Nested.md"]));
        Assert.True(new HashSet<string>(batch.AssetsChanged, StringComparer.OrdinalIgnoreCase).SetEquals(
            ["assets/deleted.png", "ASSETS/New.png", "assets/old-directory", "assets/new-directory"]));
        Assert.True(batch.NeedsFullSync); // Deleted directory, as in Swift.
        Assert.False(watcher.HasPollingTimerForChecks); // One overflow does not degrade a live watch.
        recorder.Drain();
        offset = recorder.Count;
        watcher.SimulateErrorForChecks();
        var unchanged = recorder.Wait(c => c.NeedsFullSync, offset);
        Assert.Empty(unchanged.NotesChanged);
        Assert.Empty(unchanged.AssetsChanged);
    }

    [Fact]
    public void WatcherExternalOverflowDiffsExactSnapshotsAndRepeatedErrorsEnableFallback()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        var note = e.Write("Projects/Note.md", "initial", true);
        e.WriteRegistry("{\"version\":1,\"paths\":[\"Projects/Note.md\"]}");
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.05, recorder.Append);
        watcher.ConfigureWatchFallbackForChecks(64, 0.1);
        watcher.Start();
        recorder.Drain();
        watcher.SetNativeEventsEnabledForChecks(false);
        var offset = recorder.Count;
        File.WriteAllText(note, "missed edit");
        e.Write("Projects/Sibling.md", "ignored sibling", true);
        watcher.SimulateErrorForChecks(Path.GetDirectoryName(note));
        var batch = recorder.Wait(c => c.NotesChanged.Contains(e.Vault.NoteId(note)), offset);
        Assert.Single(batch.NotesChanged);
        Assert.False(batch.NeedsFullSync);
        Assert.False(watcher.HasPollingTimerForChecks);
        watcher.SimulateErrorForChecks(Path.GetDirectoryName(note));
        watcher.SimulateErrorForChecks(Path.GetDirectoryName(note));
        Assert.True(watcher.HasPollingTimerForChecks);
        Assert.Equal(1, watcher.PollingFallbackCountForChecks);
        recorder.Wait(c => c.NeedsFullSync, offset);
        offset = recorder.Count;
        File.WriteAllText(note, "edit after repeated errors");
        recorder.Wait(c => c.NotesChanged.Contains(e.Vault.NoteId(note)), offset);
    }

    [Fact]
    public void WatcherRootRepeatedErrorsPollUntilNativeCoverageRecovers()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.05, recorder.Append);
        watcher.ConfigureWatchFallbackForChecks(64, 0.1);
        watcher.Start();
        recorder.Drain();
        watcher.SetNativeEventsEnabledForChecks(false);
        watcher.SimulateErrorForChecks();
        watcher.SimulateErrorForChecks();
        watcher.SimulateErrorForChecks();
        Assert.True(watcher.IsRunning);
        Assert.True(watcher.HasPollingTimerForChecks);
        var offset = recorder.Count;
        e.Write("Fallback.md", "written without a native watcher");
        recorder.Wait(c => c.NotesChanged.Contains("Fallback.md"), offset);
        recorder.Wait(c => c.NeedsFullSync);
        Eventually(() => !watcher.HasPollingTimerForChecks);
        Assert.DoesNotContain("watch-unavailable:" + e.Vault.Root, watcher.ReportedWatchIssuesForChecks);
        offset = recorder.Count;
        e.Write("Recovered.md", "written with native coverage restored");
        recorder.Wait(c => c.NotesChanged.Contains("Recovered.md"), offset);
        Assert.Equal(1, watcher.StreamGenerationForChecks);
    }

    [Fact]
    public void WatcherNotifyEnumDirErrorRescansAndRecreatesNativeWatch()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.05, recorder.Append);
        watcher.Start();
        recorder.Drain();
        watcher.SetNativeEventsEnabledForChecks(false);
        var offset = recorder.Count;
        e.Write("Missed.md", "missed notification");
        watcher.SimulateErrorForChecks(error: new System.ComponentModel.Win32Exception(1022)); // ERROR_NOTIFY_ENUM_DIR
        var batch = recorder.Wait(c => c.NotesChanged.Contains("Missed.md"), offset);
        Assert.True(batch.NeedsFullSync);
        Assert.False(watcher.HasPollingTimerForChecks);
        offset = recorder.Count;
        e.Write("NativeAgain.md", "native watcher recreated");
        recorder.Wait(c => c.NotesChanged.Contains("NativeAgain.md"), offset);
    }

    [Fact]
    public void WatcherVaultRootReplacementRequestsFullSyncEvenWithoutFileDifferences()
    {
        using var e = new CheckVault();
        Directory.CreateDirectory(e.Vault.Root);
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.05, recorder.Append);
        watcher.Start();
        recorder.Drain();
        watcher.SetNativeEventsEnabledForChecks(false);
        var offset = recorder.Count;
        Directory.Move(e.Vault.Root, Path.Combine(e.Base, "OldVault"));
        Directory.CreateDirectory(e.Vault.Root);
        watcher.SimulateErrorForChecks();
        var batch = recorder.Wait(c => c.NeedsFullSync, offset);
        Assert.Empty(batch.NotesChanged);
        Assert.Empty(batch.AssetsChanged);
    }

    [UnixFact]
    public void WatcherSnapshotRescansDoNotOpenContentOrFollowLinks()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var pipe = e.Vault.UrlForRelativePath("Pipe.md");
        CheckVault.Fifo(pipe); // Opening for content would block indefinitely.
        var outside = Path.Combine(e.Base, "Outside");
        Directory.CreateDirectory(outside);
        CheckVault.WriteAbsolute(Path.Combine(outside, "Hidden.md"), "outside");
        CheckVault.SymbolicLink(e.Vault.UrlForRelativePath("Linked"), outside, true);
        var recorder = new Recorder();
        using var watcher = new VaultWatcher(e.Vault, 0.05, recorder.Append);
        watcher.Start();
        recorder.Drain();
        watcher.SetNativeEventsEnabledForChecks(false);
        e.Write("Visible.md", "visible");
        watcher.SimulateErrorForChecks();
        var change = recorder.Wait(c => c.NotesChanged.Contains("Visible.md"));
        Assert.Single(change.NotesChanged);
        Assert.True(change.NeedsFullSync);
    }

    [Theory]
    [InlineData((int)FileAttributes.Offline)]
    [InlineData(0x400000)]
    [InlineData(0x40000)]
    [InlineData(0x400400)]
    public void WatcherRecognizesEveryOnlineOnlyPlaceholderFlag(int attributes)
    {
        Assert.True(WatchSnapshot.IsOnlineOnly((FileAttributes)attributes));
        Assert.False(WatchSnapshot.IsOnlineOnly(FileAttributes.Normal));
        Assert.False(WatchSnapshot.IsOnlineOnly(FileAttributes.ReparsePoint));
    }
}
