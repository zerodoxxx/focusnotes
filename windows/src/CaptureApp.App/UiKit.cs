using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CaptureApp.App;

/// Small helpers for the code-built Setup and Settings windows. Colors come from the Overlay palette.
internal static class UiKit
{
    public static TextBlock Text(string value, double size = 13, bool bold = false, string brush = "TextPrimary", double bottom = 6)
    {
        var block = new TextBlock { Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, bottom) };
        if (bold) { block.FontWeight = FontWeights.SemiBold; }
        block.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return block;
    }

    public static TextBlock Secondary(string value, double bottom = 6) => Text(value, 12, false, "Secondary", bottom);

    public static Button Button(string label, Action click, bool primary = false)
    {
        var button = new Button { Content = label, Padding = new Thickness(14, 5, 14, 5), Margin = new Thickness(0, 0, 8, 0), MinWidth = 84, IsDefault = primary };
        button.Click += (_, _) => click();
        return button;
    }

    public static CheckBox Check(string label, bool isChecked)
    {
        var box = new CheckBox { Content = label, IsChecked = isChecked, Margin = new Thickness(0, 4, 0, 4) };
        box.SetResourceReference(Control.ForegroundProperty, "TextPrimary");
        return box;
    }

    public static RadioButton Radio(string label, string group, bool isChecked)
    {
        var radio = new RadioButton { Content = label, GroupName = group, IsChecked = isChecked, Margin = new Thickness(0, 3, 0, 3) };
        radio.SetResourceReference(Control.ForegroundProperty, "TextPrimary");
        return radio;
    }

    public static StackPanel Row(params UIElement[] children)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 6) };
        foreach (var child in children) { row.Children.Add(child); }
        return row;
    }

    public static void Themed(Window window)
    {
        window.SetResourceReference(Control.BackgroundProperty, "CardFill");
        window.SetResourceReference(Control.ForegroundProperty, "TextPrimary");
        window.FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
    }

    public static Border Rule()
    {
        var line = new Border { Height = 1, Margin = new Thickness(0, 8, 0, 8) };
        line.SetResourceReference(Border.BackgroundProperty, "Separator");
        return line;
    }
}
