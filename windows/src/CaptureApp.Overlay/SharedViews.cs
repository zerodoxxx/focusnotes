using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace CaptureApp.Overlay;

public class OverlaySurface : Grid
{
    protected Canvas Body { get; } = new();
    public Size SurfaceSize => new(Width, Height);
    public OverlaySurface(double width, double height, double radius = Tokens.PanelRadius)
    {
        Width = width; Height = height;
        var border = new Border { CornerRadius = new CornerRadius(radius), BorderThickness = new Thickness(Tokens.BorderWidth), IsHitTestVisible = false };
        border.SetResourceReference(Border.BackgroundProperty, "SurfaceTint");
        border.SetResourceReference(Border.BorderBrushProperty, "SurfaceBorder");
        border.SetResourceReference(EffectProperty, "SurfaceShadow");
        Children.Add(border); Children.Add(Body);
    }
    public static Grid Frame(OverlaySurface surface)
    {
        var frame = new Grid { Width = surface.Width + Tokens.ShadowMargin * 2, Height = surface.Height + Tokens.ShadowMargin * 2 };
        surface.Margin = new Thickness(Tokens.ShadowMargin);
        frame.Children.Add(surface);
        surface.SizeChanged += (_, _) => { frame.Width = surface.Width + Tokens.ShadowMargin * 2; frame.Height = surface.Height + Tokens.ShadowMargin * 2; };
        return frame;
    }
}
internal sealed class DecorativeTextBlock : TextBlock
{
    protected override System.Windows.Automation.Peers.AutomationPeer OnCreateAutomationPeer() => null!;
}
internal static class Ui
{
    internal static T Place<T>(Canvas canvas, T child, double x, double y, double width, double height) where T : FrameworkElement
    {
        Canvas.SetLeft(child, x); Canvas.SetTop(child, y); child.Width = Math.Max(Tokens.Zero, width); child.Height = Math.Max(Tokens.Zero, height); canvas.Children.Add(child); return child;
    }
    internal static TextBlock Text(string value, string style, string color = "TextPrimary", bool accessible = false)
    {
        TextBlock text = accessible ? new TextBlock { Text = value } : new DecorativeTextBlock { Text = value };
        text.SetResourceReference(FrameworkElement.StyleProperty, "TextStyle." + style);
        text.SetResourceReference(TextBlock.ForegroundProperty, color);
        return text;
    }
    internal static TextBlock Icon(string symbol, string color = "Secondary", double size = Tokens.IconSize)
    {
        var text = new DecorativeTextBlock { Text = Icons.Glyph(symbol), FontSize = size, LineHeight = size, LineStackingStrategy = LineStackingStrategy.BlockLineHeight, VerticalAlignment = VerticalAlignment.Center, TextAlignment = TextAlignment.Center };
        text.SetResourceReference(TextBlock.FontFamilyProperty, "Font.Icons"); text.SetResourceReference(TextBlock.ForegroundProperty, color);
        return text;
    }
    internal static Border Separator() { var line = new Border(); line.SetResourceReference(Border.BackgroundProperty, "Separator"); return line; }
    internal static Grid Field(TextBox field, string placeholder)
    {
        field.SetResourceReference(FrameworkElement.StyleProperty, "Overlay.Field");
        AutomationProperties.SetName(field, placeholder);
        var grid = new Grid(); grid.Children.Add(field);
        var hint = Text(placeholder, "Input", "Tertiary"); hint.IsHitTestVisible = false;
        grid.Children.Add(hint);
        void Update() => hint.Visibility = field.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        field.TextChanged += (_, _) => Update(); Update();
        return grid;
    }
    internal static void Matches(TextBlock text, string value, IReadOnlyList<TextMatch>? ranges, string matchColor)
    {
        if (ranges is null || ranges.Count == 0) return;
        var offset = 0;
        foreach (var range in ranges.OrderBy(r => r.Start))
        {
            if (range.Start < offset || range.Start < 0 || range.Length <= 0 || range.Start > value.Length || range.Length > value.Length - range.Start) continue;
            text.Inlines.Add(new Run(value[offset..range.Start]));
            var run = new Run(value.Substring(range.Start, range.Length)) { FontWeight = FontWeights.SemiBold };
            run.SetResourceReference(TextElement.ForegroundProperty, matchColor);
            text.Inlines.Add(run); offset = range.Start + range.Length;
        }
        if (offset == 0) return;
        text.Inlines.Add(new Run(value[offset..]));
    }
    internal static double NaturalWidth(FrameworkElement element)
    {
        element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); return Math.Ceiling(element.DesiredSize.Width);
    }
}
public sealed class KeycapView : StackPanel
{
    public KeycapView(string key, string caption = "")
    {
        Orientation = Orientation.Horizontal; VerticalAlignment = VerticalAlignment.Center;
        var label = Ui.Text(key, "Hint", "Secondary"); label.TextTrimming = TextTrimming.None;
        var capsule = new Border { CornerRadius = new CornerRadius(Tokens.HintRadius), Padding = new Thickness(Tokens.HintPadding, Tokens.Zero, Tokens.HintPadding, Tokens.Zero), Height = Tokens.HintHeight, Child = label };
        capsule.SetResourceReference(Border.BackgroundProperty, "HintFill"); Children.Add(capsule);
        if (caption.Length > 0)
        {
            var text = Ui.Text(caption, "Meta", "Tertiary"); text.TextTrimming = TextTrimming.None;
            text.Margin = new Thickness(Tokens.HintLabelGap, Tokens.Zero, Tokens.Zero, Tokens.Zero); Children.Add(text);
        }
        AutomationProperties.SetName(this, string.Join(" ", new[] { key, caption }.Where(s => s.Length > 0)));
    }
}
internal sealed class ChoiceRowView : Button
{
    internal ChoiceRowView(SearchRow model, bool selected)
    {
        SetResourceReference(StyleProperty, "Overlay.Row");
        var canvas = new Canvas(); var background = new Border { CornerRadius = new CornerRadius(Tokens.SelectedRadius) };
        if (selected) background.SetResourceReference(Border.BackgroundProperty, "SelectedFill");
        var grid = new Grid(); grid.Children.Add(background); grid.Children.Add(canvas); Content = grid;
        var foreground = selected ? "SelectedText" : "TextPrimary";
        var secondary = selected ? "SelectedSecondary" : "Secondary";
        var title = Ui.Text(model.Title, "Title", foreground);
        // Clear Text before adding runs (TextBlock.Text is otherwise retained as an implicit run).
        if (model.TitleMatches?.Count > 0) { title.Text = ""; Ui.Matches(title, model.Title, model.TitleMatches, foreground); }
        var snippet = Ui.Text(model.Snippet, "Snippet", secondary);
        if (model.SnippetMatches?.Count > 0) { snippet.Text = ""; Ui.Matches(snippet, model.Snippet, model.SnippetMatches, selected ? "SelectedSecondary" : "TextPrimary"); }
        var meta = Ui.Text(model.Meta, "Meta", selected ? "SelectedSecondary" : "Tertiary");
        FrameworkElement icon;
        if (model.Kind == SearchRowKind.Image)
        {
            Thumbnail = new Image { Stretch = Stretch.UniformToFill };
            icon = new Border { CornerRadius = new CornerRadius(Tokens.ThumbnailRadius), Child = Thumbnail, Clip = new RectangleGeometry(new Rect(Tokens.Zero, Tokens.Zero, Tokens.ThumbnailSize, Tokens.ThumbnailSize), Tokens.ThumbnailRadius, Tokens.ThumbnailRadius) };
            icon.SetResourceReference(Border.BackgroundProperty, "HintFill");
        }
        else icon = Ui.Icon(model.Kind == SearchRowKind.Note ? "doc.text" : "text.alignleft", selected ? "SelectedText" : "Secondary");
        SizeChanged += (_, _) =>
        {
            canvas.Children.Clear();
            var iconSize = model.Kind == SearchRowKind.Image ? Tokens.ThumbnailSize : Tokens.IconSize;
            Ui.Place(canvas, icon, Tokens.RowInset + (Tokens.ThumbnailSize - iconSize) / 2, (Tokens.ResultHeight - iconSize) / 2, iconSize, iconSize);
            var x = Tokens.RowInset + Tokens.ThumbnailSize + Tokens.IconGap; var width = ActualWidth - x - Tokens.RowInset;
            var snippetHeight = model.Snippet.Length == 0 ? Tokens.Zero : Tokens.SnippetLineHeight;
            var metaHeight = model.Meta.Length == 0 ? Tokens.Zero : Tokens.MetaLineHeight;
            var y = (Tokens.ResultHeight - Tokens.TitleLineHeight - snippetHeight - metaHeight) / 2;
            Ui.Place(canvas, title, x, y, width, Tokens.TitleLineHeight);
            if (snippetHeight > 0) Ui.Place(canvas, snippet, x, y + Tokens.TitleLineHeight, width, snippetHeight);
            if (metaHeight > 0) Ui.Place(canvas, meta, x, y + Tokens.TitleLineHeight + snippetHeight, width, metaHeight);
        };
        AutomationProperties.SetName(this, string.Join(", ", new[] { model.Title, model.Snippet }.Where(s => s.Length > 0)));
        AutomationProperties.SetItemStatus(this, selected ? "Selected" : "");
    }
    internal Image? Thumbnail { get; }
    internal ChoiceRowView(Suggestion model, bool selected)
    {
        SetResourceReference(StyleProperty, "Overlay.Row");
        var border = new Border { CornerRadius = new CornerRadius(Tokens.SelectedRadius) };
        if (selected) border.SetResourceReference(Border.BackgroundProperty, "SelectedFill");
        var grid = new Grid { Margin = new Thickness(Tokens.RowInset, Tokens.Zero, Tokens.SuggestionTrailingInset, Tokens.Zero) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Tokens.SuggestionLeadingWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Tokens.One, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = Ui.Icon(model.SymbolName ?? "doc.text", selected ? "SelectedText" : "Secondary", Tokens.SuggestionIconSize); grid.Children.Add(icon);
        var title = Ui.Text(model.Title, "SuggestionTitle", selected ? "SelectedText" : "TextPrimary");
        title.Margin = new Thickness(Tokens.SuggestionIconGap, Tokens.Zero, Tokens.Padding, Tokens.Zero); Grid.SetColumn(title, 1); grid.Children.Add(title);
        var secondary = Ui.Text(model.Secondary ?? "", "Meta", selected ? "SelectedSecondary" : "Tertiary"); Grid.SetColumn(secondary, 2); grid.Children.Add(secondary);
        border.Child = grid; Content = border;
        AutomationProperties.SetName(this, string.Join(", ", new[] { model.Title, model.Secondary }.Where(s => !string.IsNullOrEmpty(s))));
        AutomationProperties.SetItemStatus(this, selected ? "Selected" : "");
    }
}
