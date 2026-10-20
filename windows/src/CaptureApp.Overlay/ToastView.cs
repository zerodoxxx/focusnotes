using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Threading;

namespace CaptureApp.Overlay;

public sealed class ToastView : OverlaySurface
{
    public ToastView(Toast toast) : base(Tokens.ToastMinWidth, Tokens.ToastHeight, Tokens.ToastRadius)
    {
        var (symbol, color) = toast.Style switch
        {
            ToastStyle.Warning => ("exclamationmark.triangle.fill", "Warning"),
            ToastStyle.Session => ("record.circle", "Session"),
            ToastStyle.Copied => ("doc.on.doc.fill", "SelectedFill"),
            _ => ("checkmark.circle.fill", "BrandAccent")
        };
        var title = Ui.Text(toast.Title, "ToastTitle");
        var subtitle = Ui.Text(toast.Subtitle ?? "", "ToastSubtitle", "Secondary");
        var hint = toast.Hint is { } h ? new KeycapView(h.Key, h.Label) : null;
        var hintWidth = hint is null ? Tokens.Zero : Ui.NaturalWidth(hint);
        Width = Math.Clamp(Tokens.Padding * 2 + Tokens.IconSize + Tokens.IconGap + Math.Max(Ui.NaturalWidth(title), Ui.NaturalWidth(subtitle)) + (hint is null ? Tokens.Zero : hintWidth + Tokens.IconGap), Tokens.ToastMinWidth, Tokens.ToastMaxWidth);
        Ui.Place(Body, Ui.Icon(symbol, color), Tokens.Padding, (Height - Tokens.IconSize) / 2, Tokens.IconSize, Tokens.IconSize);
        var x = Tokens.Padding + Tokens.IconSize + Tokens.IconGap;
        var width = Width - Tokens.Padding - x - (hint is null ? Tokens.Zero : hintWidth + Tokens.IconGap);
        var subtitleHeight = string.IsNullOrEmpty(toast.Subtitle) ? Tokens.Zero : Tokens.MetaLineHeight + Tokens.ToastLineGap;
        var y = (Height - Tokens.TitleLineHeight - subtitleHeight) / 2;
        Ui.Place(Body, title, x, y, width, Tokens.TitleLineHeight);
        if (subtitleHeight > 0) Ui.Place(Body, subtitle, x, y + Tokens.TitleLineHeight + Tokens.ToastLineGap, width, Tokens.MetaLineHeight);
        if (hint is not null) Ui.Place(Body, hint, Width - Tokens.Padding - hintWidth, Tokens.Padding, hintWidth, Height - Tokens.Padding * 2);
        AutomationProperties.SetName(this, string.Join(", ", new[] { toast.Title, toast.Subtitle }.Where(s => !string.IsNullOrEmpty(s))));
        AutomationProperties.SetLiveSetting(this, AutomationLiveSetting.Polite);
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new ToastPeer(this);
    private sealed class ToastPeer(ToastView owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
        protected override string GetClassNameCore() => nameof(ToastView);
    }
}
public sealed class ToastController : IDisposable
{
    private OverlayWindow? panel;
    private DispatcherTimer? expiry;
    public bool IsVisible => panel?.IsVisible == true;
    public Action? OnExpire { get; set; }
    public void Show(Toast toast)
    {
        Dismiss(false, false);
        var view = new ToastView(toast);
        var window = new OverlayWindow(view, false); panel = window;
        window.Closed += (_, _) => { if (panel == window) { panel = null; expiry?.Stop(); expiry = null; } };
        window.Present(false);
        UIElementAutomationPeer.CreatePeerForElement(view)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        expiry = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Math.Max(Tokens.LayoutTolerance, toast.DurationSeconds)) };
        expiry.Tick += (_, _) => Dismiss(true); expiry.Start();
    }
    public void Dismiss(bool expire = false, bool animated = true)
    {
        expiry?.Stop(); expiry = null;
        var previous = panel; panel = null;
        previous?.Dismiss(expire ? DismissReason.Expired : DismissReason.Replaced, animated);
        if (expire && previous is not null) OnExpire?.Invoke();
    }
    public void Dispose() => Dismiss(false, false);
}
