using System.IO;
using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Semantic;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Embed;
using CaptureApp.ModelInstall;
using CaptureApp.Overlay;
using CaptureApp.Overlay.Interop;
using CaptureApp.Platform.Capture;
using CaptureApp.Platform.Hotkeys;
using CaptureApp.Platform.Ocr;
using CaptureApp.Platform.Power;
using CaptureApp.Platform.Selection;
using CaptureApp.Platform.Shell;
using CaptureApp.Platform.Tray;
using CaptureApp.Updates;

namespace CaptureApp.App;

/// Port of AppController.swift. The WPF-facing half: tray, hotkeys, panels, windows. The capture state machine
/// lives in <see cref="CaptureCoordinator"/>; setup, menu and string logic live in AppCore.Shell.
internal sealed partial class AppController : IDisposable
{
    private readonly Application app;
    private readonly Dispatcher dispatcher;
    private readonly string stateDirectory;
    private readonly AppLog log;
    private readonly CancellationTokenSource lifetime = new();
    private readonly bool firstRun;
    private CapturePipeline pipeline = null!;
    private UiHost host = null!;
    private TrayIcon? tray;
    private HotkeyRegistrar? hotkeys;
    private PowerMonitor? power;
    private SemanticIndexer? semantic;
    private bool openedSetupThisLaunch;
    private readonly ForegroundTracker foreground;
    private readonly MenuCaptureFlow menuCapture;
    private readonly FocusReturnTracker focusProbe = new();
    private bool quitting;
    private bool disposed;

    public AppController(Application app, string stateDirectory, bool firstRun)
    {
        this.app = app;
        dispatcher = app.Dispatcher;
        this.stateDirectory = stateDirectory;
        this.firstRun = firstRun;
        log = new(stateDirectory, "app");
        foreground = new ForegroundTracker(message => log.Error(message));
        SettingsPath = Path.Combine(stateDirectory, "settings.json");
        Settings = new SettingsStore(SettingsPath);
        Setup = new SetupState(Settings);
        BindingStore = new HotkeyBindingStore(SettingsPath);
        LoginItem = new LoginItem();
        Ocr = new Lazy<RapidOcrEngine>(() => new RapidOcrEngine());
        menuCapture = new MenuCaptureFlow(new WindowsForegroundProbe(foreground, focusProbe));
    }

    internal AppController(Application app, string stateDirectory, CapturePipeline testPipeline)
        : this(app, stateDirectory, firstRun: false)
    {
        pipeline = testPipeline;
        Coordinator = new(testPipeline, new HeadlessCaptureHost());
        Coordinator.ChooseNoteRequested = id => dispatcher.BeginInvoke(() => ShowTitlePicker(id));
    }

    public string SettingsPath { get; }
    public SettingsStore Settings { get; }
    public SetupState Setup { get; }
    public HotkeyBindingStore BindingStore { get; }
    public LoginItem LoginItem { get; }
    public Lazy<RapidOcrEngine> Ocr { get; }
    public CaptureCoordinator Coordinator { get; private set; } = null!;
    public CapturePipeline Pipeline => pipeline;

    /// Opens the vault, tray and services, then shows Setup when it is due.
    public async Task StartAsync()
    {
        try
        {
            var root = Settings.NotesFolder ?? Path.Combine(KnownFolders.Documents, AppInfo.Name);
            // Reserve legacy recovery/session state for the original folder before a recovery choice is saved.
            _ = await Task.Run(() => StatePaths.ForNotesFolder(stateDirectory, root)).ConfigureAwait(true);
            while (true)
            {
                var folder = await Task.Run(() => ProbeNotesFolder(root)).ConfigureAwait(true);
                if (folder.Ok) { break; }
                var choice = MessageBox.Show($"{AppInfo.Name} can't write to this notes folder:\n\n{root}\n\n{folder.Cause}\n\nChoose another folder to continue. Existing notes stay in their current folder.",
                    Strings.NotesFolderUnavailableTitle, MessageBoxButton.OKCancel, MessageBoxImage.Warning);
                if (choice != MessageBoxResult.OK) { app.Shutdown(); return; }
                var selected = PickNotesFolder(null, root, out var error, appliesOnRestart: false);
                if (selected is null)
                {
                    if (error is not null) { MessageBox.Show(error, AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning); }
                    app.Shutdown();
                    return;
                }

                if (!SaveNotesFolder(selected, out error))
                {
                    MessageBox.Show(error, AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning);
                    continue;
                }

                root = CurrentNotesFolder;
            }

            var models = Path.Combine(stateDirectory, "models");
            pipeline = await Task.Run(() => CapturePipeline.Open(root,
                StatePaths.ForNotesFolder(stateDirectory, root), TimeZoneInfo.Local, models)).ConfigureAwait(true);
        }
        catch (Exception error)
        {
            log.Error($"Startup failed ({error.GetType().Name}): {error}");
            MessageBox.Show($"{AppInfo.Name} couldn't start.\n\n{error.Message}\n\nYour notes and app state were left in place. Check the folder and app-state permissions before trying again.",
                AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning);
            app.Shutdown();
            return;
        }

        host = new UiHost(dispatcher, trigger => BindingText(trigger == CaptureTrigger.Selection ? HotkeyAction.CaptureSelection : HotkeyAction.CaptureArea),
            () => BindingText(HotkeyAction.ToggleSession), RefreshMenu);
        Coordinator = new CaptureCoordinator(pipeline, host);
        Coordinator.ChooseNoteRequested = id => dispatcher.BeginInvoke(() => ShowTitlePicker(id));
        host.OnExpire = Coordinator.ToastExpired;
        LoadBindings();
        LoadFolderBindings();
        InstallTray();
        InitializeSemantic();
        pipeline.Monitor.RefreshRequested += OnVaultRefresh;
        app.SessionEnding += OnSessionEnding;
        Revalidate();
        if (Setup.ConsentAnswered) { RegisterHotkeys(); }
        RefreshMenu();

        try { await Coordinator.StartAsync().ConfigureAwait(true); }
        catch (Exception error) { log.Error($"Journal replay failed: {error}"); }
        RefreshMenu();
        try { Pipeline.Vault.ValidateExternalNoteRegistry(); }
        catch (Exception error) { Coordinator.ReportExternalRegistryProblem(error, false); }
        pipeline.Monitor.Start();
        _ = Task.Run(async () =>
        {
            try
            {
                await pipeline.SyncAsync().ConfigureAwait(false);
                await pipeline.BackfillAsync().ConfigureAwait(false);
            }
            catch (Exception error) { log.Error($"Initial index sync failed: {error.GetType().Name}"); }
        });
        StartUpdates();
        log.Notice($"Ready: vault={pipeline.Vault.Root}");

        if (Setup.ShouldOpenOnLaunch(firstRun)) { OpenSetup(manual: false); }
    }

