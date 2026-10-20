using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Microsoft.Win32;
using Windows.UI.ViewManagement;

namespace CaptureApp.Overlay;

/// <summary>Own one per UI dispatcher. Views use dynamic palette resources.</summary>
public sealed class ThemeManager : IDisposable
{
    private readonly ResourceDictionary resources;
    private readonly System.Windows.Threading.Dispatcher dispatcher;
    private readonly bool? darkOverride;
    private bool disposed;
    public ThemeManager(ResourceDictionary resources, bool? darkOverride = null)
    {
        this.resources = resources;
        this.darkOverride = darkOverride;
        dispatcher = System.Windows.Threading.Dispatcher.CurrentDispatcher;
        resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CaptureApp.Overlay;component/Tokens.xaml", UriKind.Relative) });
        Apply();
        SystemEvents.UserPreferenceChanged += PreferenceChanged;
        SystemParameters.StaticPropertyChanged += ParametersChanged;
    }

    public void Apply(bool? dark = null, bool? highContrast = null)
    {
        var dictionary = resources.MergedDictionaries[0];
        var isDark = dark ?? darkOverride ?? Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is 0;
        dictionary.MergedDictionaries.Clear();
        dictionary.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri($"/CaptureApp.Overlay;component/Tokens.{(isDark ? "Dark" : "Light")}.xaml", UriKind.Relative) });
        try
        {
            var accent = new UISettings().GetColorValue(UIColorType.Accent);
            dictionary["SelectedFill"] = new SolidColorBrush(Color.FromArgb(accent.A, accent.R, accent.G, accent.B));
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or TypeLoadException) { dictionary.Remove("SelectedFill"); }
        var contrast = highContrast ?? SystemParameters.HighContrast;
        if (contrast)
        {
            foreach (var key in new[] { "SurfaceTint", "CardFill", "HintFill", "QuickClusterFill", "CodeBackground", "QuickButtonHoverFill", "QuickButtonPressedFill" }) dictionary[key] = SystemColors.WindowBrush;
            foreach (var key in new[] { "TextPrimary", "Secondary", "Tertiary", "SurfaceBorder", "CardBorder", "Separator", "KeycapBoxBorder", "QuickClusterBorder", "BrandAccent", "Warning", "Session" }) dictionary[key] = SystemColors.WindowTextBrush;
            dictionary["SelectedFill"] = SystemColors.HighlightBrush;
            dictionary["MenuSelectedFill"] = SystemColors.HighlightBrush;
            dictionary["SelectedText"] = SystemColors.HighlightTextBrush;
            dictionary["SelectedSecondary"] = SystemColors.HighlightTextBrush;
            if (darkOverride is true)
            {
                dictionary["EditorLink"] = SystemColors.HotTrackBrush;
                dictionary["EditorCheckboxCheck"] = SystemColors.WindowBrush;
            }
            dictionary["SurfaceShadow"] = null!;
        }
        else
        {
            // Remove previous high-contrast overrides, leaving the palette dictionaries authoritative.
            foreach (var key in new[] { "SurfaceTint", "CardFill", "HintFill", "QuickClusterFill", "CodeBackground", "QuickButtonHoverFill", "QuickButtonPressedFill", "TextPrimary", "Secondary", "Tertiary", "SurfaceBorder", "CardBorder", "Separator", "KeycapBoxBorder", "QuickClusterBorder", "BrandAccent", "Warning", "Session", "MenuSelectedFill", "SelectedText", "SelectedSecondary" }) dictionary.Remove(key);
            if (darkOverride is true)
            {
                dictionary.Remove("EditorLink");
                dictionary.Remove("EditorCheckboxCheck");
            }
            dictionary["SurfaceShadow"] = new DropShadowEffect { BlurRadius = Tokens.ShadowBlur, ShadowDepth = Tokens.ShadowDepth, Direction = Tokens.ShadowDirection, Opacity = Tokens.ShadowOpacity, Color = ((SolidColorBrush)dictionary["Shadow"]).Color };
        }
    }
    private void PreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => Refresh();
    private void ParametersChanged(object? sender, PropertyChangedEventArgs e) => Refresh();
    private void Refresh() { if (!disposed) dispatcher.BeginInvoke(() => { if (!disposed) Apply(); }); }
    public void Dispose()
    {
        disposed = true;
        SystemEvents.UserPreferenceChanged -= PreferenceChanged;
        SystemParameters.StaticPropertyChanged -= ParametersChanged;
    }
}
