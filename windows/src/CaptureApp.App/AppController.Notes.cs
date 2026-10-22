using System.IO;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Overlay;
using CaptureApp.Platform.Shell;

namespace CaptureApp.App;

internal sealed partial class AppController
{
    private readonly QuickNoteController quickNote = new();

    private bool CloseEditor()
    {
        if (!quickNote.IsVisible) { return true; }
        quickNote.Dismiss();
        return !quickNote.IsVisible;
    }

    private bool DismissEditorForQuit() => CloseEditor();

    private string? NoteId(Destination? destination)
    {
        if (destination is null) { return null; }
        try { return pipeline.Vault.NoteId(destination.Url); }
        catch (Exception) { return null; }
    }

    private bool IsPinned(Destination? destination, bool fallback) => NoteId(destination) is { } id ? pipeline.Pins.IsPinned(id) : fallback;

    private void OpenNoteEditor()
    {
        if (!RequireConsent()) { return; }
        Coordinator.Enqueue(async c =>
        {
            if (quickNote.IsVisible)
            {
                // Visible but inactive re-activates in place; active closes and keeps the draft.
                if (quickNote.IsActive) { quickNote.Dismiss(); } else { quickNote.Focus(); }
                return;
            }

            var pendingCommit = c.CommitPending();
            await c.WaitForProcessingAsync();
            var processedCommit = c.CommitPending();
            if (!await ClosePanelsAsync()) { return; }
            try
            {
                if (pendingCommit is not null) { await pendingCommit; }
                if (processedCommit is not null) { await processedCommit; }
                if (c.CommitTail is { } tail) { await tail; }
            }
            catch (Exception error) { c.Report(error, Strings.CouldNotSavePending); return; }
            if (c.IsTerminating) { return; }

            Destination? sessionDestination;
            try
            {
                var active = await Task.Run(() => pipeline.Sessions.Current());
                sessionDestination = active is null ? null : Router.Destination(null, active, [], pipeline.Vault);
            }
            catch (Exception error) { c.Report(error, Strings.CouldNotResolveDestination); return; }

            try
            {
                var restored = pipeline.Drafts.LoadSnapshot();
                var state = new QuickNoteState(sessionDestination, restored.PinOnSave);
                quickNote.PositionStore ??= new SettingsPanelPositionStore(Settings);
                quickNote.Present(sessionDestination?.Title, IsPinned(sessionDestination, state.PinOnSave), restored.Text, NoteHandlers(c, state, sessionDestination));
                _ = Task.Run(async () =>
                {
                    var list = await c.SuggestionSnapshotAsync(false);
                    await dispatcher.InvokeAsync(() =>
                    {
                        if (c.IsTerminating) { return; }
                        state.Suggestions = list;
                        quickNote.RefreshBrowseItems();
                    });
                });
            }
            catch (Exception error) { c.Report(error, Strings.CouldNotRestoreDraft); }
        });
    }

