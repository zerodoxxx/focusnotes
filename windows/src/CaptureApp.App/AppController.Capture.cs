using System.IO;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using CaptureApp.Overlay;
using CaptureApp.Platform;
using CaptureApp.Platform.Capture;
using CaptureApp.Platform.Context;
using CaptureApp.Platform.Hotkeys;
using CaptureApp.Platform.Ocr;
using CaptureApp.Platform.Selection;

namespace CaptureApp.App;

internal sealed partial class AppController
{
    private InputPanelController? input;
    private readonly List<TaskCompletionSource> inputCloseWaiters = [];
    private readonly SelectionReader selectionReader = new();

    /// The two capture hotkeys and their menu twins (AppController.swift:280).
    private void Capture(CaptureTrigger trigger, bool fromHotkey, FrontmostContext context, bool outsideSession = false)
    {
        if (Coordinator.IsTerminating || Coordinator.AcquisitionInProgress) { return; }
        if (context.ProcessIdentifier == (uint)Environment.ProcessId) { return; }
        // An Unavailable capability names its cause and points at Setup; nothing partial is captured.
        var capability = Capabilities.Of(CapabilityTable(), trigger == CaptureTrigger.Selection ? CapabilityId.SelectionCapture : CapabilityId.AreaCapture);
        if (!capability.IsAvailable)
        {
            Coordinator.ShowToast(new(AppToastStyle.Warning,
                capability.Reason == Capabilities.FinishSetupReason ? Strings.FinishSetupToCaptureTitle : capability.Reason ?? Strings.CapturePausedTitle,
                Strings.OpenTraySetup));
            return;
        }

        // The staged toast, or a retry-pending capture's warning, reopens the picker.
        if (!outsideSession && fromHotkey && (Coordinator.PendingWithToast ?? Coordinator.PendingWithRetryWarning) is { } pending && pending.Trigger == trigger && host.StagedToastVisible)
        {
            ShowTitlePicker(pending.Id);
            return;
        }

        _ = Coordinator.CommitPending();
        var fallback = Settings.ClipboardFallback == true;
        Coordinator.BeginAcquisition(async () =>
        {
            if (!await ClosePanelsAsync()) { return null; }
            if (trigger == CaptureTrigger.Selection)
            {
                var result = await selectionReader.ReadAsync(fallback, context);
                if (result.Capture is { } captured)
                {
                    CaptureObserved?.Invoke(CaptureTrigger.Selection, captured.Method == SelectionMethod.Clipboard ? "clipboard fallback" : "UI Automation", true);
                    return PendingCaptures.Selection(captured.Text, captured.Context.Source) with { OutsideSession = outsideSession };
                }

                SelectionFailed(result);
                return null;
            }

            try
            {
                var png = await new RegionCapturer().CaptureAsync();
                if (png is null) { return null; }
                var image = PendingCaptures.Image(png, null, context.Source) with { OutsideSession = outsideSession };
                Coordinator.RecordAcquiredImage(image);
                return image;
            }
            catch (Exception error)
            {
                Coordinator.Report(error, Strings.CouldNotCaptureArea);
                return null;
            }
        }, async acquired =>
        {
            if (acquired.Png is null) { return acquired; }
            var processed = await RegionProcessing.ProcessAsync(acquired.Png, acquired.Source, acquired.Id, acquired.CreatedAt, Recognize,
                Coordinator.RegisterDeferredOcr, log: message => log.Error(message));
            var found = processed.Content.Kind == CaptureContentKind.Text || !string.IsNullOrWhiteSpace(processed.Ocr);
            CaptureObserved?.Invoke(CaptureTrigger.Region, processed.Subtitle, found);
            return processed;
        });
    }

    /// OCR plus the classifier; null when the models are missing or recognition failed (the image is kept).
    private RegionRecognition? Recognize(byte[] png)
    {
        if (!Ocr.Value.IsAvailable)
        {
            log.Error(Ocr.Value.MissingModelReason);
            return null;
        }

        var result = Ocr.Value.Recognize(png);
        var classification = CaptureClassifier.Classify(result);
        log.Notice($"Region classifier: decision={classification.Decision} coverage={classification.Metrics.TextCoverage:0.###} lines={classification.Metrics.LineCount}");
        return new RegionRecognition(result.Text, classification.Decision == CaptureDecision.Text);
    }

