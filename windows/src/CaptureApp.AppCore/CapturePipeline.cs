using System.Globalization;
using System.Text;
using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.AppCore;

public enum CaptureTrigger
{
    Selection,
    Region
}

public sealed record PendingCapture(Guid Id, DateTimeOffset CreatedAt, CaptureTrigger Trigger, CaptureContent Content,
    CaptureSource Source, string Subtitle, byte[]? Png = null, string? Ocr = null);

/// Platform-neutral capture orchestration over Core's vault, writer, session, index, and watcher.
public sealed class CapturePipeline : IDisposable
{
    private readonly TimeProvider clock;
    private readonly AppLog logger;
    private bool disposed;

    public Vault Vault { get; }
    public SessionStore Sessions { get; }
    public CaptureService Service { get; }
    public SearchIndex Index { get; }
    public VaultMonitor Monitor { get; }
    public CaptureJournal Journal { get; }
    public NoteDraftStore Drafts { get; }
    public NotePinStore Pins { get; }
    public TimeZoneInfo TimeZone { get; }
    public string StateDirectory { get; }
    public string? ModelsDirectory { get; }

    private CapturePipeline(Vault vault, SessionStore sessions, CaptureService service, SearchIndex index,
        VaultMonitor monitor, CaptureJournal journal, NoteDraftStore drafts, NotePinStore pins,
        TimeZoneInfo timeZone, string stateDirectory, string? modelsDirectory, TimeProvider clock)
    {
        Vault = vault;
        Sessions = sessions;
        Service = service;
        Index = index;
        Monitor = monitor;
        Journal = journal;
        Drafts = drafts;
        Pins = pins;
        TimeZone = timeZone;
        StateDirectory = stateDirectory;
        ModelsDirectory = modelsDirectory;
        this.clock = clock;
        logger = new(stateDirectory, "pipeline");
    }

    public static CapturePipeline Open(string vaultRoot, string stateDirectory, TimeZoneInfo? timeZone = null,
        string? modelsDirectory = null, double watcherLatencySeconds = 1.0, TimeProvider? timeProvider = null,
        string? homeDirectory = null)
    {
        var state = Path.GetFullPath(stateDirectory);
        Directory.CreateDirectory(state);
        var zone = timeZone ?? TimeZoneInfo.Local;
        var clock = timeProvider ?? TimeProvider.System;
        var vault = new Vault(vaultRoot, Path.Combine(state, "external-notes.json"), homeDirectory);
        vault.Prepare();
        var index = new SearchIndex(vault, Path.Combine(state, "index.sqlite"), zone);
        var sessions = new SessionStore(state, vault, zone, clock);
        var writer = new NoteWriter(vault, zone, clock);
        var service = new CaptureService(vault, sessions, writer, clock);
        var monitor = new VaultMonitor(vault, index, state, watcherLatencySeconds);
        return new(vault, sessions, service, index, monitor, new(state), new(state), new(state), zone,
            state, modelsDirectory is null ? null : Path.GetFullPath(modelsDirectory), clock);
    }

    public CaptureJob PrepareText(string text, CaptureSource source, string? noteTitle = null, string? noteDraft = null,
        Guid? id = null, DateTimeOffset? createdAt = null)
    {
        ThrowIfDisposed();
        var capture = new Capture(id ?? Guid.NewGuid(), createdAt ?? clock.GetUtcNow(), CaptureContent.Text(text), source);
        return new(Service.Prepare(capture, noteTitle), NoteDraft: noteDraft);
    }

    public CaptureJob PrepareImage(byte[] png, CaptureSource source, string? noteTitle = null, string? ocr = null,
        Guid? id = null, DateTimeOffset? createdAt = null)
    {
        ThrowIfDisposed();
        var captureId = id ?? Guid.NewGuid();
        var created = createdAt ?? clock.GetUtcNow();
        var stamp = CaptureFormat.LocalStamp(created, "yyyy-MM-dd-HHmmss", TimeZone);
        var asset = $"{Vault.AssetsDirectoryName}/{stamp}-{captureId.ToString("D").ToLowerInvariant()}.png";
        var capture = new Capture(captureId, created, CaptureContent.Image(asset), source);
        return new(Service.Prepare(capture, noteTitle), png, ocr);
    }

