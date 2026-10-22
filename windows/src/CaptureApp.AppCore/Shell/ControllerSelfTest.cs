using System.Text;
using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.AppCore.Shell;

/// A host that presents nothing and records toasts (the Mac's presentsUI=false controller).
public sealed class HeadlessCaptureHost : ICaptureHost
{
    public List<AppToast> Toasts { get; } = [];
    public bool PresentsUi => false;
    public bool StagedToastVisible => false;
    public string SessionBinding => "the session shortcut";
    public void ShowToast(AppToast toast) { lock (Toasts) { Toasts.Add(toast); } }
    public void ShowStagedToast(AppToast toast) => ShowToast(toast);
    public void DismissStagedToast() { }
    public string BindingFor(CaptureTrigger trigger) => trigger.ToString();
    public void StatusChanged() { }
}

/// The controller sections of SelfTest.swift that do not need a desktop: staging, journaling, ordered commits,
/// the OCR budget race, sessions, subheadings, typed notes, replay and the shutdown drain.
public static class ControllerSelfTest
{
    public static async Task RunAsync(string baseDirectory, TimeZoneInfo zone, TextWriter output, CancellationToken cancellationToken = default)
    {
        var vaultDirectory = Path.Combine(baseDirectory, "Vault");
        var stateDirectory = Path.Combine(baseDirectory, "State");
        var homeDirectory = Path.Combine(baseDirectory, "Home");
        Directory.CreateDirectory(homeDirectory);
        var pipeline = CapturePipeline.Open(vaultDirectory, stateDirectory, zone, null, 0.12, homeDirectory: homeDirectory);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        var terminated = false;
        try
        {
            var source = new CaptureSource("Demo Source", "Pipeline smoke test");
            await coordinator.StartAsync().ConfigureAwait(false);

            // A staged, uncommitted capture is journaled at its default destination before any title is accepted.
            var staged = PendingCaptures.Selection("controllerneedle full body\nSecond line.", source);
            await coordinator.StageAsync(staged).ConfigureAwait(false);
            var records = pipeline.Journal.RecordPaths();
            if (records.Count != 1 || pipeline.Journal.Load(records[0]).Prepared.Capture.Id != staged.Id
                || pipeline.Journal.Load(records[0]).Prepared.Destination.Kind != NoteKind.Inbox || pipeline.Index.Capture(staged.Id) is not null)
            {
                throw new InvalidOperationException("Staged, uncommitted capture was not journaled at its default destination.");
            }

            var titled = await (coordinator.CommitPending("Demo Heading") ?? throw new InvalidOperationException("Text was not pending")).ConfigureAwait(false);
            if (titled.Destination.Title != "Demo Heading" || pipeline.Index.Capture(staged.Id)?.Body != "controllerneedle full body\nSecond line.")
            {
                throw new InvalidOperationException("The titled capture did not reach its note with the full body.");
            }

            await WritePass(output, "controller staged capture journaled and committed").ConfigureAwait(false);

            // Keep the first acquisition single-flight until its work is in the processing queue.
            var firstQueued = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var releaseFirstQueueRegistration = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var firstInOrder = PendingCaptures.Selection("first queued acquisition", source);
            var secondInOrder = PendingCaptures.Selection("second queued acquisition", source);
            coordinator.BeforeProcessingTailRegistrationForSelfTest = async capture =>
            {
                if (capture.Id != firstInOrder.Id) { return; }
                firstQueued.TrySetResult();
                await releaseFirstQueueRegistration.Task.ConfigureAwait(false);
            };
            var secondAcceptedDuringHandoff = false;
            try
            {
                if (!coordinator.BeginAcquisition(() => Task.FromResult<PendingCapture?>(firstInOrder)))
                {
                    throw new InvalidOperationException("First ordered acquisition was not accepted.");
                }
                await firstQueued.Task.WaitAsync(TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false);
                secondAcceptedDuringHandoff = coordinator.BeginAcquisition(() => Task.FromResult<PendingCapture?>(secondInOrder));
            }
            finally
            {
                releaseFirstQueueRegistration.TrySetResult();
                coordinator.BeforeProcessingTailRegistrationForSelfTest = null;
            }

            await WaitUntil(() => !coordinator.AcquisitionInProgress, "acquisition handoff did not finish", cancellationToken).ConfigureAwait(false);
            await coordinator.WaitForProcessingAsync().WaitAsync(TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false);
            if (secondAcceptedDuringHandoff)
            {
                throw new InvalidOperationException("A second acquisition was accepted before the first capture entered the processing queue.");
            }
            if (!coordinator.BeginAcquisition(() => Task.FromResult<PendingCapture?>(secondInOrder)))
            {
                throw new InvalidOperationException("Second ordered acquisition was not accepted after queue registration.");
            }
            await WaitUntil(() => !coordinator.AcquisitionInProgress, "second ordered acquisition did not finish", cancellationToken).ConfigureAwait(false);
            await coordinator.WaitForProcessingAsync().WaitAsync(TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false);
            await (coordinator.CommitPending() ?? throw new InvalidOperationException("Second ordered capture was not staged."))
                .WaitAsync(TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false);
            var orderedIds = NoteParser.Parse(File.ReadAllText(pipeline.Vault.InboxUrl), "Inbox.md", "", zone)
                .Blocks.Where(block => block.CaptureId is not null).Select(block => block.CaptureId!.Value).ToArray();
            var firstIndex = Array.IndexOf(orderedIds, firstInOrder.Id);
            var secondIndex = Array.IndexOf(orderedIds, secondInOrder.Id);
            if (firstIndex < 0 || secondIndex <= firstIndex)
            {
                throw new InvalidOperationException($"Captures committed out of order (first index {firstIndex}, second index {secondIndex}).");
            }
            await WritePass(output, "controller acquisition remains single-flight through ordered queue registration").ConfigureAwait(false);

            // Over-budget OCR must stage and commit the image while recognition remains blocked, then index text later.
            var recognitionStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var releaseRecognition = new TaskCompletionSource<RegionRecognition?>(TaskCreationOptions.RunContinuationsAsynchronously);
            var deferredRegistered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var png = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9, 9 };
            var imageId = Guid.NewGuid();
            var accepted = coordinator.BeginAcquisition(
                () => Task.FromResult<PendingCapture?>(PendingCaptures.Image(png, null, source, "Image", imageId)),
                async acquired => await RegionProcessing.ProcessAsync(png, source, acquired.Id, acquired.CreatedAt,
                    async _ =>
                    {
                        recognitionStarted.TrySetResult();
                        return await releaseRecognition.Task.ConfigureAwait(false);
                    },
                    (id, task) =>
                    {
                        coordinator.RegisterDeferredOcr(id, task);
                        deferredRegistered.TrySetResult();
                    }, TimeSpan.FromMilliseconds(100)).ConfigureAwait(false));
            if (!accepted) { throw new InvalidOperationException("Slow OCR acquisition not accepted."); }
            try
            {
                await recognitionStarted.Task.WaitAsync(TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false);
                await deferredRegistered.Task.WaitAsync(TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false);

                await WaitUntil(() => !coordinator.AcquisitionInProgress, "OCR fallback acquisition did not finish", cancellationToken).ConfigureAwait(false);
                var next = PendingCaptures.Selection("secondacquisitionneedle", source);
                if (!coordinator.BeginAcquisition(() => Task.FromResult<PendingCapture?>(next)))
                {
                    throw new InvalidOperationException("A second capture was ignored while OCR ran in the background.");
                }
                await WaitUntil(() => !coordinator.AcquisitionInProgress, "second acquisition stuck", cancellationToken).ConfigureAwait(false);
                await coordinator.WaitForProcessingAsync().WaitAsync(TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false);
                await (coordinator.CommitPending() ?? throw new InvalidOperationException("Second acquisition was not staged."))
                    .WaitAsync(TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false);

                var imageKind = pipeline.Index.Capture(imageId)?.BlockKind;
                if (imageKind != BlockKind.Image)
                {
                    throw new InvalidOperationException($"Blocked OCR did not commit the fallback image (indexed as {imageKind?.ToString() ?? "nothing"}).");
                }

                var inbox = File.ReadAllText(pipeline.Vault.InboxUrl);
                var order = NoteParser.Parse(inbox, "Inbox.md", "", zone).Blocks.Where(b => b.CaptureId is not null).Select(b => b.CaptureId!.Value).ToArray();
                if (!order.TakeLast(2).SequenceEqual([imageId, next.Id]))
                {
                    throw new InvalidOperationException($"OCR fallback and next capture committed out of order (expected {imageId}, {next.Id}; actual {string.Join(", ", order)}).");
                }
                if (pipeline.Index.Search("slowocrneedle").Count != 0)
                {
                    throw new InvalidOperationException("Deferred OCR text became searchable before recognition was released.");
                }

                releaseRecognition.TrySetResult(new RegionRecognition("slowocrneedle searchable after budget", false));
                await WaitUntil(() => pipeline.Index.Search("slowocrneedle").Any(h => h.CaptureID == imageId), "Deferred OCR never became searchable", cancellationToken, 5000).ConfigureAwait(false);
                if (File.ReadAllText(pipeline.Vault.InboxUrl) != inbox) { throw new InvalidOperationException("Deferred OCR changed the note."); }
            }
            finally
            {
                releaseRecognition.TrySetResult(new RegionRecognition("slowocrneedle searchable after budget", false));
            }
            await WritePass(output, "controller OCR budget, ordering and deferred text").ConfigureAwait(false);

            // Sessions, subheadings and replay without duplicates.
            var session = await coordinator.StartSessionAsync("Feedback").ConfigureAwait(false);
            var browser = new CaptureSource("Firefox", "System Design — Mozilla Firefox");
            await coordinator.StageAsync(PendingCaptures.Selection("First paragraph.", browser)).ConfigureAwait(false);
            await (coordinator.CommitPending() ?? throw new InvalidOperationException("not pending")).ConfigureAwait(false);
            await coordinator.StageAsync(PendingCaptures.Selection("Second paragraph.", browser)).ConfigureAwait(false);
            var subheading = await coordinator.AddSubheadingAsync("### Tradeoffs\n and limits").ConfigureAwait(false)
                ?? throw new InvalidOperationException("Subheading was not appended.");
            var notePath = pipeline.Vault.ManagedUrl(session.NotePath);
            var beforeEmpty = File.ReadAllBytes(notePath);
            if (await coordinator.AddSubheadingAsync(" ### ").ConfigureAwait(false) is not null || !File.ReadAllBytes(notePath).SequenceEqual(beforeEmpty))
            {
                throw new InvalidOperationException("An empty subheading changed the note.");
            }

            var replay = new Capture(subheading.CaptureId, DateTimeOffset.UtcNow, CaptureContent.Subheading("Tradeoffs and limits"), new CaptureSource());
            pipeline.Journal.Store(new CaptureJob(new PreparedCapture(replay, subheading.Destination)));
            if (await pipeline.ReplayUnsavedAsync(cancellationToken).ConfigureAwait(false) != 1 || !File.ReadAllBytes(notePath).SequenceEqual(beforeEmpty))
            {
                throw new InvalidOperationException("Subheading journal replay duplicated the block.");
            }

            await coordinator.StageAsync(PendingCaptures.Selection("Third paragraph.", browser)).ConfigureAwait(false);
            await (coordinator.CommitPending() ?? throw new InvalidOperationException("not pending")).ConfigureAwait(false);
            var markdown = File.ReadAllText(notePath, Encoding.UTF8);
            var second = markdown.IndexOf("Second paragraph.", StringComparison.Ordinal);
            var heading = markdown.IndexOf("## Tradeoffs and limits", StringComparison.Ordinal);
            if (markdown.Split("### System Design\n").Length - 1 != 2 || second < 0 || heading < second || pipeline.Index.CaptureCount(session.NotePath) != 3)
            {
                throw new InvalidOperationException("Subheading ordering or source grouping failed.");
            }

            await WritePass(output, "controller session, subheading and replay").ConfigureAwait(false);

            // Typed notes: draft cleanup, pending-first ordering, an independent note outside a session, collision append.
            var draft = "typednoteneedle A personal **note**  \n- [ ] Follow up\n";
            pipeline.Drafts.Store(draft);
            await coordinator.StageAsync(PendingCaptures.Selection("Fourth paragraph.", browser)).ConfigureAwait(false);
            var typed = await coordinator.AddNoteAsync(draft).ConfigureAwait(false) ?? throw new InvalidOperationException("Typed note was not saved.");
            var typedHit = pipeline.Index.Search("typednoteneedle").FirstOrDefault();
            if (pipeline.Drafts.Load().Length != 0 || typedHit is null || typedHit.CaptureID != typed.CaptureId || typedHit.BlockKind != BlockKind.Note)
            {
                throw new InvalidOperationException("Note search or draft cleanup failed.");
            }

            var withNote = File.ReadAllText(notePath, Encoding.UTF8);
            if (withNote.IndexOf("Fourth paragraph.", StringComparison.Ordinal) > withNote.IndexOf("typednoteneedle", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The pending capture did not precede the typed note.");
            }

            pipeline.Drafts.Store("Discard this empty draft");
            if (await coordinator.AddNoteAsync(" \n\t").ConfigureAwait(false) is not null || pipeline.Drafts.Load().Length != 0)
            {
                throw new InvalidOperationException("Whitespace-only input did not clear the draft.");
            }

            await coordinator.EndSessionAsync(session).ConfigureAwait(false);
            var inboxBefore = File.ReadAllBytes(pipeline.Vault.InboxUrl);
            var rootDraft = "# independentnoteneedle\n\nA personal **thought**  \n- [ ] Follow up\n";
            var created = await coordinator.AddNoteAsync(rootDraft).ConfigureAwait(false) ?? throw new InvalidOperationException("Independent note was not saved.");
            if (created.Destination.Kind != NoteKind.Note || !File.ReadAllBytes(pipeline.Vault.InboxUrl).SequenceEqual(inboxBefore)
                || pipeline.Index.Search("independentnoteneedle").FirstOrDefault()?.CaptureID != created.CaptureId)
            {
                throw new InvalidOperationException("Outside a session the note did not create and index its own file.");
            }

            var again = await coordinator.AddNoteAsync(rootDraft).ConfigureAwait(false);
            if (again?.Destination.Url != created.Destination.Url)
            {
                throw new InvalidOperationException("A typed-note title collision did not append to the existing note.");
            }

            var asNew = await coordinator.AddNoteAsync(rootDraft, newNote: true).ConfigureAwait(false);
            if (asNew is null || Path.GetFileName(asNew.Destination.Url) != "independentnoteneedle 2.md"
                || !File.Exists(asNew.Destination.Url) || pipeline.Journal.RecordPaths().Count != 0)
            {
                throw new InvalidOperationException("Save as New Note did not create a numbered sibling and clear its journal.");
            }

            await WritePass(output, "controller typed notes").ConfigureAwait(false);

            // Accepted termination drains a still-pending default commit and stops the watcher.
            pipeline.StartWatcher();
            await coordinator.StageAsync(PendingCaptures.Selection("shutdownneedle pending capture", source)).ConfigureAwait(false);
            await coordinator.BeginTermination().ConfigureAwait(false);
            terminated = true;
            if (pipeline.Monitor.IsRunning || pipeline.Index.Search("shutdownneedle").Count != 1)
            {
                throw new InvalidOperationException("Shutdown did not save its pending capture and stop the watcher.");
            }

            await WritePass(output, "controller shutdown drain").ConfigureAwait(false);
            await InFlightQuitAsync(baseDirectory, zone, output).ConfigureAwait(false);
        }
        finally
        {
            if (!terminated) { await coordinator.BeginTermination().ConfigureAwait(false); }
            pipeline.Dispose();
        }
    }