    private void SelectionFailed(SelectionResult result)
    {
        if (result.Failure is SelectionFailure.OwnApp or SelectionFailure.Busy or SelectionFailure.Cancelled or null) { return; }
        log.Notice($"Selection capture refused: {result.Failure}{(result.Detail is { } detail ? $" ({detail})" : "")}");
        var area = BindingText(HotkeyAction.CaptureArea);
        var title = result.Message ?? PlatformStrings.NoTextSelected;
        var subtitle = result.HintForCaptureArea(area);
        if (result.Failure is SelectionFailure.NoSelection or SelectionFailure.TargetChanged)
        {
            subtitle = Strings.NoTextSelectedSubtitle(area);
        }

        Coordinator.ShowToast(new(AppToastStyle.Warning, title, subtitle));
    }

    /// Re-pressing the capture key on the staged toast chooses a destination.
    private void ShowTitlePicker(Guid id)
    {
        Coordinator.ClearToastMarker();
        Coordinator.Enqueue(async c =>
        {
            if (!await ClosePanelsAsync()) { c.RestoreRetryWarning(id, Strings.CouldNotKeepDraft); return; }
            if (c.Pending?.Id != id) { return; }
            var suggestions = await c.SuggestionSnapshotAsync(false);
            if (c.Pending?.Id != id || c.IsTerminating) { return; }
            // Bare titles match root notes only, so other and same-titled notes are picked by value and saved to that exact note.
            var picks = c.PickerChoices(suggestions);
            PresentInput(Strings.AddToNotePlaceholder, suggestions: suggestions,
                suggestionValue: picks.ValueOf, suggestionPath: picks.ValueOf,
                onAccept: text =>
                {
                    if (c.Pending?.Id != id) { return; }
                    if (picks.DestinationOf(text) is { } destination) { _ = c.CommitPending(destination: destination, announce: true); }
                    else { _ = c.CommitPending(text, true); }
                },
                onSubmit: _ => { },
                onCancel: () => { if (c.Pending is { } pending && pending.Id == id) { c.SettleUnchosenCapture(id, pending.OutsideSession); } });
        });
    }

    private void PresentInput(string placeholder, string? title = null, string? secondary = null,
        IReadOnlyList<NoteSuggestion>? suggestions = null, Action<string>? onAccept = null, Action<string>? onSubmit = null, Action? onCancel = null,
        Func<NoteSuggestion, string?>? suggestionValue = null, Func<NoteSuggestion, string?>? suggestionPath = null)
    {
        if (Coordinator.IsTerminating) { return; }
        var list = suggestions ?? [];
        var panel = new InputPanelController();
        input = panel;
        var zone = pipeline.TimeZone;
        panel.Present(new InputRequest(placeholder, prefix =>
        {
            var key = NoteTitle.MatchKey(prefix);
            return list.Where(s => key.Length == 0 || NoteTitle.MatchKey(s.Title).StartsWith(key, StringComparison.Ordinal)).Take(8)
                .Select(s =>
                {
                    var session = s.Kind == NoteKind.Session;
                    return new Suggestion(s.Title, Strings.SuggestionDetail(session, s.Modified, s.Path, zone, suggestionPath?.Invoke(s)), session ? "record.circle" : "doc.text", suggestionValue?.Invoke(s));
                }).ToArray();
        }, text => { InputClosed(); onSubmit?.Invoke(text); }, () => { InputClosed(); onCancel?.Invoke(); },
            Title: title, Secondary: secondary, OnAccept: onAccept));
    }

    private void InputClosed()
    {
        input = null;
        var waiters = inputCloseWaiters.ToArray();
        inputCloseWaiters.Clear();
        foreach (var waiter in waiters) { waiter.TrySetResult(); }
    }

    /// Closes the editor, input and search panels; false when the editor refuses to close (an unsaved draft write failed).
    private async Task<bool> ClosePanelsAsync()
    {
        if (!CloseEditor()) { return false; }
        if (input is { } panel)
        {
            var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            inputCloseWaiters.Add(closed);
            panel.Dismiss();
            await closed.Task;
        }

        if (search is not null)
        {
            var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            searchCloseWaiters.Add(closed);
            search.Dismiss();
            await closed.Task;
        }

        return true;
    }

    // Sessions.
    private void ToggleSession()
    {
        if (!RequireConsent()) { return; }
        Coordinator.Enqueue(async c =>
        {
            await c.SettleCapturesAsync();
            if (!await ClosePanelsAsync()) { return; }
            if (c.IsTerminating) { return; }
            var session = await Task.Run(() => pipeline.Sessions.Current());
            if (session is not null)
            {
                try { await c.EndSessionAsync(session); }
                catch (Exception error) { c.Report(error, Strings.CouldNotEndSession); }
                return;
            }

            var suggestions = await c.SuggestionSnapshotAsync(true);
            PresentInput(Strings.SessionNamePlaceholder, suggestions: suggestions, onSubmit: name => c.Enqueue(async inner =>
            {
                try { await inner.StartSessionAsync(name); }
                catch (SessionStoreException ambiguous) when (ambiguous.Kind == SessionStoreError.Ambiguous)
                {
                    PresentSessionCandidates(ambiguous.Candidates);
                }
                catch (Exception error) { inner.Report(error, Strings.CouldNotStartSession); }
            }));
        });
    }

