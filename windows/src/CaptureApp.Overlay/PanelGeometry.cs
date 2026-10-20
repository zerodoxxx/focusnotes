using System.Windows;

namespace CaptureApp.Overlay;

/// <summary>X from work-area left; Y from work-area bottom to visible top, as on Mac.</summary>
public readonly record struct PanelPosition(double X, double Y)
{
    public bool IsFinite => double.IsFinite(X) && double.IsFinite(Y);
}
public interface IPanelPositionStore
{
    PanelPosition? Load(string key);
    void Save(string key, PanelPosition position);
}
public sealed class MemoryPanelPositionStore : IPanelPositionStore
{
    private readonly Dictionary<string, PanelPosition> positions = [];
    public PanelPosition? Load(string key) => positions.TryGetValue(key, out var position) ? position : null;
    public void Save(string key, PanelPosition position) { if (position.IsFinite) positions[key] = position; }
}
public static class PanelGeometry
{
    public const string NotePositionKey = "NoteEditorPanel.topCenter";
    public static PanelPosition TopCenter(Rect visible, Rect workArea) => new((visible.Left + visible.Width / 2 - workArea.Left) / Math.Max(Tokens.One, workArea.Width), (workArea.Bottom - visible.Top) / Math.Max(Tokens.One, workArea.Height));
    public static Rect FromPosition(PanelPosition point, Size size, Rect workArea) => Clamp(new Rect(workArea.Left + workArea.Width * point.X - size.Width / 2, workArea.Bottom - workArea.Height * point.Y, size.Width, size.Height), workArea);
    public static Rect Default(Size size, Rect workArea, bool interactive) => Clamp(new Rect(workArea.Left + (workArea.Width - size.Width) / 2, interactive ? workArea.Top + workArea.Height * Tokens.PanelTopFraction : workArea.Bottom - Tokens.ToastBottomOffset - size.Height, size.Width, size.Height), workArea);
    public static Rect Clamp(Rect rect, Rect workArea) => new(Math.Max(workArea.Left, Math.Min(rect.Left, workArea.Right - rect.Width)), Math.Max(workArea.Top, Math.Min(rect.Top, workArea.Bottom - rect.Height)), rect.Width, rect.Height);
    public static Rect Resize(Rect visible, Size size, Rect workArea) => Clamp(new Rect(visible.Left + (visible.Width - size.Width) / 2, visible.Top, size.Width, size.Height), workArea);
    public static Rect WindowRect(Rect visible) => new(visible.Left - Tokens.ShadowMargin, visible.Top - Tokens.ShadowMargin, visible.Width + Tokens.ShadowMargin * 2, visible.Height + Tokens.ShadowMargin * 2);
}
