using System.IO;
using System.Diagnostics;
using System.Windows.Threading;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Overlay;
using CaptureApp.Platform;
using CaptureApp.Platform.Context;
using CaptureApp.Platform.Hotkeys;
using CaptureApp.Platform.Shell;
using CaptureApp.Platform.Tray;
using CaptureApp.Updates;

namespace CaptureApp.App;

internal sealed partial class AppController
{
    private IReadOnlyDictionary<HotkeyAction, KeyChord> Bindings { get; set; } = HotkeyDefaults.All;
    private readonly Dictionary<HotkeyAction, HotkeyRegistrationResult> failures = [];

    internal IReadOnlyDictionary<HotkeyAction, HotkeyRegistrationResult> ShortcutFailures => failures;

    private void LoadBindings()
    {
        try { Bindings = BindingStore.Load(); }
        catch (InvalidDataException error)
        {
            // A saved binding that fails validation falls back to the defaults; the file is left as written.
            log.Error($"Shortcut settings were invalid; using defaults: {error.Message}");
            Bindings = HotkeyDefaults.All;
        }
    }

    internal IReadOnlyList<string> FailedShortcutNames() => failures.Keys.Select(action => action.ToString()).ToArray();

    // Hotkeys. Callbacks arrive on the registrar's message thread, so each captures its context first.
    internal void RegisterHotkeys()
    {
        hotkeys ??= new HotkeyRegistrar();
        hotkeys.UnregisterAll();
        failures.Clear();
        LoadBindings();
        var disabled = Settings.DisabledShortcuts;
        var handlers = new Dictionary<HotkeyAction, Action>
        {
            [HotkeyAction.CaptureSelection] = () => { var context = FrontmostContext.Capture(); dispatcher.BeginInvoke(() => Capture(CaptureTrigger.Selection, true, context)); },
            [HotkeyAction.CaptureArea] = () => { var context = FrontmostContext.Capture(); dispatcher.BeginInvoke(() => Capture(CaptureTrigger.Region, true, context)); },
            [HotkeyAction.CaptureSelectionOutsideSession] = () => { var context = FrontmostContext.Capture(); dispatcher.BeginInvoke(() => Capture(CaptureTrigger.Selection, true, context, outsideSession: true)); },
            [HotkeyAction.CaptureAreaOutsideSession] = () => { var context = FrontmostContext.Capture(); dispatcher.BeginInvoke(() => Capture(CaptureTrigger.Region, true, context, outsideSession: true)); },
            [HotkeyAction.SearchNotes] = () => dispatcher.BeginInvoke(OpenSearch),
            [HotkeyAction.ToggleSession] = () => dispatcher.BeginInvoke(ToggleSession),
            [HotkeyAction.WriteNote] = () => dispatcher.BeginInvoke(OpenNoteEditor),
            [HotkeyAction.AddSubheading] = () => dispatcher.BeginInvoke(OpenSubheading),
            [HotkeyAction.OpenNotesFolder] = () => dispatcher.BeginInvoke(OpenNotesFolder)
        };
        foreach (var (action, handler) in handlers)
        {
            if (disabled.Contains(action.ToString())) { continue; }
            var chord = Bindings[action];
            if (!AltGrGuard.IsSafe(chord))
            {
                failures[action] = new HotkeyRegistrationResult(action, chord, false, 0,
                    "This combination types a letter on an installed keyboard layout (AltGr).");
                continue;
            }

            var result = hotkeys.Register(action, chord, handler);
            if (!result.Succeeded) { failures[action] = result; log.Error($"Hotkey {action} {chord.DisplayString} failed ({result.Win32Error})"); }
        }

        RefreshMenu();
        if (failures.Count > 0)
        {
            Coordinator?.ShowToast(new(AppToastStyle.Warning, Strings.ShortcutsUnavailableTitle, Strings.ShortcutsUnavailableSubtitle, Duration: 6));
        }
    }

    // Tray.
    private void InstallTray()
    {
        tray = new TrayIcon(id => dispatcher.BeginInvoke(() => OnMenu(id)), TrayIconAssets.FindDefault());
        tray.MenuDispatchFailed += error => log.Error($"Tray menu dispatch failed: {error.Message}");
    }

    internal void RefreshMenu()
    {
        if (tray is null || disposed) { return; }
        var entries = TrayMenuBuilder.Build(BuildMenuState());
        tray.Menu = new TrayMenuModel(entries.Select(ToTray));
        tray.SetAttention(Setup.NeedsAttention);
    }

    private static TrayMenuItem ToTray(MenuEntry entry) => entry.IsSeparator
        ? TrayMenuItem.Separator()
        : new TrayMenuItem(entry.Id, entry.Title, entry.Shortcut, entry.Enabled, entry.Checked, entry.Children?.Select(ToTray).ToArray());