    private QuickNoteHandlers NoteHandlers(CaptureCoordinator c, QuickNoteState state, Destination? sessionDestination)
    {
        var zone = pipeline.TimeZone;
        void RefreshDestination() => quickNote.SetDestination(state.Destination?.Title, IsPinned(state.Destination, false));
        Task<SavedCapture?> Save(string text, bool newNote = false) => c.AddNoteAsync(text, state.Destination, state.PinOnSave, newNote);

        return new QuickNoteHandlers(
            OnDraft: text =>
            {
                var blank = string.IsNullOrWhiteSpace(text);
                pipeline.Drafts.FlushScheduledStore(text, blank ? false : state.PinOnSave);
                if (blank) { state.ResetPinOnSave(pipeline.Drafts); RefreshDestination(); }
            },
            OnSubmit: text => c.Enqueue(async inner =>
            {
                try { await Save(text); }
                catch (Exception error) { inner.ReportUserSaveFailure(error, Strings.CouldNotAddNote); }
            }),
            OnNew: text =>
            {
                if (string.IsNullOrWhiteSpace(text))
                {
                    try { state.ResetPinOnSave(pipeline.Drafts); }
                    catch (Exception error) { c.Report(error, Strings.CouldNotResetDraftPin); return; }
                    state.Destination = sessionDestination;
                    quickNote.SetDestination(sessionDestination?.Title, IsPinned(sessionDestination, false));
                    return;
                }

                c.Enqueue(async inner =>
                {
                    try { await Save(text); OpenNoteEditor(); }
                    catch (Exception error) { inner.ReportUserSaveFailure(error, Strings.CouldNotAddNote); }
                });
            },
            OnOpenAsNote: text => c.Enqueue(async inner =>
            {
                try
                {
                    if (!string.IsNullOrWhiteSpace(text))
                    {
                        if (await Save(text) is { } saved) { OpenNote(saved.Destination.Url); return; }
                    }
                    else if (state.Destination?.Url is { } url && File.Exists(url))
                    {
                        OpenNote(url);
                        return;
                    }

                    inner.ShowToast(new(AppToastStyle.Warning, Strings.NothingToOpen, Strings.WriteSomethingFirst));
                }
                catch (Exception error) { inner.ReportUserSaveFailure(error, Strings.CouldNotAddNote); }
            }),
            BrowseItems: () =>
            {
                var pinned = pipeline.Pins.Paths();
                return state.Suggestions.OrderByDescending(s => s.Modified).Select(s =>
                {
                    var session = s.Kind == NoteKind.Session;
                    return new BrowseItem(s.Path, s.Title, Strings.BrowseDetail(session, s.Modified, zone), session ? "record.circle" : "doc.text", pinned.Contains(s.Path));
                }).ToArray();
            },
            OnBrowse: (item, choice) =>
            {
                switch (choice)
                {
                    case BrowseChoice.Write:
                        try { state.ResetPinOnSave(pipeline.Drafts); }
                        catch (Exception error) { c.Report(error, Strings.CouldNotResetDraftPin); return; }
                        try
                        {
                            var location = pipeline.Vault.NoteLocation(item.Id);
                            state.Destination = new Destination(location.Url, item.Title, state.Kinds.GetValueOrDefault(item.Id, NoteKind.Note));
                        }
                        catch (Exception error) { c.Report(error, Strings.CouldNotSelectNote); return; }
                        quickNote.SetDestination(item.Title, pipeline.Pins.IsPinned(item.Id));
                        break;
                    case BrowseChoice.Open:
                        try { OpenNote(pipeline.Vault.NoteLocation(item.Id).Url); }
                        catch (Exception error) { c.Report(error, Strings.CouldNotOpenNote); }
                        break;
                    case BrowseChoice.Reveal:
                        try { RevealNote(pipeline.Vault.NoteLocation(item.Id).Url); }
                        catch (Exception error) { c.Report(error, Strings.CouldNotRevealNote); }
                        break;
                }
            },
            OnTogglePin: () =>
            {
                try
                {
                    if (state.Destination is not { } destination) { return state.TogglePinOnSave(pipeline.Drafts); }
                    if (NoteId(destination) is not { } id) { return false; }
                    return File.Exists(destination.Url) ? pipeline.Pins.Toggle(id) : state.TogglePinOnSave(pipeline.Drafts);
                }
                catch (Exception error)
                {
                    c.Report(error, Strings.CouldNotUpdatePinned);
                    return IsPinned(state.Destination, state.PinOnSave);
                }
            },
            OnClose: () => { },
            OnError: error => c.Report(error, Strings.CouldNotKeepDraft),
            TitleForText: text => new TypedNote(text, DateTimeOffset.Now, zone, pipeline.Vault.NamingRules).Title,
            OnScheduleDraft: text =>
            {
                var blank = string.IsNullOrWhiteSpace(text);
                pipeline.Drafts.ScheduleStore(text, blank ? false : state.PinOnSave,
                    error => dispatcher.BeginInvoke(() => c.Report(error, Strings.CouldNotKeepDraft)));
                if (blank) { state.ResetPinOnSave(pipeline.Drafts); RefreshDestination(); }
            },
            ExistingTitleForText: text =>
            {
                // Session and Browse destinations take precedence over typed-name matching, as in PrepareNote.
                if (sessionDestination is not null || state.Destination is not null) return null;
                try
                {
                    var note = new TypedNote(text, DateTimeOffset.Now, zone, pipeline.Vault.NamingRules);
                    return CaptureService.AppendTarget(note, pipeline.Service.ReservedNoteUrls, pipeline.Vault)?.Title;
                }
                catch (Exception) { return null; } // Invalid or unavailable paths are reported when saving.
            },
            OnSaveAsNew: text => c.Enqueue(async inner =>
            {
                try { await Save(text, newNote: true); }
                catch (Exception error) { inner.ReportUserSaveFailure(error, Strings.CouldNotAddNote); }
            }));
    }

    private void OpenNote(string url)
    {
        try { ExplorerShell.Open(url); }
        catch (Exception error) { Coordinator.Report(error, Strings.CouldNotOpenNote); }
    }

    private void RevealNote(string url)
    {
        try { ExplorerShell.Reveal(url); }
        catch (Exception error) { Coordinator.Report(error, Strings.CouldNotRevealNote); }
    }
}
