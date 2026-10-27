using System.IO;
using CaptureApp.AppCore.Shell;
using CaptureApp.Updates;

namespace CaptureApp.App;

internal sealed partial class AppController
{
    private UpdateService? updates;
    private bool manualCheckPending;

    internal UpdateService? UpdateService => updates;

    private void StartUpdates()
    {
        updates = UpdateServiceFactory.Create(SettingsPath);
        updates.StateChanged += snapshot => dispatcher.BeginInvoke(() => OnUpdateState(snapshot));
        var service = updates;
        updateStartup = Task.Run(async () =>
        {
            try { await service.StartAsync(lifetime.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
            catch (Exception error) { log.Error($"Update startup failed ({error.GetType().Name}): {error.Message}"); }
        });
        StartUpdateScheduler();
    }

    private Task updateStartup = Task.CompletedTask;
    private int updateSchedulerStarted;

    /// Only an explicit "automatically" answer starts the one schedule; "Check for Updates…" always works.
    private void StartUpdateScheduler()
    {
        if (updates is not { IsEnabled: true } service || Settings.UpdatesChoice != UpdatesChoice.Auto
            || Interlocked.Exchange(ref updateSchedulerStarted, 1) == 1) { return; }
        var startup = updateStartup;
        _ = Task.Run(async () =>
        {
            try
            {
                await startup.ConfigureAwait(false);
                await service.RunAutomaticChecksAsync(lifetime.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { log.Error($"Automatic update checks stopped ({error.GetType().Name}): {error.Message}"); }
        });
    }

    private UpdateMenuState CurrentUpdateMenu()
    {
        if (updates is not { IsEnabled: true }) { return new(UpdateMenuKind.Hidden); }
        var snapshot = updates.Snapshot;
        return snapshot.Status switch
        {
            UpdateStatus.Checking => new(UpdateMenuKind.Checking),
            UpdateStatus.Downloading => new(UpdateMenuKind.Downloading, snapshot.Version),
            UpdateStatus.ReadyToRestart => new(UpdateMenuKind.ReadyToRestart, snapshot.Version),
            UpdateStatus.Failed => new(UpdateMenuKind.Failed),
            _ => new(UpdateMenuKind.Idle)
        };
    }

    private void OnUpdateState(UpdateSnapshot snapshot)
    {
        RefreshMenu();
        if (!manualCheckPending) { return; }
        switch (snapshot.Status)
        {
            case UpdateStatus.UpToDate: manualCheckPending = false; Coordinator.ShowToast(new(AppToastStyle.Success, Strings.UpToDate, $"v{AppCore_Version}")); break;
            case UpdateStatus.CheckFailed: manualCheckPending = false; Coordinator.ShowToast(new(AppToastStyle.Warning, Strings.UpdateCheckFailed, snapshot.Message)); break;
            case UpdateStatus.ReadyToRestart or UpdateStatus.Failed or UpdateStatus.Disabled: manualCheckPending = false; break;
        }
    }

    private static string AppCore_Version => CaptureApp.Core.AppInfo.Version;

    /// "Check for Updates…" and the failed-update Retry bypass the backoff and show the outcome.
    internal void CheckForUpdates()
    {
        if (updates is null) { return; }
        manualCheckPending = true;
        _ = Task.Run(async () =>
        {
            try { await updates.CheckAsync(manual: true, lifetime.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
            catch (Exception error) { log.Error($"Manual update check failed ({error.GetType().Name})"); }
        });
    }

    private void DownloadInstaller()
    {
        if (updates?.Snapshot.InstallerUrl is { } url) { OpenUrl(url); }
    }

    private void ApplyUpdateOnExitIfReady()
    {
        if (updates?.Snapshot.Status == UpdateStatus.ReadyToRestart) { updates.ApplyOnExit(); }
    }
}