    /// A quit while OCR is still running journals the acquired pixels, and the next launch recovers them once.
    private static async Task InFlightQuitAsync(string baseDirectory, TimeZoneInfo zone, TextWriter output)
    {
        var vault = Path.Combine(baseDirectory, "QuitVault");
        var state = Path.Combine(baseDirectory, "QuitState");
        var home = Path.Combine(baseDirectory, "Home");
        var pipeline = CapturePipeline.Open(vault, state, zone, null, 0.12, homeDirectory: home);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var release = new ManualResetEventSlim();
        var acquired = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var acquisitionFinished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<bool>? terminate = null;
        var png = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 5, 5, 5 };
        var id = Guid.NewGuid();
        try
        {
            coordinator.BeginAcquisition(async () =>
            {
                try
                {
                    coordinator.RecordAcquiredImage(PendingCaptures.Image(png, null, new CaptureSource("Demo"), "Image", id));
                    acquired.SetResult();
                    await Task.Run(() => release.Wait(TimeSpan.FromSeconds(30))).ConfigureAwait(false);
                    return null;
                }
                finally { acquisitionFinished.TrySetResult(); }
            });
            if (!await ShutdownWait.WaitAsync(acquired.Task, TimeSpan.FromSeconds(10)).ConfigureAwait(false))
            {
                throw new InvalidOperationException("The in-flight acquisition did not record its image before termination.");
            }
            terminate = coordinator.BeginTermination(TimeSpan.FromMilliseconds(500));
            await terminate.ConfigureAwait(false);
            if (pipeline.Journal.RecordPaths().Count != 1 && pipeline.Index.Capture(id) is null)
            {
                throw new InvalidOperationException("A quit during acquisition lost the acquired pixels.");
            }
        }
        finally
        {
            release.Set();
            try
            {
                if (terminate is not null) { await terminate.ConfigureAwait(false); }
                if (acquired.Task.IsCompleted) { await acquisitionFinished.Task.WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false); }
            }
            finally { pipeline.Dispose(); }
        }

        pipeline = CapturePipeline.Open(vault, state, zone, null, 0.12, homeDirectory: home);
        try
        {
            await pipeline.ReplayUnsavedAsync().ConfigureAwait(false);
            await pipeline.ReplayUnsavedAsync().ConfigureAwait(false);
            if (pipeline.Index.Capture(id)?.BlockKind != BlockKind.Image)
            {
                throw new InvalidOperationException("The in-flight capture was not recovered on relaunch.");
            }
        }
        finally
        {
            pipeline.Dispose();
        }

        await WritePass(output, "controller in-flight quit recovered").ConfigureAwait(false);
    }

    private static async Task WaitUntil(Func<bool> condition, string failure, CancellationToken cancellationToken, int milliseconds = 3000)
    {
        var deadline = DateTimeOffset.UtcNow.AddMilliseconds(milliseconds);
        while (!condition())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (DateTimeOffset.UtcNow > deadline) { throw new TimeoutException(failure); }
            await Task.Delay(20, cancellationToken).ConfigureAwait(false);
        }
    }

    private static Task WritePass(TextWriter output, string section) => output.WriteLineAsync("PASS  " + section);
}