    public CaptureJob PrepareNote(string markdown, CaptureSource source, Destination? destination = null,
        string? noteDraft = null, Guid? id = null, DateTimeOffset? createdAt = null, bool newNote = false)
    {
        ThrowIfDisposed();
        var capture = new Capture(id ?? Guid.NewGuid(), createdAt ?? clock.GetUtcNow(), CaptureContent.Note(markdown), source);
        return new(Service.PrepareNote(capture, TimeZone, destination, newNote), NoteDraft: noteDraft ?? markdown);
    }

    public void Stage(CaptureJob job)
    {
        ThrowIfDisposed();
        Journal.Store(job);
    }

    /// <param name="onNoteSaved">Called for typed notes with whether the pin intent failed (the Mac's showNoteSaveFeedback).</param>
    public SavedCapture Commit(CaptureJob job, bool? pinOnSave = null, Action<SavedCapture, bool>? onNoteSaved = null)
    {
        ThrowIfDisposed();
        Journal.Store(job);
        var saved = Service.Save(job.Prepared, job.Png);
        Monitor.RefreshExternalRoots();
        try
        {
            Index.Reindex(saved.Destination.Url);
            // Journaled OCR text reaches the cache here, including on replay.
            if (job.Ocr is { } ocr && job.Png is { } png && Index.Capture(saved.CaptureId)?.AssetPath is { } asset)
            {
                Index.SetImageText(asset, ocr, SearchIndex.ImageFingerprint(png));
            }
        }
        catch (Exception error)
        {
            // Startup index sync repairs a cache miss; it must not append an already-saved capture again.
            logger.Error($"Capture saved but its index update failed: {error}");
        }

        var pinFailed = false;
        var isNote = job.Prepared.Capture.Content.Kind == CaptureContentKind.Note;
        if (isNote)
        {
            Drafts.CompleteSave(job.NoteDraft ?? job.Prepared.Capture.Content.Value, pinOnSave, intent =>
            {
                if (!intent) { return; }
                try
                {
                    Pins.Set(Vault.NoteId(saved.Destination.Url), true);
                }
                catch (Exception error)
                {
                    pinFailed = true;
                    logger.Error($"Note was saved but could not be pinned: {error}");
                }
            });
        }

        Journal.Remove(saved.CaptureId);
        if (isNote) { onNoteSaved?.Invoke(saved, pinFailed); }
        return saved;
    }

    public async Task<int> ReplayUnsavedAsync(CancellationToken cancellationToken = default,
        Action<SavedCapture, bool>? onNoteSaved = null)
    {
        ThrowIfDisposed();
        var restored = 0;
        IReadOnlyList<string> records;
        try { records = Journal.RecordPaths(); }
        catch (Exception error)
        {
            logger.Error($"Journal enumeration failed: {error}");
            return 0;
        }

        foreach (var path in records)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var job = Journal.Load(path);
                // Persist OCR recovery or other normalized payload before attempting the append.
                Journal.Store(job);
                _ = Commit(job, null, onNoteSaved);
                restored++;
            }
            catch (CaptureJournal.RecordException error)
            {
                logger.Error($"Journal replay found a corrupt record {Path.GetFileName(path)}: {error.Message}");
                try { Journal.Quarantine(path); }
                catch (Exception quarantineError) { logger.Error($"Journal quarantine failed: {quarantineError}"); }
            }
            catch (Exception error)
            {
                logger.Error($"Journal replay failed for {Path.GetFileName(path)}: {error}");
            }

            await Task.Yield();
        }

        logger.Notice($"Journal replay restored {restored} capture(s).");
        return restored;
    }

    public void StartWatcher() => Monitor.Start();
    public Task SyncAsync() => Monitor.SyncAsync();
    public Task BackfillAsync() => Monitor.BackfillAsync();

    public byte[] AssetData(string assetPath)
    {
        var snapshot = Vault.FileSnapshot(assetPath);
        return snapshot?.Contents ?? throw new FileNotFoundException("The vault asset was not found.", assetPath);
    }

    public string AssetUrl(string assetPath)
    {
        _ = Vault.FileSnapshot(assetPath, includingContents: false)
            ?? throw new FileNotFoundException("The vault asset was not found.", assetPath);
        return Vault.UrlForRelativePath(assetPath);
    }

    public async Task StopWatcherAsync() => await Monitor.StopAsync().ConfigureAwait(false);

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(disposed, this);

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        Monitor.Dispose();
        Drafts.Dispose();
        Index.Dispose();
    }
}