    internal InputPanelController? InputForChecks => input;

    internal void PresentSessionCandidates(IReadOnlyList<SessionCandidate> candidates, string? selectedPath = null)
    {
        if (Coordinator.IsTerminating) { return; }
        var zone = pipeline.TimeZone;
        var choices = candidates.Select(c => new Suggestion(c.Name, Strings.CandidateSecondary(c.ModifiedAt, c.NotePath, zone), "record.circle", c.NotePath)).ToArray();
        var panel = new InputPanelController();
        input = panel;
        panel.Present(new InputRequest(Strings.SelectSessionPlaceholder, prefix =>
        {
            var key = NoteTitle.MatchKey(prefix);
            return choices.Where(s => key.Length == 0 || NoteTitle.MatchKey(s.Title).StartsWith(key, StringComparison.Ordinal)).ToArray();
        }, path =>
        {
            InputClosed();
            if (candidates.FirstOrDefault(c => c.NotePath == path) is not { } candidate) { return; }
            Coordinator.Enqueue(async c =>
            {
                try { await c.ResumeSessionAsync(candidate); }
                catch (Exception error) { c.Report(error, Strings.CouldNotResumeSession); }
            });
        }, InputClosed, Title: Strings.MultipleSessionsTitle, Secondary: Strings.SessionPickerHint,
            SelectionOnly: true, OnAlternateSubmit: path =>
            {
                InputClosed();
                if (candidates.FirstOrDefault(c => c.NotePath == path) is { } candidate)
                    PresentSessionRename(candidates, candidate);
            }, SelectedValue: selectedPath));
    }

    private void PresentSessionRename(IReadOnlyList<SessionCandidate> candidates, SessionCandidate candidate,
        string? initialText = null, string? errorMessage = null)
    {
        if (Coordinator.IsTerminating) { return; }
        var panel = new InputPanelController();
        input = panel;
        panel.Present(new InputRequest(Strings.SessionNamePlaceholder, _ => [], name =>
        {
            InputClosed();
            Coordinator.Enqueue(async c =>
            {
                if (c.IsTerminating) return;
                try { await c.RenameSessionAsync(candidate, name); }
                catch (Exception error)
                {
                    c.Report(error, Strings.CouldNotRenameSession);
                    // A committed move returns SessionRenameOutcome, including pending migration.
                    PresentSessionRename(candidates, candidate, name, Strings.RenameSessionErrorHint(error));
                }
            });
        }, InputClosed, InitialText: initialText ?? candidate.Name, Title: Strings.RenameSessionTitle,
            Secondary: errorMessage ?? Strings.RenameSessionHint, SelectInitialText: true, AllowEmptySubmission: true, OnEscape: () =>
            {
                InputClosed();
                PresentSessionCandidates(candidates, candidate.NotePath);
            }));
    }

    // Subheading.
    private void OpenSubheading()
    {
        if (!RequireConsent()) { return; }
        Coordinator.Enqueue(async c =>
        {
            await c.SettleCapturesAsync();
            if (!await ClosePanelsAsync()) { return; }
            if (c.IsTerminating) { return; }
            Destination destination;
            try
            {
                var active = await Task.Run(() => pipeline.Sessions.Current());
                destination = Router.Destination(null, active, [], pipeline.Vault);
            }
            catch (Exception error) { c.Report(error, Strings.CouldNotResolveDestination); return; }
            PresentInput(Strings.SubheadingPlaceholder, Strings.AddSubheadingTitle, Strings.InNote(destination.Title),
                onSubmit: text => c.Enqueue(async inner =>
                {
                    try { await inner.AddSubheadingAsync(text, destination); }
                    catch (Exception error) { inner.Report(error, Strings.CouldNotAddSubheading); }
                }));
        });
    }

    /// Until step 0 is answered no capture or panel runs.
    private bool RequireConsent()
    {
        if (Setup.ConsentAnswered) { return true; }
        Coordinator.ShowToast(new(AppToastStyle.Warning, Strings.FinishSetupToCaptureTitle, Strings.OpenTraySetup));
        return false;
    }
}
