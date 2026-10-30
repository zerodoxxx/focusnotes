using CaptureApp.AppCore.Semantic;
using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.AppCore.Shell;

/// Title picker values by suggestion, and the exact note each value stands for.
public sealed class TitlePicks
{
    private readonly Dictionary<string, string> values = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Destination> destinations = new(StringComparer.Ordinal);

    internal void Add(NoteSuggestion suggestion, string value, Destination destination)
    {
        values[suggestion.Path] = value;
        destinations[value] = destination;
    }

    /// The value to submit for a suggestion, or null when its bare title already routes to it.
    public string? ValueOf(NoteSuggestion suggestion) => values.GetValueOrDefault(suggestion.Path);

    /// The note a submitted value was offered for; null for typed text, which is routed by title.
    public Destination? DestinationOf(string value) => destinations.GetValueOrDefault(value);
}

/// The UI-free half of AppController.swift: staging, ordered commits, journaling, notes, sessions and the
/// shutdown drain. The App's controller owns panels, tray and hotkeys and calls into this class.
public sealed class CaptureCoordinator
{
    private readonly object gate = new();
    private readonly ICaptureHost host;
    private readonly AppLog log;
    private readonly Dictionary<Guid, Task<string?>> deferredOcr = [];
    private readonly HashSet<string> reportedRegistryWarnings = new(StringComparer.Ordinal);
    private PendingCapture? pending;
    private Guid? pendingToastId;
    // A titled commit that failed in preparation keeps the capture pending but off implicit commits (AppController.swift pendingNeedsRetryChoice).
    private bool pendingNeedsRetryChoice;
    private bool retryWarningShown;
    private Guid? stagedId;
    private Task? commitMonitor;
    private Task? acquisitionTask;
    private int acquisitionGeneration;
    private PendingCapture? acquisitionFallback;
    private Task? processingTail;
    private int processingGeneration;
    private Task? actionTail;
    private int actionGeneration;
    private Task? startupReplayTask;
    private bool acquisitionInProgress;
    private bool isTerminating;
    private bool shutdownFinished;
    private Task<bool>? shutdownTask;

    // Lets the controller self-test hold the narrow handoff between acquisition and queue registration.
    internal Func<PendingCapture, Task>? BeforeProcessingTailRegistrationForSelfTest { get; set; }

    public CaptureCoordinator(CapturePipeline pipeline, ICaptureHost host)
    {
        Pipeline = pipeline;
        this.host = host;
        log = new(pipeline.StateDirectory, "controller");
    }

    public CapturePipeline Pipeline { get; }
    public SemanticIndexer? Semantic { get; set; }
    public Action<Guid>? ChooseNoteRequested { get; set; }
    public Session? ActiveSession { get; private set; }
    public bool IsTerminating { get { lock (gate) { return isTerminating; } } }
    public bool AcquisitionInProgress { get { lock (gate) { return acquisitionInProgress; } } }
    public PendingCapture? Pending { get { lock (gate) { return pending; } } }
    public bool HasPendingToast { get { lock (gate) { return pending is not null && pendingToastId == pending.Id; } } }
    public PendingCapture? PendingWithToast { get { lock (gate) { return pending is not null && pendingToastId == pending.Id ? pending : null; } } }
    public PendingCapture? PendingWithRetryWarning { get { lock (gate) { return pending is not null && pendingNeedsRetryChoice && retryWarningShown ? pending : null; } } }
    internal Task? CommitTail => Pipeline.Unsaved.Tail;

    /// Replays the journal, then loads the active session. Returns how many captures were restored.
    public async Task<int> StartAsync()
    {
        var replay = Task.Run(() => Pipeline.ReplayUnsavedAsync(default, (saved, pinFailed) => NoteFeedback(saved, pinFailed)));
        lock (gate) { startupReplayTask = replay; }
        var restored = await replay.ConfigureAwait(false);
        lock (gate) { startupReplayTask = null; }
        try { ActiveSession = Pipeline.Sessions.Current(); }
        catch (Exception error) { log.Error($"Session state could not be read: {error.GetType().Name}"); }
        return restored;
    }

    // Action queue: UI commands run in order, while their context was snapshotted at hotkey/menu entry.
    public void Enqueue(Func<CaptureCoordinator, Task> action)
    {
        Task? previous;
        int generation;
        lock (gate)
        {
            if (isTerminating) { return; }
            previous = actionTail;
            generation = ++actionGeneration;
        }

        var tail = RunActionAsync(previous, action, generation);
        lock (gate) { if (actionGeneration == generation && !tail.IsCompleted) { actionTail = tail; } }
    }

