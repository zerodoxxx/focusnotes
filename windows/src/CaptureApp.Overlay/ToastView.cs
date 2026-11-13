using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Threading;

namespace CaptureApp.Overlay;

public sealed class ToastView : OverlaySurface
{
    internal event Action? ActionRequested;
    public ToastView(Toast toast) : base(Tokens.ToastMinWidth, Tokens.ToastHeight, Tokens.ToastRadius)
    {
        var (symbol, color) = toast.Style switch
        {
            ToastStyle.Warning => ("exclamationmark.triangle.fill", "Warning"),
            ToastStyle.Session => (Icons.Session, "Session"),
            ToastStyle.Copied => ("doc.on.doc.fill", "SelectedFill"),
            _ => ("checkmark.circle.fill", "BrandAccent")
        };
        var title = Ui.Text(toast.Title, "ToastTitle");
        var subtitle = Ui.Text(toast.Subtitle ?? "", "ToastSubtitle", "Secondary");
        var hint = toast.Hint is { } h ? new KeycapView(h.Key, h.Label) : null;
        var hintWidth = hint is null ? Tokens.Zero : Ui.NaturalWidth(hint);
        Button? action = null;
        if (toast.Action is { } callback)
        {
            SetResourceReference(BackgroundProperty, "Transparent");
            action = new Button { Content = Ui.Text(callback.Title, "Hint", "BrandAccent"), Focusable = false };
            action.SetResourceReference(StyleProperty, "Overlay.Row");
            AutomationProperties.SetName(action, callback.Title);
            action.Click += (_, _) => ActionRequested?.Invoke();
        }
        var actionWidth = action is null ? Tokens.Zero : Ui.NaturalWidth(action);
        var actionSpace = action is null ? Tokens.Zero : actionWidth + Tokens.IconGap;
        Width = Math.Clamp(Tokens.Padding * 2 + Tokens.IconSize + Tokens.IconGap + Math.Max(Ui.NaturalWidth(title), Ui.NaturalWidth(subtitle)) + actionSpace + (hint is null ? Tokens.Zero : hintWidth + Tokens.IconGap), Tokens.ToastMinWidth, Tokens.ToastMaxWidth);
        Ui.Place(Body, Ui.Icon(symbol, color), Tokens.Padding, (Height - Tokens.IconSize) / 2, Tokens.IconSize, Tokens.IconSize);
        var x = Tokens.Padding + Tokens.IconSize + Tokens.IconGap;
        var width = Width - Tokens.Padding - x - actionSpace - (hint is null ? Tokens.Zero : hintWidth + Tokens.IconGap);
        var subtitleHeight = string.IsNullOrEmpty(toast.Subtitle) ? Tokens.Zero : Tokens.MetaLineHeight + Tokens.ToastLineGap;
        var y = (Height - Tokens.TitleLineHeight - subtitleHeight) / 2;
        Ui.Place(Body, title, x, y, width, Tokens.TitleLineHeight);
        if (subtitleHeight > 0) Ui.Place(Body, subtitle, x, y + Tokens.TitleLineHeight + Tokens.ToastLineGap, width, Tokens.MetaLineHeight);
        if (hint is not null) Ui.Place(Body, hint, Width - Tokens.Padding - actionSpace - hintWidth, Tokens.Padding, hintWidth, Height - Tokens.Padding * 2);
        if (action is not null) Ui.Place(Body, action, Width - Tokens.Padding - actionWidth, Tokens.Padding, actionWidth, Height - Tokens.Padding * 2);
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
    private int generation;
    public bool IsVisible => panel?.IsVisible == true;
    public Action? OnExpire { get; set; }
    public void Show(Toast toast)
    {
        Dismiss(false, false);
        var token = ++generation;
        var view = new ToastView(toast);
        var window = new OverlayWindow(view, false, receivesMouseClicks: toast.Action is not null); panel = window;
        void StopExpiry() { expiry?.Stop(); expiry = null; }
        void StartExpiry()
        {
            if (generation != token) return;
            StopExpiry();
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Math.Max(Tokens.LayoutTolerance, toast.DurationSeconds)) };
            expiry = timer;
            timer.Tick += (_, _) => { if (generation == token && expiry == timer) Dismiss(true); };
            timer.Start();
        }
        window.Closed += (_, _) =>
        {
            if (generation != token) return;
            generation++; panel = null; StopExpiry();
        };
        if (toast.Action is { } action)
        {
            view.ActionRequested += () =>
            {
                if (generation != token) return;
                Dismiss(false);
                action.Invoke();
            };
            view.MouseEnter += (_, _) => { if (generation == token) StopExpiry(); };
            view.MouseLeave += (_, _) => { if (generation == token) StartExpiry(); };
        }
        window.Present(false);
        UIElementAutomationPeer.CreatePeerForElement(view)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        if (toast.Action is null || !view.IsMouseOver) StartExpiry();
    }
    public void Dismiss(bool expire = false, bool animated = true)
    {
        generation++;
        expiry?.Stop(); expiry = null;
        var previous = panel; panel = null;
        previous?.Dismiss(expire ? DismissReason.Expired : DismissReason.Replaced, animated);
        if (expire && previous is not null) OnExpire?.Invoke();
    }
    public void Dispose() => Dismiss(false, false);
}