    public string BindingText(HotkeyAction action) =>
        Settings.DisabledShortcuts.Contains(action.ToString()) ? "" : (Bindings.TryGetValue(action, out var chord) ? chord : HotkeyDefaults.For(action)).DisplayString;

    /// Called when a second instance asks the running one to show itself.
    public void ShowRequested() => dispatcher.BeginInvoke(() =>
    {
        if (disposed || quitting) { return; }
        if (Setup.NeedsAttention) { OpenSetup(manual: true); }
        else { Coordinator.ShowToast(new(AppToastStyle.Success, $"{AppInfo.Name} is already running", "Open the tray icon for commands")); }
    });

    private void Revalidate()
    {
        var folder = ProbeNotesFolder(pipeline.Vault.Root);
        var report = new RevalidationReport(
            folder.Ok,
            Setup.ConsentAnswered ? FailedShortcutNames() : [],
            Settings.StartAtLogin == true ? LoginItem.IsEnabled : null,
            Settings.UpdatesChoice is not null);
        FolderWritable = folder.Ok;
        if (!Setup.ConsentAnswered) { return; }
        IReadOnlyList<SetupStepId> regressed;
        try { regressed = Setup.Revalidate(report); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Automatic: the next launch re-checks.
            log.Error($"Setup re-validation could not be saved: {error.Message}");
            return;
        }

        if (regressed.Count > 0)
        {
            Coordinator.ShowToast(new(AppToastStyle.Warning, Strings.SetupNeedsAttentionTitle, Strings.OpenTraySetup));
        }
    }

    internal bool FolderWritable { get; private set; } = true;

    /// Writes and removes a probe file. A failure carries the cause for the Setup page.
    internal static (bool Ok, string? Cause) ProbeNotesFolder(string folder)
    {
        try
        {
            _ = NotesFolderChoice.Probe(folder);
            return (true, null);
        }
        catch (Exception error) when (NotesFolderPicker.IsFolderError(error))
        {
            return (false, error.Message);
        }
    }

    // Quit and the shutdown drain.
    public void RequestQuit(bool restartForUpdate = false) => _ = QuitAsync(restartForUpdate);

    private async Task QuitAsync(bool restartForUpdate)
    {
        if (quitting) { return; }
        // A failed final draft write must leave the app usable for a retry.
        if (!DismissEditorForQuit()) { return; }
        quitting = true;
        PrepareTermination();
        try { await Coordinator.BeginTermination().ConfigureAwait(true); }
        catch (Exception error) { log.Error($"Shutdown drain failed: {error.GetType().Name}"); }
        FinishQuit(restartForUpdate);
    }

    private void PrepareTermination()
    {
        lifetime.Cancel();
        hotkeys?.UnregisterAll();
        input?.Dismiss(DismissReason.Quit);
        search?.Dismiss(DismissReason.Quit);
        setupWindow?.Close();
        settingsWindow?.Close();
        CancelModelDownload();
        power?.Stop();
    }

    private void FinishQuit(bool restartForUpdate)
    {
        var update = updates;
        if (update?.Snapshot.Status == UpdateStatus.ReadyToRestart)
        {
            // Both run after the drain; ApplyAndRestart ends this process itself.
            if (restartForUpdate) { update.ApplyAndRestart(); }
            else { update.ApplyOnExit(); }
        }

        Dispose();
        app.Shutdown();
    }

    private void OnSessionEnding(object sender, SessionEndingCancelEventArgs e)
    {
        if (quitting) { return; }
        quitting = true;
        PrepareTermination();
        var drain = Coordinator.BeginTermination();
        UiWait.Pump(drain, TimeSpan.FromSeconds(5));
        ApplyUpdateOnExitIfReady();
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        lifetime.Cancel();
        hotkeys?.Dispose();
        tray?.Dispose();
        power?.Dispose();
        foreground.Dispose();
        focusProbe.Dispose();
        host?.Dispose();
        if (Ocr.IsValueCreated) { Ocr.Value.Dispose(); }
        pipeline?.Dispose();
    }
}

/// Runs the dispatcher until a task finishes or a deadline passes, without blocking message handling.
internal static class UiWait
{
    public static void Pump(Task task, TimeSpan timeout)
    {
        if (task.IsCompleted) { return; }
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer { Interval = timeout };
        timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
        timer.Start();
        var dispatcher = Dispatcher.CurrentDispatcher;
        _ = task.ContinueWith(_ => dispatcher.BeginInvoke(() => frame.Continue = false), TaskScheduler.Default);
        Dispatcher.PushFrame(frame);
        timer.Stop();
    }
}