    private async Task RunActionAsync(Task? previous, Func<CaptureCoordinator, Task> action, int generation)
    {
        await TryWait(previous).ConfigureAwait(true);
        if (IsTerminating) { return; }
        try { await action(this).ConfigureAwait(true); }
        catch (Exception error) { log.Error($"Queued action failed: {error}"); }
        lock (gate) { if (actionGeneration == generation) { actionTail = null; } }
    }

    // Acquisition.
    public bool BeginAcquisition(Func<Task<PendingCapture?>> operation, Func<PendingCapture, Task<PendingCapture>>? postprocess = null)
    {
        int generation;
        lock (gate)
        {
            if (isTerminating || acquisitionInProgress) { return false; }
            acquisitionInProgress = true;
            generation = ++acquisitionGeneration;
        }

        var task = RunAcquisitionAsync(operation, postprocess, generation);
        lock (gate) { if (acquisitionGeneration == generation && acquisitionInProgress) { acquisitionTask = task; } }
        return true;
    }

    private async Task RunAcquisitionAsync(Func<Task<PendingCapture?>> operation, Func<PendingCapture, Task<PendingCapture>>? postprocess, int generation)
    {
        await Task.Yield();
        PendingCapture? result = null;
        try { result = await operation().ConfigureAwait(true); }
        catch (Exception error) { log.Error($"Acquisition failed: {error}"); }
        try
        {
            lock (gate)
            {
                if (acquisitionGeneration != generation || shutdownFinished) { return; }
                if (result is null)
                {
                    acquisitionFallback = null;
                    acquisitionInProgress = false;
                    acquisitionTask = null;
                    return;
                }

                // This only schedules journal work; it does not perform disk I/O under the gate.
                // Keeping the validity check and scheduling together prevents shutdown from invalidating
                // this generation between the check and journal registration.
                JournalAcquisition(result);
            }

            // Keep acquisition single-flight until the acquired capture has been appended to processingTail
            // so a later capture cannot overtake it. Post-processing runs outside the coordinator gate.
            var acquired = result;
            var processed = Task.Run(async () => postprocess is null ? acquired : await postprocess(acquired).ConfigureAwait(false));
            if (BeforeProcessingTailRegistrationForSelfTest is { } barrier)
            {
                await barrier(acquired).ConfigureAwait(false);
            }

            lock (gate)
            {
                if (acquisitionGeneration != generation || shutdownFinished) { return; }
                acquisitionFallback = null;
                var previous = processingTail;
                var id = ++processingGeneration;
                var tail = ProcessAsync(previous, processed, acquired, id);
                if (!tail.IsCompleted) { processingTail = tail; }
                acquisitionInProgress = false;
                acquisitionTask = null;
            }
        }
        catch (Exception error)
        {
            log.Error($"Acquisition handoff failed: {error}");
            FinishAcquisition(generation);
        }
    }

    private void FinishAcquisition(int generation)
    {
        lock (gate)
        {
            if (acquisitionGeneration != generation || shutdownFinished) { return; }
            acquisitionInProgress = false;
            acquisitionTask = null;
        }
    }

    private async Task ProcessAsync(Task? previous, Task<PendingCapture> processed, PendingCapture fallback, int id)
    {
        await TryWait(previous).ConfigureAwait(true);
        var capture = fallback;
        try { capture = await processed.ConfigureAwait(true); }
        catch (Exception error) { log.Error($"Capture post-processing failed; keeping the acquired capture: {error.GetType().Name}"); }
        await StageAsync(capture with { OutsideSession = fallback.OutsideSession }).ConfigureAwait(true);
        lock (gate) { if (processingGeneration == id) { processingTail = null; } }
    }

    /// Pixels the pipeline already owns are journaled if the app quits while OCR is still running.
    public void RecordAcquiredImage(PendingCapture capture)
    {
        bool terminating;
        lock (gate)
        {
            acquisitionFallback = capture;
            terminating = isTerminating;
        }

        if (terminating) { JournalAcquisition(capture); }
    }

    public void RegisterDeferredOcr(Guid id, Task<string?> task)
    {
        lock (gate) { deferredOcr[id] = task; }
    }

    private void JournalAcquisition(PendingCapture capture)
    {
        lock (gate)
        {
            if (Pipeline.Unsaved.IsRecorded(capture.Id)) { return; }
            _ = Pipeline.Unsaved.Record(capture.Id, _ => Prepare(capture, null, null));
        }
    }

