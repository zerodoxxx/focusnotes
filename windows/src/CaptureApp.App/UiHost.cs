using System.IO;
using System.Windows.Threading;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Overlay;

namespace CaptureApp.App;

/// Presents coordinator toasts through the Overlay toast controller, always on the UI thread.
internal sealed class UiHost : ICaptureHost, IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly ToastController toast = new();
    private readonly Func<CaptureTrigger, string> binding;
    private readonly Func<string> sessionBinding;
    private readonly Action statusChanged;
    private volatile bool stagedVisible;

    public UiHost(Dispatcher dispatcher, Func<CaptureTrigger, string> binding, Func<string> sessionBinding, Action statusChanged)
    {
        this.dispatcher = dispatcher;
        this.binding = binding;
        this.sessionBinding = sessionBinding;
        this.statusChanged = statusChanged;
    }

    public bool PresentsUi => true;
    public bool StagedToastVisible => stagedVisible;
    public string SessionBinding => sessionBinding();
    public string BindingFor(CaptureTrigger trigger) => binding(trigger);
    public void StatusChanged() => dispatcher.BeginInvoke(statusChanged);

    public Action? OnExpire { get => toast.OnExpire; set => toast.OnExpire = value; }

    public void ShowToast(AppToast value) => dispatcher.BeginInvoke(() =>
    {
        stagedVisible = false;
        toast.Show(Map(value));
    });

    public void ShowStagedToast(AppToast value) => dispatcher.BeginInvoke(() =>
    {
        toast.Show(Map(value));
        stagedVisible = true;
    });

    public void DismissStagedToast() => dispatcher.BeginInvoke(() =>
    {
        stagedVisible = false;
        toast.Dismiss(false);
    });

    public void Dispose() => dispatcher.Invoke(() => toast.Dispose());

    internal static Toast Map(AppToast value) => new(
        value.Style switch
        {
            AppToastStyle.Warning => ToastStyle.Warning,
            AppToastStyle.Session => ToastStyle.Session,
            AppToastStyle.Copied => ToastStyle.Copied,
            _ => ToastStyle.Success
        },
        value.Title, value.Subtitle, value.HintKey is { } key ? new ToastHint(key, value.HintLabel ?? "") : null, value.Duration);
}

/// Panel positions persist in the settings.json "panels" section as screen fractions.
internal sealed class SettingsPanelPositionStore(SettingsStore settings) : IPanelPositionStore
{
    public PanelPosition? Load(string key) => settings.ReadPanel(key) is { } value ? new PanelPosition(value.X, value.Y) : null;

    public void Save(string key, PanelPosition position)
    {
        if (!position.IsFinite) { return; }
        try { settings.WritePanel(key, position.X, position.Y); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
