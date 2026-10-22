using CaptureApp.AppCore.Semantic;
using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.AppCore.Shell;

/// The UI-free half of AppController.swift: staging, ordered commits, journaling, notes, sessions and the
/// shutdown drain. The App's controller owns panels, tray and hotkeys and calls into this class.
public sealed class CaptureCoordinator
{
    private sealed record Staged(Guid Id, Task<CaptureJob> Preparation, Task Persistence);

    private readonly object gate = new();
    private readonly ICaptureHost host;
    private readonly AppLog log;
    private readonly Dictionary<Guid, Task<CaptureJob>> preparedJobs = [];
    private readonly Dictionary<Guid, Task<CaptureJob>> recoveryJobs = [];
    private readonly Dictionary<Guid, Task> recoveryPersistences = [];
    private readonly Dictionary<Guid, Task<string?>> deferredOcr = [];
    private readonly HashSet<string> reportedRegistryWarnings = new(StringComparer.Ordinal);
    private PendingCapture? pending;
    private Guid? pendingToastId;
    private Staged? staged;
    private Task<SavedCapture>? commitTail;
    private int commitGeneration;
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
    public Session? ActiveSession { get; private set; }
    public bool IsTerminating { get { lock (gate) { return isTerminating; } } }
    public bool AcquisitionInProgress { get { lock (gate) { return acquisitionInProgress; } } }
    public PendingCapture? Pending { get { lock (gate) { return pending; } } }
    public bool HasPendingToast { get { lock (gate) { return pending is not null && pendingToastId == pending.Id; } } }
    public PendingCapture? PendingWithToast { get { lock (gate) { return pending is not null && pendingToastId == pending.Id ? pending : null; } } }
    public Task? CommitTail { get { lock (gate) { return commitTail; } } }

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
        await StageAsync(capture).ConfigureAwait(true);
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
            if (recoveryJobs.ContainsKey(capture.Id)) { return; }
            var preparation = Task.Run(() => Prepare(capture, null, null));
            recoveryJobs[capture.Id] = preparation;
            recoveryPersistences[capture.Id] = Task.Run(async () => Pipeline.Journal.Store(await preparation.ConfigureAwait(false)));
        }
    }

    private CaptureJob Prepare(PendingCapture capture, string? noteTitle, Destination? destination)
    {
        var route = destination is null ? noteTitle : null;
        var job = capture.Png is not null
            ? Pipeline.PrepareImage(capture.Png, capture.Source, route, capture.Ocr, capture.Id, capture.CreatedAt)
            : Pipeline.PrepareText(capture.Content.Value, capture.Source, route, null, capture.Id, capture.CreatedAt);
        return destination is null ? job : Pipeline.WithDestination(job, destination);
    }

    // Staging and commit.
    public async Task StageAsync(PendingCapture capture)
    {
        lock (gate) { if (shutdownFinished) { return; } }
        _ = CommitPending();
        Task<CaptureJob>? recovery;
        Task? recoveryPersistence;
        lock (gate)
        {
            recoveryJobs.TryGetValue(capture.Id, out recovery);
            recoveryPersistences.TryGetValue(capture.Id, out recoveryPersistence);
        }

        var preparation = Task.Run(async () =>
        {
            var recovered = await TryResult(recovery).ConfigureAwait(false);
            return Prepare(capture, null, recovered?.Prepared.Destination);
        });
        var persistence = Task.Run(async () =>
        {
            await TryWait(recoveryPersistence).ConfigureAwait(false);
            Pipeline.Journal.Store(await preparation.ConfigureAwait(false));
        });
        lock (gate)
        {
            staged = new(capture.Id, preparation, persistence);
            pending = capture;
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
        Session? session = null;
        try { session = Pipeline.Sessions.Current(); } catch (Exception error) { log.Error($"Session read failed: {error.GetType().Name}"); }
        lock (gate)
        {
            if (!host.PresentsUi || pending?.Id != capture.Id || isTerminating) { return; }
            pendingToastId = capture.Id;
        }

        host.ShowStagedToast(new(AppToastStyle.Success, session is null ? Strings.SavedTo(Vault.InboxTitle) : Strings.AddedTo(session.Name),
            capture.Subtitle, host.BindingFor(capture.Trigger), Strings.ChooseNoteHint));
    }

    /// The staged toast expired: the default destination is the answer.
    public void ToastExpired()
    {
        bool commit;
        lock (gate) { commit = pending is not null && pendingToastId == pending.Id; }
        if (commit) { _ = CommitPending(); }
    }

    /// Hotkey re-press on the staged toast: stop the toast and choose a destination.
    public void ClearToastMarker()
    {
        lock (gate) { pendingToastId = null; }
        host.DismissStagedToast();
    }

    public Task<SavedCapture>? CommitPending(string? noteTitle = null, bool announce = false)
    {
        PendingCapture capture;
        Staged? stagedJob;
        Task<CaptureJob>? recovery;
        Task? recoveryPersistence;
        Task<SavedCapture>? previous;
        bool terminating;
        lock (gate)
        {
            if (pending is null) { return null; }
            capture = pending;
            pending = null;
            pendingToastId = null;
            previous = commitTail;
            stagedJob = staged is { } current && current.Id == capture.Id ? current : null;
            staged = null;
            terminating = isTerminating;
            recovery = null;
            if (terminating) { recoveryJobs.TryGetValue(capture.Id, out recovery); }
            recoveryPersistences.TryGetValue(capture.Id, out recoveryPersistence);
        }

        if (host.PresentsUi) { host.DismissStagedToast(); }
        // Only shutdown's acquired-pixel fallback forces its original destination.
        var preparation = Task.Run(async () =>
        {
            Destination? destination;
            if (recovery is not null) { destination = (await TryResult(recovery).ConfigureAwait(false))?.Prepared.Destination; }
            else if (noteTitle is null) { destination = (await TryResult(stagedJob?.Preparation).ConfigureAwait(false))?.Prepared.Destination; }
            else { destination = null; }
            return Prepare(capture, noteTitle, destination);
        });
        int generation;
        Task<SavedCapture> task;
        lock (gate)
        {
            preparedJobs[capture.Id] = preparation;
            // Journal before waiting for earlier writes, so even queued work is recoverable.
            task = Task.Run(async () =>
            {
                var job = await preparation.ConfigureAwait(false);
                await TryWait(stagedJob?.Persistence).ConfigureAwait(false);
                await TryWait(recoveryPersistence).ConfigureAwait(false);
                Pipeline.Journal.Store(job);
                await TryWait(previous).ConfigureAwait(false);
                return CommitJob(job, null);
            });
            commitTail = task;
            generation = ++commitGeneration;
        }

        _ = ObserveCommitAsync(task, preparation, capture, stagedJob, noteTitle, announce, generation);
        return task;
    }

    private async Task ObserveCommitAsync(Task<SavedCapture> task, Task<CaptureJob> preparation, PendingCapture capture,
        Staged? stagedJob, string? noteTitle, bool announce, int generation)
    {
        try
        {
            var saved = await task.ConfigureAwait(false);
            bool noPending;
            lock (gate)
            {
                preparedJobs.Remove(capture.Id);
                recoveryJobs.Remove(capture.Id);
                recoveryPersistences.Remove(capture.Id);
                noPending = pending is null;
            }

            if (announce && noPending)
            {
                host.ShowToast(new(AppToastStyle.Success, Strings.SavedTo(saved.Destination.Title), Duration: 1.6));
            }
        }
        catch (Exception error)
        {
            if (noteTitle is not null && preparation.IsFaulted && stagedJob is not null)
            {
                lock (gate)
                {
                    preparedJobs.Remove(capture.Id);
                    staged = stagedJob;
                    pending = capture;
                    pendingToastId = capture.Id;
                }
            }

            ReportUserSaveFailure(error, Strings.CouldNotSaveCapture);
        }

        lock (gate) { if (commitGeneration == generation) { commitTail = null; } }
    }

    private SavedCapture CommitJob(CaptureJob job, bool? pinOnSave, string? noteText = null)
    {
        var saved = Pipeline.Commit(job, pinOnSave, (value, pinFailed) =>
            NoteFeedback(value, pinFailed, job.Prepared.CreatesNote == true, noteText));
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

    private void NoteFeedback(SavedCapture saved, bool pinFailed, bool? created = null, string? text = null)
    {
        if (pinFailed)
        {
            ShowToast(new(AppToastStyle.Warning, Strings.NoteNotPinned, saved.Destination.Title));
        }
        else if (created is { } made && text is not null)
        {
            ShowToast(new(AppToastStyle.Success, Strings.NoteCreatedOrAdded(made),
                made ? saved.Destination.Title : PendingCaptures.FirstLine(text)));
        }
    }

    public Task WaitForProcessingAsync() { Task? tail; lock (gate) { tail = processingTail; } return TryWait(tail); }

    public Task WaitForCommitsAsync() { Task? tail; lock (gate) { tail = commitTail; } return TryWait(tail); }

    // Notes and subheadings.
    public async Task<SavedCapture?> AddNoteAsync(string rawText, Destination? destination = null, bool pinOnSave = false,
        bool newNote = false)
    {
        if (IsTerminating) { return null; }
        Pipeline.Drafts.Store(rawText, pinOnSave);
        var text = CaptureFormat.NoteBody(rawText);
        if (string.IsNullOrWhiteSpace(text)) { return null; }
        var pendingCommit = CommitPending();
        await WaitForProcessingAsync().ConfigureAwait(false);
        var processedCommit = CommitPending();
        if (pendingCommit is not null) { await pendingCommit.ConfigureAwait(false); }
        if (processedCommit is not null) { await processedCommit.ConfigureAwait(false); }

        Task<CaptureJob>? retry = null;
        KeyValuePair<Guid, Task<CaptureJob>>[] candidates;
        var superseded = new Dictionary<Guid, Guid>();
        lock (gate) { candidates = preparedJobs.ToArray(); }
        foreach (var (key, candidate) in candidates)
        {
            if (await TryResult(candidate).ConfigureAwait(false) is not { } job) { continue; }
            var sameText = job.NoteDraft is { } draft
                ? CaptureFormat.NoteBody(draft) == text
                : job.Prepared.Capture.Content == CaptureContent.Note(text);
            if (sameText && (destination is null || job.Prepared.Destination == destination))
            {
                if (newNote && job.Prepared.CreatesNote != true)
                {
                    superseded[key] = job.Prepared.Capture.Id;
                    continue;
                }

                retry = candidate;
                break;
            }
        }

        // Remove the durable append first. If removal fails, keep the old job retryable and the draft intact.
        foreach (var (key, id) in superseded)
        {
            Pipeline.Journal.Remove(id);
            lock (gate) { preparedJobs.Remove(key); }
        }

        var preparation = retry ?? Task.Run(() => Pipeline.PrepareNote(text, new CaptureSource(), destination, rawText, newNote: newNote));
        var prepared = (await preparation.ConfigureAwait(false)).Prepared;
        var noteId = prepared.Capture.Id;
        Task<SavedCapture> task;
        int generation;
        lock (gate)
        {
            preparedJobs[noteId] = preparation;
            var previous = commitTail;
            task = Task.Run(async () =>
            {
                var job = await preparation.ConfigureAwait(false);
                Pipeline.Journal.Store(job);
                await TryWait(previous).ConfigureAwait(false);
                return CommitJob(job, pinOnSave, text);
            });
            commitTail = task;
            generation = ++commitGeneration;
        }

        var saved = await task.ConfigureAwait(false);
        lock (gate)
        {
            preparedJobs.Remove(noteId);
            if (commitGeneration == generation) { commitTail = null; }
        }

        return saved;
    }

    public async Task<SavedCapture?> AddSubheadingAsync(string rawText, Destination? destination = null)
    {
        var text = CaptureFormat.CleanSubheading(rawText);
        if (text.Length == 0 || IsTerminating) { return null; }
        _ = CommitPending();
        await WaitForProcessingAsync().ConfigureAwait(false);
        _ = CommitPending();
        var capture = new Capture(Guid.NewGuid(), DateTimeOffset.UtcNow, CaptureContent.Subheading(text), new CaptureSource());
        var preparation = Task.Run(() => Pipeline.PrepareSubheading(capture, destination));
        Task<SavedCapture> task;
        int generation;
        lock (gate)
        {
            preparedJobs[capture.Id] = preparation;
            var previous = commitTail;
            task = Task.Run(async () =>
            {
                var job = await preparation.ConfigureAwait(false);
                Pipeline.Journal.Store(job);
                await TryWait(previous).ConfigureAwait(false);
                return CommitJob(job, null);
            });
            commitTail = task;
            generation = ++commitGeneration;
        }

        var saved = await task.ConfigureAwait(false);
        lock (gate)
        {
            preparedJobs.Remove(capture.Id);
            if (commitGeneration == generation) { commitTail = null; }
        }

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

    // Sessions.
    public Task<Session> StartSessionAsync(string name) => Task.Run(() => ActivateSession(Pipeline.Sessions.Start(name)));

    public Task<Session> ResumeSessionAsync(SessionCandidate candidate) => Task.Run(() => ActivateSession(Pipeline.Sessions.Resume(candidate)));

    public Task<SessionRenameOutcome> RenameSessionAsync(SessionCandidate candidate, string newName) => Task.Run(() =>
    {
        try
        {
            var outcome = Pipeline.RenameSession(candidate, newName);
            ActiveSession = outcome.Session;
            host.StatusChanged();
            if (outcome.IdentityUpdatePending)
                ShowToast(new(AppToastStyle.Warning, $"Session rename pending · {outcome.Session.Name}", "State updates will retry before the next save."));
            else ActivateSession(outcome.Session);
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

    public Task<int> EndSessionAsync(Session session) => Task.Run(() =>
    {
        Pipeline.Sessions.End();
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
        lock (gate) { pendingToastId = null; }
        if (!IsTerminating || !host.PresentsUi) { host.ShowToast(toast); }
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
            Task[] persistences;
            lock (gate) { persistences = recoveryPersistences.Values.ToArray(); }
            foreach (var persistence in persistences)
            {
                try { await persistence.ConfigureAwait(false); }
                catch (Exception error) { log.Error($"Shutdown recovery journal failed: {error.GetType().Name}"); }
            }

            lock (gate) { if (shutdownFinished) { return; } }
            _ = CommitPending();
            await WaitForCommitsAsync().ConfigureAwait(false);
            lock (gate) { if (shutdownFinished) { return; } }
            // A journal write itself may have failed earlier: retry the exact prepared capture.
            KeyValuePair<Guid, Task<CaptureJob>>[] jobs;
            lock (gate) { jobs = preparedJobs.ToArray(); }
            foreach (var (id, preparation) in jobs)
            {
                try
                {
                    var job = await preparation.ConfigureAwait(false);
                    Pipeline.Journal.Store(job);
                    CommitJob(job, null);
                    lock (gate) { preparedJobs.Remove(id); }
                }
                catch (Exception error) { log.Error($"Shutdown save retained in journal: {error.GetType().Name}"); }
            }

            await TryWait(watcherStop).ConfigureAwait(false);
        });
        var task = Task.Run(async () =>
        {
            var completed = await ShutdownWait.WaitAsync(drain, deadline).ConfigureAwait(false);
            Task[] persistences;
            lock (gate) { persistences = recoveryPersistences.Values.ToArray(); }
            try { await ShutdownWait.WaitAsync(Task.WhenAll(persistences), TimeSpan.FromSeconds(2)).ConfigureAwait(false); }
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