    private CaptureJob Prepare(PendingCapture capture, string? noteTitle, Destination? destination)
    {
        // Resolve the outside fallback before preparation: title matching can pick
        // another Inbox, and preparing then overriding still performs routing work.
        if (destination is null && noteTitle is null && capture.OutsideSession)
            destination = new(Pipeline.Vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox);
        return capture.Png is not null
            ? Pipeline.PrepareImage(capture.Png, capture.Source, noteTitle, capture.Ocr, capture.Id, capture.CreatedAt, destination)
            : Pipeline.PrepareText(capture.Content.Value, capture.Source, noteTitle, null, capture.Id, capture.CreatedAt, destination);
    }

    // Staging and commit.
    public async Task StageAsync(PendingCapture capture)
    {
        lock (gate) { if (shutdownFinished) { return; } }
        _ = CommitPending();
        var previousNotice = await SaveRetryPendingAsync().ConfigureAwait(true);
        // The staged default keeps the acquisition record's destination.
        var persistence = Pipeline.Unsaved.Record(capture.Id, recovered => Prepare(capture, null, recovered?.Prepared.Destination));
        lock (gate)
        {
            stagedId = capture.Id;
            pending = capture;
            // The new capture starts unheld: a failed titled commit may have restored an earlier one since the check above.
            pendingNeedsRetryChoice = false;
            retryWarningShown = false;
        }

        // Persist the default job before showing the toast or accepting a note title.
        try { await persistence.ConfigureAwait(true); }
        catch (Exception error) { Report(error, Strings.CouldNotJournal); }
        bool stillPending;
        bool terminating;
        lock (gate)
        {
            stillPending = pending?.Id == capture.Id;
            terminating = isTerminating;
        }

        if (!stillPending) { return; }
        if (terminating) { _ = CommitPending(); return; }
        if (capture.OutsideSession)
        {
            ChooseNoteRequested?.Invoke(capture.Id);
            // The picker dismisses toasts as it opens, so the notice only reaches the log here.
            if (previousNotice is not null) { log.Notice(previousNotice); }
            return;
        }
        Session? session = null;
        try { session = Pipeline.Sessions.Current(); } catch (Exception error) { log.Error($"Session read failed: {error.GetType().Name}"); }
        lock (gate)
        {
            if (!host.PresentsUi || pending?.Id != capture.Id || isTerminating) { return; }
            pendingToastId = capture.Id;
        }

        // Fold the notice into this toast so it cannot hide it.
        var subtitle = string.Join(" · ", new[] { capture.Subtitle, previousNotice }.Where(part => !string.IsNullOrEmpty(part)));
        host.ShowStagedToast(new(AppToastStyle.Success, session is null ? Strings.SavedTo(Vault.InboxTitle) : Strings.AddedTo(session.Name),
            subtitle, host.BindingFor(capture.Trigger), Strings.ChooseNoteHint));
    }

    /// A newer capture saves a retry-pending one to its staged default, then says so.
    private async Task<string?> SaveRetryPendingAsync()
    {
        PendingCapture? held;
        bool heldStaged;
        lock (gate)
        {
            held = pendingNeedsRetryChoice ? pending : null;
            heldStaged = held is not null && stagedId == held.Id;
        }

        if (held is null) { return null; }
        var destination = !heldStaged ? null : (await Pipeline.Unsaved.RecordedAsync(held.Id).ConfigureAwait(true))?.Prepared.Destination;
        bool stillHeld;
        lock (gate) { stillHeld = pendingNeedsRetryChoice && pending?.Id == held.Id; }
        if (!stillHeld || CommitPending(force: true) is not { } commit) { return null; }
        // Finish the held capture, including its failure handling, before the newer one is staged.
        var succeeded = await TryResult(commit).ConfigureAwait(true) is not null;
        Task? monitor;
        lock (gate) { monitor = commitMonitor; }
        await TryWait(monitor).ConfigureAwait(true);
        return succeeded ? Strings.PreviousCaptureSaved(destination?.Title) : Strings.PreviousCaptureNotSaved;
    }

    /// The staged toast expired: the default destination is the answer. A retry-pending capture only loses its warning.
    public void ToastExpired()
    {
        bool commit;
        bool warningGone;
        lock (gate)
        {
            commit = pending is not null && pendingToastId == pending.Id;
            warningGone = retryWarningShown;
            retryWarningShown = false;
        }

        if (commit) { _ = CommitPending(); }
        else if (warningGone) { host.DismissStagedToast(); }
    }

    /// Hotkey re-press on the staged toast: stop the toast and choose a destination.
    public void ClearToastMarker()
    {
        lock (gate) { pendingToastId = null; }
        host.DismissStagedToast();
    }

