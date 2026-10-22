using System.IO;
using System.Windows;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Platform.Hotkeys;

namespace CaptureApp.App;

internal sealed partial class AppController
{
    private SetupWindow? setupWindow;
    private SettingsWindow? settingsWindow;

    /// Raised by capture flows so the Setup tests can observe a real capture: (trigger, method or detail, OCR text found).
    internal event Action<CaptureTrigger, string, bool>? CaptureObserved;

    internal void OpenSetup(bool manual)
    {
        if (quitting) { return; }
        // A launch-time reopen happens once per launch; a manual open always works.
        if (!manual)
        {
            if (openedSetupThisLaunch) { return; }
            openedSetupThisLaunch = true;
        }

        if (setupWindow is { } open)
        {
            open.Activate();
            return;
        }

        Setup.Reload();
        var window = new SetupWindow(this, manual);
        setupWindow = window;
        window.Closed += (_, _) =>
        {
            setupWindow = null;
            try { Setup.AcknowledgeVersion(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { log.Error($"Setup version could not be saved: {error.Message}"); }
            RefreshMenu();
        };
        window.Show();
        window.Activate();
    }

    internal void OpenSettings(int tab = 0)
    {
        if (quitting) { return; }
        if (settingsWindow is { } open)
        {
            open.SelectTab(tab);
            open.Activate();
            return;
        }

        var window = new SettingsWindow(this, tab);
        settingsWindow = window;
        window.Closed += (_, _) => settingsWindow = null;
        window.Show();
        window.Activate();
    }

    /// Setup or Settings changed something the tray shows.
    internal void OnSetupChanged() => RefreshMenu();

    /// Step 0 was answered: hotkeys come alive and the update schedule follows the choice.
    internal void OnConsentAnswered()
    {
        RegisterHotkeys();
        RefreshMenu();
        if (updates is { IsEnabled: true } && Settings.UpdatesChoice != UpdatesChoice.Manual && !updateSchedulerStarted)
        {
            updateSchedulerStarted = true;
            _ = Task.Run(async () =>
            {
                try { await updates.RunAutomaticChecksAsync(lifetime.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { }
            });
        }
    }

    private bool updateSchedulerStarted;

    internal bool IsRegistered(HotkeyAction action) => hotkeys is not null && Setup.ConsentAnswered && !failures.ContainsKey(action)
                                                       && !Settings.DisabledShortcuts.Contains(action.ToString());

    internal void PauseHotkeys() => hotkeys?.UnregisterAll();

    /// null when the combination can be used; otherwise the reason.
    internal string? ValidateBinding(HotkeyAction action, KeyChord chord)
    {
        var validation = HotkeyValidator.Validate(chord);
        if (!validation.IsValid) { return validation.Error; }
        if (folderBindings.Any(binding => binding.Shortcut == chord))
            return "This combination is already used by a folder shortcut.";
        if (!AltGrGuard.IsSafe(chord))
        {
            var suggestion = AltGrGuard.FindNextFreeLetter(Bindings.Values);
            return "This combination types a letter on an installed keyboard layout (AltGr)." +
                   (suggestion is { } letter ? $" Try {letter.DisplayString}." : "");
        }

        foreach (var (other, existing) in Bindings)
        {
            if (other != action && existing == chord && !Settings.DisabledShortcuts.Contains(other.ToString()))
            {
                return $"{existing.DisplayString} is already used by another shortcut.";
            }
        }

        return null;
    }

    /// Test-registers the combination before saving it (§4 guard 3).
    internal HotkeyRegistrationResult TrySaveBinding(HotkeyAction action, KeyChord chord)
    {
        hotkeys ??= new HotkeyRegistrar();
        if (ValidateBinding(action, chord) is { } error) { return new(action, chord, false, 87, error); }
        try
        {
            var result = BindingStore.SaveIfAvailable(action, chord, hotkeys);
            if (result.Succeeded)
            {
                var set = Settings.DisabledShortcuts.ToHashSet(StringComparer.Ordinal);
                if (set.Remove(action.ToString())) { TrySave(() => Settings.DisabledShortcuts = set); }
                LoadBindings();
            }

            return result;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            if (exception is not InvalidDataException) { ReportSaveFailure(exception); }
            return new(action, chord, false, 0, exception.Message);
        }
    }

    /// Runs a user-triggered settings save. A locked or unwritable settings.json is logged and shown as a toast;
    /// false means nothing was saved, so the caller must keep showing the previous value.
    internal bool TrySave(Action save)
    {
        try { save(); return true; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            ReportSaveFailure(error);
            return false;
        }
    }

    internal void ReportSaveFailure(Exception error)
    {
        log.Error($"Settings could not be saved ({error.GetType().Name}): {error.Message}");
        Coordinator?.ShowToast(new(AppToastStyle.Warning, Strings.CouldNotSaveSettings, Strings.CouldNotSaveSettingsHint));
    }

    internal bool MarkSetup(SetupStepId id, SetupStatus status, string? detail = null)
    {
        var saved = TrySave(() => Setup.Mark(id, status, detail));
        if (saved) { RefreshMenu(); }
        return saved;
    }

    internal bool ApplyStartAtLogin(bool enabled)
    {
        var previous = LoginItem.IsEnabled;
        LoginItem.SetEnabled(enabled);
        if (TrySave(() => Settings.StartAtLogin = enabled)) { return true; }
        // Keep the Run key in step with the saved choice.
        try { LoginItem.SetEnabled(previous); }
        catch (Exception error) when (error is InvalidOperationException or UnauthorizedAccessException or System.Security.SecurityException) { }
        return false;
    }

    internal bool ApplyUpdatesChoice(UpdatesChoice choice)
    {
        if (!TrySave(() => Settings.UpdatesChoice = choice)) { return false; }
        RefreshMenu();
        return true;
    }

    internal bool ApplyClipboardFallback(bool enabled) => TrySave(() => Settings.ClipboardFallback = enabled);

    internal bool SaveNotesFolder(string folder, out string? error)
    {
        string path;
        try { path = NotesFolderChoice.Probe(folder); }
        catch (Exception failure) when (NotesFolderPicker.IsFolderError(failure))
        {
            error = $"Can't write to that folder: {failure.Message}";
            return false;
        }

        if (!TrySave(() => Settings.NotesFolder = path))
        {
            error = Strings.CouldNotSaveSettings;
            return false;
        }

        error = null;
        return true;
    }

    private bool choosingNotesFolder;

    internal string? PickNotesFolder(Window? owner, string initialFolder, out string? error, bool appliesOnRestart = true)
    {
        error = null;
        if (choosingNotesFolder) { return null; }
        choosingNotesFolder = true;
        try
        {
            return NotesFolderPicker.Choose(owner, initialFolder, appliesOnRestart);
        }
        catch (Exception failure) when (NotesFolderPicker.IsFolderError(failure))
        {
            error = $"Couldn't open the folder picker: {failure.Message}";
            return null;
        }
        finally { choosingNotesFolder = false; }
    }

    private void ChooseNotesFolder()
    {
        var folder = PickNotesFolder(null, CurrentNotesFolder, out var error);
        if (folder is null)
        {
            if (error is not null) { Coordinator.ShowToast(new(AppToastStyle.Warning, "Couldn't choose notes folder", error)); }
            return;
        }

        if (!SaveNotesFolder(folder, out error))
        {
            Coordinator.ShowToast(new(AppToastStyle.Warning, "Couldn't change notes folder", error));
            return;
        }

        Coordinator.ShowToast(new(AppToastStyle.Success, "Notes folder saved", NotesFolderChangeMessage, Duration: 8));
    }

    internal string CurrentNotesFolder => Settings.NotesFolder ?? Path.Combine(Platform.Shell.KnownFolders.Documents, AppInfo.Name);

    internal bool NotesFolderNeedsRestart => pipeline is not null && !NotesFolderChoice.SameFolder(CurrentNotesFolder, pipeline.Vault.Root);

    internal string NotesFolderChangeMessage => NotesFolderNeedsRestart
        ? "Restart the app to use this folder. Existing notes stay in their current folder."
        : "This folder is already in use. Existing notes stay in place.";

    internal IReadOnlyList<CapabilityStatus> CapabilityTable() => Capabilities.Evaluate(new CapabilityInputs(
        Setup.ConsentAnswered,
        7 - failures.Count - Settings.DisabledShortcuts.Count,
        failures.Count,
        Settings.DisabledShortcuts.Count,
        Settings.ClipboardFallback,
        FolderWritable,
        Ocr.IsValueCreated ? Ocr.Value.IsAvailable : null,
        Settings.StartAtLogin,
        LoginItem.IsEnabled,
        updates?.IsEnabled == true,
        Settings.UpdatesChoice));
}