    private MenuState BuildMenuState()
    {
        var bindings = new Dictionary<string, string>
        {
            [MenuIds.CaptureSelection] = BindingText(HotkeyAction.CaptureSelection),
            [MenuIds.CaptureArea] = BindingText(HotkeyAction.CaptureArea),
            [MenuIds.Search] = BindingText(HotkeyAction.SearchNotes),
            [MenuIds.Session] = BindingText(HotkeyAction.ToggleSession),
            [MenuIds.WriteNote] = BindingText(HotkeyAction.WriteNote),
            [MenuIds.AddSubheading] = BindingText(HotkeyAction.AddSubheading),
            [MenuIds.OpenFolder] = BindingText(HotkeyAction.OpenNotesFolder)
        };
        foreach (var action in failures.Keys)
        {
            var id = action switch
            {
                HotkeyAction.CaptureSelection => MenuIds.CaptureSelection,
                HotkeyAction.CaptureArea => MenuIds.CaptureArea,
                HotkeyAction.SearchNotes => MenuIds.Search,
                HotkeyAction.ToggleSession => MenuIds.Session,
                HotkeyAction.WriteNote => MenuIds.WriteNote,
                HotkeyAction.AddSubheading => MenuIds.AddSubheading,
                HotkeyAction.OpenNotesFolder => MenuIds.OpenFolder,
                _ => null
            };
            if (id is not null) bindings[id] = "";
        }

        return new MenuState(Setup.ConsentAnswered, Setup.AttentionCount, Coordinator?.ActiveSession?.Name, bindings, failures.Count,
            CurrentSemanticMenu(), CurrentUpdateMenu());
    }

    private void OnMenu(string id)
    {
        if (quitting) { return; }
        switch (id)
        {
            case MenuIds.FinishSetup: OpenSetup(manual: true); break;
            case MenuIds.CaptureSelection: AfterMenu(() => _ = CaptureSelectionFromMenuAsync()); break;
            case MenuIds.CaptureArea: AfterMenu(() => Capture(CaptureTrigger.Region, false, FrontmostContext.Capture())); break;
            case MenuIds.Search: OpenSearch(); break;
            case MenuIds.Session: ToggleSession(); break;
            case MenuIds.WriteNote: OpenNoteEditor(); break;
            case MenuIds.AddSubheading: OpenSubheading(); break;
            case MenuIds.RetryShortcuts: RegisterHotkeys(); break;
            case MenuIds.OpenFolder: OpenNotesFolder(); break;
            case MenuIds.Semantic: ActivateSemanticMenu(); break;
            case MenuIds.RemoveModels: ConfirmRemoveModels(); break;
            case MenuIds.Setup: OpenSetup(manual: true); break;
            case MenuIds.Settings: OpenSettings(); break;
            case MenuIds.CheckUpdates:
            case MenuIds.RetryUpdate: CheckForUpdates(); break;
            case MenuIds.RestartToUpdate: RequestQuit(restartForUpdate: true); break;
            case MenuIds.DownloadInstaller: DownloadInstaller(); break;
            case MenuIds.Quit: RequestQuit(); break;
        }
    }

    /// Lets the tray menu release the foreground before the capture reads the frontmost window.
    private void AfterMenu(Action action)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            try { action(); }
            catch (Exception error) { log.Error($"Tray command failed ({error.GetType().Name}): {error}"); }
        };
        timer.Start();
    }

    private async Task CaptureSelectionFromMenuAsync()
    {
        try
        {
            await menuCapture.RunAsync(
                hadTarget => Coordinator.ShowToast(hadTarget
                    ? new(AppToastStyle.Warning, PlatformStrings.CouldNotCapture)
                    : new(AppToastStyle.Warning, PlatformStrings.NoTextSelected, Strings.NoTextSelectedSubtitle(BindingText(HotkeyAction.CaptureArea)))),
                context => Capture(CaptureTrigger.Selection, false, context));
        }
        catch (Exception error)
        {
            log.Error($"Tray Capture Selection failed ({error.GetType().Name}): {error}");
        }
    }

    private void OpenNotesFolder()
    {
        if (!FolderWritable && !Directory.Exists(pipeline.Vault.Root))
        {
            Coordinator.ShowToast(new(AppToastStyle.Warning, Strings.NotesFolderUnavailableTitle, Strings.OpenTraySetup));
            return;
        }

        try { ExplorerShell.Open(pipeline.Vault.Root); }
        catch (Exception error) { Coordinator.Report(error, Strings.CouldNotOpenFolder); }
    }

    internal void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); }
        catch (Exception error) { log.Error($"Could not open a link: {error.GetType().Name}"); }
    }
}