    /// Implicit commits (drain, toast, rename, draft save) skip a retry-pending capture; only an explicit title or
    /// destination, shutdown, or a newer capture staged in <see cref="StageAsync"/> (force) may save it. A picked
    /// destination is saved without routing, if its note still exists.
    public Task<SavedCapture>? CommitPending(string? noteTitle = null, bool announce = false, bool force = false, Destination? destination = null)
    {
        PendingCapture capture;
        bool wasStaged;
        bool terminating;
        lock (gate)
        {
            if (pending is null) { return null; }
            if (pendingNeedsRetryChoice && !force && noteTitle is null && destination is null && !isTerminating) { return null; }
            capture = pending;
            pending = null;
            pendingToastId = null;
            pendingNeedsRetryChoice = false;
            retryWarningShown = false;
            wasStaged = stagedId == capture.Id;
            stagedId = null;
            terminating = isTerminating;
        }

        if (host.PresentsUi) { host.DismissStagedToast(); }
        // Only shutdown forces the recorded destination (the acquired-pixel fallback, shared by the staged default).
        var preparation = Task.Run(async () =>
        {
            Destination? resolved;
            if (terminating && await Pipeline.Unsaved.RecordedAsync(capture.Id).ConfigureAwait(false) is { } recorded) { resolved = recorded.Prepared.Destination; }
            else if (destination is not null)
            {
                // A note removed since the picker opened fails here and keeps the capture.
                resolved = destination with { Url = Pipeline.Vault.NoteLocation(Pipeline.Vault.NoteId(destination.Url)).Url };
            }
            else if (noteTitle is null && wasStaged) { resolved = (await Pipeline.Unsaved.RecordedAsync(capture.Id).ConfigureAwait(false))?.Prepared.Destination; }
            else { resolved = null; }
            return Prepare(capture, noteTitle, resolved);
        });
        var task = Pipeline.Unsaved.Commit(capture.Id, preparation, job => CommitJob(job, null));
        var monitor = ObserveCommitAsync(task, preparation, capture, wasStaged, noteTitle is not null || destination is not null, announce);
        lock (gate) { commitMonitor = monitor; }
        return task;
    }

    private async Task ObserveCommitAsync(Task<SavedCapture> task, Task<CaptureJob> preparation, PendingCapture capture,
        bool wasStaged, bool explicitTarget, bool announce)
    {
        try
        {
            var saved = await task.ConfigureAwait(false);
            bool noPending;
            lock (gate) { noPending = pending is null; }

            if (announce && noPending)
            {
                host.ShowToast(new(AppToastStyle.Success, capture.OutsideSession
                    ? Strings.SessionStillActive(Strings.AddedTo(saved.Destination.Title), Pipeline.Sessions.Current()?.Name)
                    : Strings.SavedTo(saved.Destination.Title), Duration: 1.6));
            }
        }
        catch (Exception error)
        {
            if (explicitTarget && preparation.IsFaulted && wasStaged)
            {
                // The capture is not lost: keep it pending for another note, or leave it to recovery if a newer one took its place.
                bool held;
                lock (gate)
                {
                    held = pending is null;
                    if (held)
                    {
                        stagedId = capture.Id;
                        pending = capture;
                        pendingToastId = null;
                        pendingNeedsRetryChoice = true;
                        Pipeline.Unsaved.Forget(capture.Id);
                    }
                    else { Pipeline.Unsaved.Keep(capture.Id); }
                }

                if (held)
                {
                    log.Error($"{Strings.CouldNotSaveCapture} ({error.GetType().Name}): {error}");
                    // A commit that failed during quit restored the hold after the drain's last implicit commit: save it to its default now.
                    if (IsTerminating) { _ = CommitPending(); }
                    else if (error is RouterAmbiguousException ambiguous) { ShowRetryChoice(capture, Strings.SeveralNotesTitled(ambiguous.Candidates[0].Title), true); }
                    else { ShowRetryChoice(capture, Strings.CouldNotSaveToNote); }
                }
                else
                {
                    var fallback = (await Pipeline.Unsaved.RecordedAsync(capture.Id).ConfigureAwait(false))?.Prepared.Destination;
                    host.ShowToast(new(AppToastStyle.Warning, Strings.CouldNotSavePreviousCapture, Strings.RecoveryWillRetry(fallback?.Title)));
                }
            }
            else { ReportUserSaveFailure(error, Strings.CouldNotSaveCapture); }
        }
    }

