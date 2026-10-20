using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using CaptureApp.Overlay.Interop;

namespace CaptureApp.Overlay;

/// <summary>A non-TextBox control that takes the keyboard on click, so the first click activates the window.</summary>
public interface ITypingSurface { IInputElement FocusTarget { get; } }

public enum DismissReason { Explicit, ClickAway, DesktopSwitch, Handoff, OpenExternal, Quit, Expired, Replaced }

/// <summary>UI-only window shell. Geometry always describes the visible surface, excluding shadow.</summary>
public class OverlayWindow : Window
{
    private static OverlayWindow? activePanel;
    private readonly bool interactive;
    private readonly FocusReturnTracker focus;
    private readonly DispatcherTimer desktopTimer;
    private HwndSource? source;
    private nint handle, returnTarget;
    private bool closing, handedOff;
    private Rect workArea;
    private readonly Grid frame;
    private readonly ScaleTransform scale = new(Tokens.One, Tokens.One);
    private readonly TranslateTransform travel = new();
    public bool IsSticky { get; set; }
    public bool IsMovable { get; set; }
    public IPanelPositionStore? PositionStore { get; set; }
    public string PositionKey { get; set; } = PanelGeometry.NotePositionKey;
    public Rect VisibleRect => new(Left + Tokens.ShadowMargin, Top + Tokens.ShadowMargin, Math.Max(Tokens.Zero, Width - Tokens.ShadowMargin * 2), Math.Max(Tokens.Zero, Height - Tokens.ShadowMargin * 2));
    public event Action<DismissReason>? Dismissed;
    public event Action? Resigned;
    public Func<bool>? ShouldDismiss { get; set; }
    public Func<bool>? CancelHandler { get; set; }
    public OverlayWindow(OverlaySurface surface, bool interactive = true, FocusReturnTracker? focusTracker = null)
    {
        this.interactive = interactive;
        focus = focusTracker ?? FocusReturnTracker.Shared;
        AllowsTransparency = true;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        SetResourceReference(BackgroundProperty, "Transparent");
        frame = OverlaySurface.Frame(surface);
        frame.RenderTransformOrigin = new Point(Tokens.Center, Tokens.Center);
        var transforms = new TransformGroup(); transforms.Children.Add(scale); transforms.Children.Add(travel);
        frame.RenderTransform = transforms;
        Content = frame;
        Width = surface.Width + Tokens.ShadowMargin * 2;
        Height = surface.Height + Tokens.ShadowMargin * 2;
        desktopTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(Tokens.DesktopCheckMilliseconds) };
        desktopTimer.Tick += CheckDesktop;
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && CancelHandler?.Invoke() != true) { Dismiss(); e.Handled = true; } };
    }
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        handle = new WindowInteropHelper(this).Handle;
        source = HwndSource.FromHwnd(handle);
        source.AddHook(WindowProc);
        var styles = NativeMethods.GetWindowLongPtr(handle, NativeMethods.GwlExStyle) | NativeMethods.WsExToolWindow;
        if (!interactive) styles |= NativeMethods.WsExNoActivate | NativeMethods.WsExTransparent;
        NativeMethods.SetWindowLongPtr(handle, NativeMethods.GwlExStyle, styles);
    }
    public void Present(bool typingNeeded = true, IInputElement? field = null)
    {
        if (closing) return;
        if (interactive)
        {
            returnTarget = activePanel is { closing: false } previous ? previous.returnTarget : focus.BeforeActivation();
            if (activePanel is { closing: false } old && old != this) { old.handedOff = true; old.Dismiss(DismissReason.Handoff, false); }
            activePanel = this;
        }
        var monitor = MonitorGeometry.UnderPointer(); workArea = monitor.WorkArea;
        var size = new Size(Width - Tokens.ShadowMargin * 2, Height - Tokens.ShadowMargin * 2);
        var stored = IsMovable ? PositionStore?.Load(PositionKey) : null;
        var visible = stored is { IsFinite: true } position ? PanelGeometry.FromPosition(position, size, workArea) : PanelGeometry.Default(size, workArea, interactive);
        ApplyRect(PanelGeometry.WindowRect(visible));
        Opacity = SystemParameters.ClientAreaAnimation ? Tokens.Zero : Tokens.One;
        Show();
        // Place in physical pixels using the pointer monitor's DPI, including negative monitor origins.
        var rect = PanelGeometry.WindowRect(visible);
        NativeMethods.SetWindowPos(handle, 0, (int)Math.Round(rect.X * monitor.Scale), (int)Math.Round(rect.Y * monitor.Scale), (int)Math.Round(rect.Width * monitor.Scale), (int)Math.Round(rect.Height * monitor.Scale), NativeMethods.SwpNoActivate | NativeMethods.SwpNoZOrder);
        if (interactive)
        {
            desktopTimer.Start();
            if (typingNeeded) ActivateForTyping(field);
        }
        Animate(true);
    }
    public void ActivateForTyping(IInputElement? field = null)
    {
        if (!interactive || closing) return;
        returnTarget = focus.BeforeActivation();
        Activate(); // Synchronous activation/focus before returning from a hotkey handler.
        if (field is not null) Keyboard.Focus(field);
    }
    protected override void OnActivated(EventArgs e)
    {
        if (interactive && !closing) returnTarget = focus.BeforeActivation();
        base.OnActivated(e);
    }
    protected override void OnDeactivated(EventArgs e)
    {
        base.OnDeactivated(e);
        if (!interactive || closing || handedOff) return;
        Resigned?.Invoke();
        if (!IsSticky) Dismiss(DismissReason.ClickAway, false);
    }
    private void CheckDesktop(object? sender, EventArgs e)
    {
        if (!IsSticky && focus.DesktopAvailable && !focus.IsOnCurrentDesktop(handle)) Dismiss(DismissReason.DesktopSwitch, false);
    }
    public bool Dismiss(DismissReason reason = DismissReason.Explicit, bool animated = true)
    {
        if (closing) return true;
        if (ShouldDismiss?.Invoke() == false) return false;
        closing = true;
        desktopTimer.Stop();
        // Inactive first-click actions must leave the existing foreground untouched.
        var ownedForeground = NativeMethods.GetForegroundWindow() == handle;
        if (reason == DismissReason.Explicit && ownedForeground) focus.RestoreExplicit(returnTarget);
        if (activePanel == this) activePanel = null;
        Dismissed?.Invoke(reason);
        if (animated && SystemParameters.ClientAreaAnimation) Animate(false);
        else Close();
        return true;
    }
    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (!closing) { e.Cancel = true; Dismiss(); return; }
        base.OnClosing(e);
    }
    protected override void OnClosed(EventArgs e)
    {
        desktopTimer.Stop(); source?.RemoveHook(WindowProc);
        base.OnClosed(e);
    }
    private nint WindowProc(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == NativeMethods.WmMouseActivate)
        {
            NativeMethods.GetCursorPos(out var pointer);
            var hit = InputHitTest(PointFromScreen(new Point(pointer.X, pointer.Y))) as DependencyObject;
            while (hit is not null && hit is not TextBoxBase && hit is not ITypingSurface) hit = VisualTreeHelper.GetParent(hit);
            if (hit is TextBoxBase text) { returnTarget = focus.BeforeActivation(); ActivateForTyping(text); }
            else if (hit is ITypingSurface surface) { returnTarget = focus.BeforeActivation(); ActivateForTyping(surface.FocusTarget); }
            else { handled = true; return NativeMethods.MaNoActivate; }
        }
        if (message == NativeMethods.WmDpiChanged)
        {
            var rect = Marshal.PtrToStructure<NativeMethods.Rect>(lParam);
            NativeMethods.SetWindowPos(hwnd, 0, rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top, NativeMethods.SwpNoActivate | NativeMethods.SwpNoZOrder);
            // WPF still processes this message to update the visual DPI.
        }
        return 0;
    }
    public void MoveFromBand()
    {
        if (!IsMovable || closing || Mouse.LeftButton != MouseButtonState.Pressed) return;
        DragMove();
        var monitor = MonitorGeometry.UnderPointer(); workArea = monitor.WorkArea;
        PositionStore?.Save(PositionKey, PanelGeometry.TopCenter(VisibleRect, workArea));
    }
    public void ResizeVisible(Size size, bool animated = true)
    {
        if (closing) return;
        var target = PanelGeometry.WindowRect(PanelGeometry.Resize(VisibleRect, size, workArea));
        if (!animated || !SystemParameters.ClientAreaAnimation) { ApplyRect(target); return; }
        foreach (var (property, value) in new[] { (LeftProperty, target.Left), (TopProperty, target.Top), (WidthProperty, target.Width), (HeightProperty, target.Height) })
        {
            var animation = Animation((double)GetValue(property), value, Tokens.ResizeDuration, true);
            animation.Completed += (_, _) => { SetValue(property, value); BeginAnimation(property, null); };
            BeginAnimation(property, animation);
        }
    }
    private void ApplyRect(Rect rect) { Left = rect.Left; Top = rect.Top; Width = rect.Width; Height = rect.Height; }
    private void Animate(bool appear)
    {
        if (!SystemParameters.ClientAreaAnimation) { Opacity = Tokens.One; if (!appear) Close(); return; }
        var duration = interactive ? (appear ? Tokens.PanelAppear : Tokens.PanelDisappear) : (appear ? Tokens.ToastAppear : Tokens.ToastDisappear);
        var opacity = Animation(appear ? Tokens.Zero : Opacity, appear ? Tokens.One : Tokens.Zero, duration, appear);
        if (!appear) opacity.Completed += (_, _) => Close();
        BeginAnimation(OpacityProperty, opacity);
        if (interactive && appear)
        {
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, Animation(Tokens.PanelScale, Tokens.One, duration, true));
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, Animation(Tokens.PanelScale, Tokens.One, duration, true));
        }
        if (!interactive) travel.BeginAnimation(TranslateTransform.YProperty, Animation(appear ? Tokens.ToastTravel : Tokens.Zero, appear ? Tokens.Zero : Tokens.ToastTravel, duration, appear));
    }
    private static DoubleAnimation Animation(double from, double to, double seconds, bool easeOut) => new(from, to, TimeSpan.FromSeconds(seconds)) { EasingFunction = new CubicEase { EasingMode = easeOut ? EasingMode.EaseOut : EasingMode.EaseIn } };
}