    private SavedCapture CommitJob(CaptureJob job, bool? pinOnSave, string? noteText = null, bool outsideSession = false)
    {
        var saved = Pipeline.Commit(job, pinOnSave, (value, pinFailed) =>
            NoteFeedback(value, pinFailed, job.Prepared.CreatesNote == true, noteText, outsideSession));
        Task<string?>? deferred;
        lock (gate) { deferredOcr.Remove(job.Prepared.Capture.Id, out deferred); }
        if (deferred is not null && job.Png is { } png && job.Prepared.Capture.Content is { Kind: CaptureContentKind.Image } image)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    // Missing text stays eligible for the asset backfill.
                    if (await deferred.ConfigureAwait(false) is not { } text) { return; }
                    Pipeline.Index.SetImageText(image.Value, text, SearchIndex.ImageFingerprint(png));
                    Semantic?.Schedule();
                }
                catch (Exception error) { log.Error($"Deferred OCR cache update failed: {error.GetType().Name}"); }
            });
        }

        Semantic?.Schedule();
        return saved;
    }

    private void NoteFeedback(SavedCapture saved, bool pinFailed, bool? created = null, string? text = null, bool outsideSession = false)
    {
        if (pinFailed)
        {
            ShowToast(new(AppToastStyle.Warning, Strings.NoteNotPinned, saved.Destination.Title));
        }
        else if (outsideSession)
        {
            ShowToast(new(AppToastStyle.Success, Strings.SessionStillActive(Strings.SavedTo(saved.Destination.Title), Pipeline.Sessions.Current()?.Name)));
        }
        else if (created is false && text is not null && saved.Destination.Kind == NoteKind.Session)
        {
            ShowToast(new(AppToastStyle.Success, Strings.SavedTo(saved.Destination.Title), PendingCaptures.FirstLine(text)));
        }
        else if (created is { } made && text is not null)
        {
            ShowToast(new(AppToastStyle.Success, Strings.NoteCreatedOrAdded(made),
                made ? saved.Destination.Title : PendingCaptures.FirstLine(text)));
        }
    }

    /// Settles in-flight captures (acquisition, processing, then commits) so each is saved in the session it was taken in.
    /// Commit failures are reported by the commits themselves. Never call it from inside an acquisition: that would wait on itself.
    public async Task SettleCapturesAsync()
    {
        await WaitForAcquisitionAsync().ConfigureAwait(false);
        _ = CommitPending();
        await WaitForProcessingAsync().ConfigureAwait(false);
        _ = CommitPending();
        await WaitForCommitsAsync().ConfigureAwait(false);
    }

    /// Waits for an in-flight acquisition to hand its capture to the processing queue (drainCaptures).
    internal Task WaitForAcquisitionAsync() { Task? task; lock (gate) { task = acquisitionTask; } return TryWait(task); }

    internal Task WaitForProcessingAsync() { Task? tail; lock (gate) { tail = processingTail; } return TryWait(tail); }

    internal Task WaitForCommitsAsync() => Pipeline.Unsaved.WaitForCommitsAsync();

    // Notes and subheadings.
    public async Task<SavedCapture?> AddNoteAsync(string rawText, Destination? destination = null, bool pinOnSave = false,
        bool newNote = false, bool outsideSession = false, NoteFolder? folder = null)
    {
        if (IsTerminating) { return null; }
        Pipeline.Drafts.Store(rawText, pinOnSave, folder: folder);
        var text = CaptureFormat.NoteBody(rawText);
        if (string.IsNullOrWhiteSpace(text)) { return null; }
        await SettleCapturesAsync().ConfigureAwait(false);

        // A failed note with the same body is retried under its id; the same body with other options supersedes it.
        bool SameText(CaptureJob job) => job.NoteDraft is { } draft
            ? CaptureFormat.NoteBody(draft) == text
            : job.Prepared.Capture.Content == CaptureContent.Note(text);
        bool SameOptions(CaptureJob job) => job.NoteOutsideSession == outsideSession && job.NoteFolder == folder &&
            (destination is null || job.Prepared.Destination == destination) && (!newNote || job.Prepared.CreatesNote == true);
        var job = await Pipeline.Unsaved.FindRetryAsync(kept => SameText(kept) && SameOptions(kept), kept => SameText(kept) && !SameOptions(kept)).ConfigureAwait(false)
            ?? await Task.Run(() => Pipeline.PrepareNote(text, new CaptureSource(), destination, rawText, newNote: newNote, outsideSession: outsideSession, folder: folder)).ConfigureAwait(false);
        return await Pipeline.Unsaved.Commit(job.Prepared.Capture.Id, Task.FromResult(job), prepared => CommitJob(prepared, pinOnSave, text, outsideSession)).ConfigureAwait(false);
    }

    public async Task<SavedCapture?> AddSubheadingAsync(string rawText, Destination? destination = null)
    {
        var text = CaptureFormat.CleanSubheading(rawText);
        if (text.Length == 0 || IsTerminating) { return null; }
        await SettleCapturesAsync().ConfigureAwait(false);
        // Retyping a subheading whose commit failed retries that capture and id, so the quit drain cannot also write it.
        // Only a failed job with the same text and destination matches; a queued or different one is left alone.
        var capture = new Capture(Guid.NewGuid(), DateTimeOffset.UtcNow, CaptureContent.Subheading(text), new CaptureSource());
        var retry = await Pipeline.Unsaved.FindRetryAsync(job => job.Prepared.Capture.Content == capture.Content &&
            (destination is null || job.Prepared.Destination == destination)).ConfigureAwait(false);
        var preparation = retry is not null ? Task.FromResult(retry) : Task.Run(() => Pipeline.PrepareSubheading(capture, destination));
        var saved = await Pipeline.Unsaved.Commit(retry?.Prepared.Capture.Id ?? capture.Id, preparation, job => CommitJob(job, null)).ConfigureAwait(false);
        ShowToast(new(AppToastStyle.Success, Strings.SubheadingAdded, text));
        return saved;
    }

    public Task<IReadOnlyList<NoteSuggestion>> SuggestionSnapshotAsync(bool sessionsOnly) => Task.Run<IReadOnlyList<NoteSuggestion>>(() =>
    {
        try
        {
            // The input panel's provider is synchronous: a sorted snapshot allows the same prefix filtering.
            return Pipeline.Index.TitleSuggestions("", int.MaxValue).Where(s => !sessionsOnly || s.Kind == NoteKind.Session).ToArray();
        }
        catch (Exception error)
        {
            log.Error($"Title suggestions failed: {error.GetType().Name}");
            return [];
        }
    });

    /// What the title picker offers. Bare titles match root notes first, then sessions, so nested, HOME, shadowed and
    /// same-titled notes get a value of their own, tied to their exact destination (which commits without routing).
    public TitlePicks PickerChoices(IReadOnlyList<NoteSuggestion> suggestions)
    {
        var vault = Pipeline.Vault;
        var rules = vault.NamingRules;
        static bool IsHome(NoteSuggestion s) => s.Path.StartsWith("file:", StringComparison.OrdinalIgnoreCase);
        static bool IsRoot(NoteSuggestion s) => s.Kind == NoteKind.Note && !IsHome(s) && !s.Path.Contains('/');
        var roots = suggestions.Where(IsRoot).GroupBy(s => NoteTitle.MatchKey(s.Title)).ToDictionary(g => g.Key, g => g.Count());
        var sessions = suggestions.Where(s => s.Kind == NoteKind.Session).GroupBy(s => NoteTitle.MatchKey(s.Title)).ToDictionary(g => g.Key, g => g.Count());
        var picks = new TitlePicks();
        foreach (var suggestion in suggestions)
        {
            var key = NoteTitle.MatchKey(suggestion.Title);
            var exact = suggestion.Kind switch
            {
                NoteKind.Note => IsRoot(suggestion) && roots[key] == 1,
                NoteKind.Session => !roots.ContainsKey(key) && sessions[key] == 1,
                _ => true
            };
            if (exact && Router.IsHeadingTitle(suggestion.Title, rules)) { continue; }
            try
            {
                var home = IsHome(suggestion);
                var url = home ? Vault.DecodeFilePath(suggestion.Path) : vault.UrlForRelativePath(suggestion.Path);
                var relative = home ? Vault.RelativeUnder(url, vault.HomeRoot) : suggestion.Path;
                if (relative is null || !relative.EndsWith(".md", StringComparison.OrdinalIgnoreCase)) { continue; }
                // The file name with .md is unique among the offered values. Nested, HOME and session notes use their
                // extensionless path instead when the Router resolves it to the same name.
                var value = home ? "/" + relative : relative;
                if (!IsRoot(suggestion))
                {
                    var stem = relative[..^3];
                    var path = home ? "/" + stem : stem;
                    if (RoundTrips(path, stem, rules)) { value = path; }
                }

                picks.Add(suggestion, value, new Destination(url, suggestion.Title, suggestion.Kind));
            }
            catch (Exception error) when (error is ArgumentException or VaultFileException) { }
        }

        return picks;
    }

    private static bool RoundTrips(string path, string stem, VaultNamingRules rules)
    {
        try { return string.Equals(NoteTitle.PathName(path, rules).RelativePath, stem, StringComparison.OrdinalIgnoreCase); }
        catch (NotePathNameException) { return false; }
    }

    // Sessions.
    // Each session change settles in-flight captures first, so they land in the session they were taken in.
    // Quit may begin while captures settle; the session is then left unchanged.
    private async Task SettleBeforeSessionChangeAsync()
    {
        await SettleCapturesAsync().ConfigureAwait(false);
        if (IsTerminating) { throw new OperationCanceledException("Quit began before the session change."); }
    }

    public async Task<Session> StartSessionAsync(string name)
    {
        await SettleBeforeSessionChangeAsync().ConfigureAwait(false);
        return await Task.Run(() => ActivateSession(Pipeline.StartSession(name))).ConfigureAwait(false);
    }

    public async Task<Session> StartFolderSessionAsync(string folder, string name)
    {
        await SettleBeforeSessionChangeAsync().ConfigureAwait(false);
        return await Task.Run(() => ActivateSession(Pipeline.StartFolderSession(new NoteFolder(folder), name))).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<NoteSuggestion>> FolderSessionSuggestionsAsync(string folder)
    {
        var parent = "Sessions/" + new NoteFolder(folder).RawValue;
        return (await SuggestionSnapshotAsync(true).ConfigureAwait(false)).Where(s =>
            string.Equals(s.Path[..Math.Max(0, s.Path.LastIndexOf('/'))], parent, StringComparison.OrdinalIgnoreCase)).ToArray();
    }

    public async Task<Session> ResumeSessionAsync(SessionCandidate candidate)
    {
        await SettleBeforeSessionChangeAsync().ConfigureAwait(false);
        return await Task.Run(() => ActivateSession(Pipeline.ResumeSession(candidate))).ConfigureAwait(false);
    }

    public async Task<SessionRenameOutcome> RenameSessionAsync(SessionCandidate candidate, string newName)
    {
        await SettleBeforeSessionChangeAsync().ConfigureAwait(false);
        return await RenameSessionNow(candidate, newName).ConfigureAwait(false);
    }

    private Task<SessionRenameOutcome> RenameSessionNow(SessionCandidate candidate, string newName) => Task.Run(() =>
    {
        try
        {
            var outcome = Pipeline.RenameSession(candidate, newName);
            ActiveSession = outcome.Session;
            host.StatusChanged();
            if (outcome.IdentityUpdatePending)
                ShowToast(new(AppToastStyle.Warning, $"Session rename pending · {outcome.Session.Name}", "State updates will retry before the next save."));
            else ShowToast(new(AppToastStyle.Session, Strings.SessionStarted(outcome.Session.Name, true),
                Strings.SessionCapturesGoHere(host.SessionBinding)));
            return outcome;
        }
        finally
        {
            // Disk rename can succeed before a later state/cache write fails. Keep tray state in sync.
            host.StatusChanged();
        }
    });

    private Session ActivateSession(Session session)
    {
        ActiveSession = session;
        host.StatusChanged();
        Pipeline.Index.Reindex(Pipeline.Vault.ManagedUrl(session.NotePath));
        ShowToast(new(AppToastStyle.Session, Strings.SessionStarted(session.Name, session.Resumed == true),
            Strings.SessionCapturesGoHere(host.SessionBinding)));
        return session;
    }

    public async Task<int> EndSessionAsync(Session session)
    {
        await SettleBeforeSessionChangeAsync().ConfigureAwait(false);
        return await EndSessionNow(session).ConfigureAwait(false);
    }

    private Task<int> EndSessionNow(Session session) => Task.Run(() =>
    {
        Pipeline.EndSession();
        ActiveSession = null;
        host.StatusChanged();
        var count = Pipeline.Index.CaptureCount(session.NotePath);
        ShowToast(new(AppToastStyle.Session, Strings.SessionEnded(session.Name), Strings.CaptureCount(count)));
        return count;
    });

    // Reporting.
    public void ShowToast(AppToast toast)
    {
        _ = CommitPending();
        lock (gate)
        {
            pendingToastId = null;
            retryWarningShown = false;
        }

        if (!IsTerminating || !host.PresentsUi) { host.ShowToast(toast); }
    }

    /// Warns that a retry-pending capture was kept; its hotkey reopens the picker while the warning is visible.
    private void ShowRetryChoice(PendingCapture capture, string title, bool ambiguous = false)
    {
        bool current;
        lock (gate)
        {
            current = pending?.Id == capture.Id;
            retryWarningShown = current;
        }

        if (!current || (IsTerminating && host.PresentsUi)) { return; }
        var binding = host.BindingFor(capture.Trigger);
        // Longer than the 3 s warning default, since the shortcut reopens the picker only while this toast is visible.
        host.ShowStagedToast(new(AppToastStyle.Warning, title, ambiguous ? Strings.CaptureKeptPickByPath(binding) : Strings.CaptureKept(binding), binding,
            Strings.ChooseNoteHint, Duration: 6));
    }

    /// The picker closed without a choice: a retry-pending capture shows its warning again, any other saves to its default destination.
    public void SettleUnchosenCapture(Guid id, bool announce)
    {
        if (RestoreRetryWarning(id, Strings.ChooseWhereToSave)) { return; }
        if (Pending?.Id == id) { _ = CommitPending(announce: announce); }
    }

    /// Shows the warning of a retry-pending capture again (its hotkey reopens the picker); false when it is not held.
    public bool RestoreRetryWarning(Guid id, string title)
    {
        PendingCapture? capture;
        lock (gate) { capture = pendingNeedsRetryChoice ? pending : null; }
        if (capture is null || capture.Id != id) { return false; }
        ShowRetryChoice(capture, title);
        return true;
    }

    public void Report(Exception error, string title)
    {
        log.Error($"{title} ({error.GetType().Name}): {error}");
        ShowToast(new(AppToastStyle.Warning, title));
    }

    public void ReportUserSaveFailure(Exception error, string title)
    {
        if (error is ExternalNoteRegistryException registry) { ReportExternalRegistryProblem(registry, true); }
        else { Report(error, title); }
    }

    public void ReportExternalRegistryProblem(Exception error, bool forSave)
    {
        var key = error is ExternalNoteRegistryException r ? $"{r.Kind}:{r.Version}" : error.GetType().Name;
        if (!forSave)
        {
            lock (gate) { if (!reportedRegistryWarnings.Add(key)) { return; } }
        }

        var registry = error as ExternalNoteRegistryException;
        var (title, subtitle) = Strings.ExternalRegistry(registry?.Kind, registry?.Version, forSave);
        log.Error($"{title} ({error.GetType().Name}): {error}");
        ShowToast(new(AppToastStyle.Warning, title, subtitle));
    }

    public void ClearRegistryWarnings()
    {
        lock (gate) { reportedRegistryWarnings.Clear(); }
    }

    // Shutdown. The caller has already dismissed its panels and refused to quit over an unsaved editor.
    public Task<bool> BeginTermination(TimeSpan? timeout = null)
    {
        lock (gate)
        {
            if (shutdownTask is not null) { return shutdownTask; }
            isTerminating = true;
        }

        var deadline = DateTimeOffset.UtcNow + (timeout ?? TimeSpan.FromSeconds(5));
        var watcherStop = Pipeline.StopWatcherAsync();
        _ = CommitPending();
        Task? acquisition;
        Task? actions;
        Task? startup;
        PendingCapture? fallback;
        lock (gate)
        {
            fallback = acquisitionFallback;
            acquisition = acquisitionTask;
            actions = actionTail;
            startup = startupReplayTask;
        }

        // OCR already owns pixels. Keep them in a fixed-destination recovery record while waiting.
        if (fallback is not null) { JournalAcquisition(fallback); }
        var drain = Task.Run(async () =>
        {
            if (Semantic is { } semantic) { await semantic.StopAsync().ConfigureAwait(false); }
            await TryWait(startup).ConfigureAwait(false);
            await TryWait(acquisition).ConfigureAwait(false);
            Task? processing;
            lock (gate) { processing = processingTail; }
            await TryWait(processing).ConfigureAwait(false);
            await TryWait(actions).ConfigureAwait(false);
            lock (gate) { if (shutdownFinished) { return; } }
            _ = CommitPending();
            await Pipeline.Unsaved.DrainAsync(job => CommitJob(job, null), () => { lock (gate) { return shutdownFinished; } }).ConfigureAwait(false);
            await TryWait(watcherStop).ConfigureAwait(false);
        });
        var task = Task.Run(async () =>
        {
            var completed = await ShutdownWait.WaitAsync(drain, deadline).ConfigureAwait(false);
            try { await ShutdownWait.WaitAsync(Pipeline.Unsaved.WhenRecorded(), TimeSpan.FromSeconds(2)).ConfigureAwait(false); }
            catch (Exception error) { log.Error($"Shutdown recovery journal failed: {error.GetType().Name}"); }
            lock (gate)
            {
                shutdownFinished = true;
                if (!completed) { acquisitionGeneration++; }
            }

            if (!completed) { log.Error("Shutdown reached its deadline; prepared captures remain in the recovery journal."); }
            return true;
        });
        lock (gate) { shutdownTask = task; }
        return task;
    }

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
