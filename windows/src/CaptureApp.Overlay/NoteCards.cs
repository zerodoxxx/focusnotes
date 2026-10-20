using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace CaptureApp.Overlay;

/// <summary>One bordered box per key (Ctrl, Shift and P are three boxes), as KeycapBoxesView.</summary>
internal sealed class KeycapBoxesView : StackPanel
{
    internal KeycapBoxesView(IReadOnlyList<string> keys)
    {
        Orientation = Orientation.Horizontal; VerticalAlignment = VerticalAlignment.Center;
        for (var i = 0; i < keys.Count; i++)
        {
            var glyph = Ui.Text(keys[i], "KeycapGlyph", "Secondary"); glyph.TextTrimming = TextTrimming.None; glyph.TextAlignment = TextAlignment.Center;
            glyph.HorizontalAlignment = HorizontalAlignment.Center;
            var box = new Border
            {
                MinWidth = Tokens.KeycapBoxMin, Height = Tokens.KeycapBoxMin, CornerRadius = new CornerRadius(Tokens.KeycapBoxRadius), BorderThickness = new Thickness(Tokens.BorderWidth),
                Padding = new Thickness(Tokens.KeycapBoxPadding, Tokens.Zero, Tokens.KeycapBoxPadding, Tokens.Zero), Child = glyph,
                Margin = new Thickness(i == 0 ? Tokens.Zero : Tokens.KeycapBoxGap, Tokens.Zero, Tokens.Zero, Tokens.Zero)
            };
            box.SetResourceReference(Border.BorderBrushProperty, "KeycapBoxBorder");
            Children.Add(box);
        }
        AutomationProperties.SetName(this, string.Join("+", keys));
    }
}

/// <summary>A list row that follows real pointer movement only, so a list scrolling under a still pointer keeps its selection.</summary>
internal abstract class CardRow : Button
{
    private static Point lastPointer = new(double.NaN, double.NaN);
    internal event Action? Hovered;
    protected CardRow()
    {
        SetResourceReference(StyleProperty, "Overlay.Row");
        ClickMode = ClickMode.Press; // Rows run on mouse down, like the Mac card.
        MouseMove += (_, e) =>
        {
            var pointer = PointToScreen(e.GetPosition(this));
            if (pointer == lastPointer) return;
            lastPointer = pointer; Hovered?.Invoke();
        };
    }
}

internal sealed record ActionItem(NoteActionId Id, string Title, string Symbol, IReadOnlyList<string> Keys, bool IsEnabled, int Group)
{
    internal static IReadOnlyList<ActionItem> Standard(bool isPinned, bool hasText) =>
    [
        new(NoteActionId.NewNote, "New Note", "plus", ["Ctrl", "N"], true, 0),
        new(NoteActionId.Pin, isPinned ? "Remove from Pinned" : "Add to Pinned", isPinned ? "pin.slash" : "pin", ["Ctrl", "Shift", "P"], true, 0),
        new(NoteActionId.OpenAsNote, "Open as Note", "arrow.up.left.and.arrow.down.right", ["Ctrl", "O"], true, 1),
        new(NoteActionId.CopyMarkdown, "Copy as Markdown", "doc.on.doc", ["Ctrl", "Shift", "C"], hasText, 1),
        new(NoteActionId.DiscardDraft, "Discard Draft", "trash", ["Ctrl", "Shift", "Bksp"], hasText, 1)
    ];
}

/// <summary>Shared surface of the Actions and Browse cards: fill, border, shadow and the filter-field header.</summary>
internal abstract class NoteCardView : Border
{
    private readonly Canvas canvas = new();
    private readonly Grid fieldHost = new();
    private readonly Border headerSeparator = Ui.Separator();
    protected TextBox Field { get; } = new();
    protected Canvas Surface => canvas;
    internal TextBox FilterField => Field;
    internal double MaximumHeight { get; set; } = double.PositiveInfinity;
    /// <summary>Raised when the card's own size changes (filtering), so the host can resize the window.</summary>
    internal event Action? LayoutChanged;
    internal event Action? CloseRequested;
    internal abstract Size DesiredCardSize { get; }
    protected static double ContentTop => Tokens.CardFieldHeight + Tokens.BorderWidth;
    protected double CappedHeight(double height) => Math.Min(height, MaximumHeight);

    protected NoteCardView(string placeholder, string query)
    {
        CornerRadius = new CornerRadius(Tokens.CardRadius); BorderThickness = new Thickness(Tokens.BorderWidth);
        SetResourceReference(BackgroundProperty, "CardFill"); SetResourceReference(BorderBrushProperty, "CardBorder");
        if (!SystemParameters.HighContrast)
            Effect = new DropShadowEffect { BlurRadius = Tokens.MenuShadowRadius, ShadowDepth = -Tokens.MenuShadowOffset.Y, Direction = Tokens.ShadowDirection, Opacity = Tokens.MenuShadowOpacity, Color = Colors.Black };
        Child = canvas;
        Field.SetResourceReference(StyleProperty, "Overlay.Field");
        Field.SetResourceReference(TextBox.FontFamilyProperty, "Font.UI");
        Field.FontSize = 13; Field.Text = query;
        AutomationProperties.SetName(Field, placeholder);
        var hint = Ui.Text(placeholder, "CardField", "Tertiary"); hint.IsHitTestVisible = false;
        fieldHost.Children.Add(Field); fieldHost.Children.Add(hint);
        void UpdateHint() => hint.Visibility = Field.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Field.TextChanged += (_, _) => { UpdateHint(); OnFilterChanged(); };
        UpdateHint();
    }
    protected abstract void OnFilterChanged();
    protected void RaiseLayoutChanged() { ApplySize(); LayoutChanged?.Invoke(); }
    protected void RequestClose() => CloseRequested?.Invoke();
    protected void BuildHeader()
    {
        var inset = Tokens.CardFieldInset; const double fieldHeight = 20;
        Ui.Place(canvas, fieldHost, inset, (Tokens.CardFieldHeight - fieldHeight) / 2, DesiredCardSize.Width - inset * 2, fieldHeight);
        Ui.Place(canvas, headerSeparator, Tokens.Zero, Tokens.CardFieldHeight, DesiredCardSize.Width, Tokens.BorderWidth);
    }
    /// <summary>Size the card and lay out its content.</summary>
    protected void ApplySize()
    {
        var size = DesiredCardSize; Width = size.Width; Height = size.Height;
        Canvas.SetLeft(fieldHost, Tokens.CardFieldInset);
        fieldHost.Width = size.Width - Tokens.CardFieldInset * 2;
        headerSeparator.Width = size.Width;
        LayoutContent(size);
    }
    protected abstract void LayoutContent(Size size);
    internal void FocusField() { Keyboard.Focus(Field); Field.CaretIndex = Field.Text.Length; }
    internal abstract bool HandleKey(KeyEventArgs e, Key key, ModifierKeys modifiers);
}

internal sealed class NoteActionMenuView : NoteCardView
{
    private readonly IReadOnlyList<ActionItem> items;
    private readonly StackPanel list = new() { Margin = new Thickness(Tokens.Zero, Tokens.CardVerticalPadding, Tokens.Zero, Tokens.CardVerticalPadding) };
    private readonly ScrollViewer scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    private List<ActionItem> visible = [];
    private List<ActionRow> rows = [];
    private int? selection;
    internal event Action<NoteActionId>? Run;
    private static double DividerHeight => Tokens.MenuGroupMargin * 2 + Tokens.BorderWidth;
    private int GroupBreaks => visible.Zip(visible.Skip(1)).Count(pair => pair.First.Group != pair.Second.Group);
    private double ListHeight => visible.Count * Tokens.MenuRowHeight + GroupBreaks * DividerHeight;
    internal NoteActionId? SelectedId => selection is { } index && index < visible.Count ? visible[index].Id : null;
    internal override Size DesiredCardSize => new(Tokens.MenuWidth, CappedHeight(ContentTop + Tokens.CardVerticalPadding * 2 + ListHeight));

    internal NoteActionMenuView(IReadOnlyList<ActionItem> items, string query = "", int? selectedIndex = null) : base("Search actions…", query)
    {
        this.items = items;
        scroll.Content = list;
        Rebuild(selectedIndex);
        BuildHeader();
        Ui.Place(Surface, scroll, Tokens.Zero, ContentTop, Tokens.MenuWidth, 0);
        ApplySize();
    }
    protected override void OnFilterChanged() { Rebuild(null); RaiseLayoutChanged(); }
    private void Rebuild(int? preferred)
    {
        var query = Field.Text.Trim();
        visible = query.Length == 0 ? [.. items] : [.. items.Where(i => i.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase))];
        list.Children.Clear();
        rows = [];
        for (var i = 0; i < visible.Count; i++)
        {
            if (i > 0 && visible[i].Group != visible[i - 1].Group)
            {
                var divider = Ui.Separator(); divider.Height = Tokens.BorderWidth; divider.VerticalAlignment = VerticalAlignment.Center;
                divider.Margin = new Thickness(Tokens.CardFieldInset, Tokens.Zero, Tokens.CardFieldInset, Tokens.Zero);
                list.Children.Add(new Grid { Height = DividerHeight, Children = { divider } });
            }
            var index = i; var item = visible[i];
            var row = new ActionRow(item);
            row.Click += (_, _) => Run?.Invoke(item.Id);
            row.Hovered += () => { if (item.IsEnabled) { selection = index; ApplySelection(); } };
            rows.Add(row); list.Children.Add(row);
        }
        selection = preferred is { } p && p >= 0 && p < visible.Count && visible[p].IsEnabled ? p : visible.FindIndex(i => i.IsEnabled) is var first and >= 0 ? first : null;
        ApplySelection();
    }
    private void ApplySelection()
    {
        for (var i = 0; i < rows.Count; i++) rows[i].SetSelected(i == selection && visible[i].IsEnabled);
    }
    private void Move(int step)
    {
        var enabled = Enumerable.Range(0, visible.Count).Where(i => visible[i].IsEnabled).ToList();
        if (enabled.Count == 0) return;
        if (selection is not { } current || !enabled.Contains(current)) selection = step > 0 ? enabled[0] : enabled[^1];
        else selection = enabled[Math.Clamp(enabled.IndexOf(current) + step, 0, enabled.Count - 1)];
        ApplySelection();
        if (selection is { } index) { scroll.UpdateLayout(); rows[index].BringIntoView(); }
    }
    protected override void LayoutContent(Size size)
    {
        Canvas.SetTop(scroll, ContentTop);
        scroll.Width = size.Width; scroll.Height = Math.Max(Tokens.Zero, size.Height - ContentTop);
    }
    internal override bool HandleKey(KeyEventArgs e, Key key, ModifierKeys modifiers)
    {
        switch (key)
        {
            case Key.Down or Key.Up when modifiers == ModifierKeys.None: Move(key == Key.Down ? 1 : -1); return true;
            case Key.Enter when modifiers == ModifierKeys.None:
                if (selection is { } index && visible[index].IsEnabled) Run?.Invoke(visible[index].Id);
                return true;
            case Key.Escape: RequestClose(); return true;
            case Key.K when modifiers == ModifierKeys.Control: RequestClose(); return true;
            default: return false;
        }
    }

    private sealed class ActionRow : CardRow
    {
        private readonly Border background = new() { CornerRadius = new CornerRadius(Tokens.MenuRowRadius), Margin = new Thickness(Tokens.MenuRowInset, Tokens.Zero, Tokens.MenuRowInset, Tokens.Zero) };
        private readonly TextBlock icon;
        internal ActionRow(ActionItem item)
        {
            Height = Tokens.MenuRowHeight; IsEnabled = item.IsEnabled;
            var inset = Tokens.MenuContentInset - Tokens.MenuRowInset;
            var grid = new Grid { Margin = new Thickness(inset, Tokens.Zero, inset, Tokens.Zero), Opacity = item.IsEnabled ? Tokens.FullOpacity : Tokens.MenuDisabledAlpha };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Tokens.MenuIconSize) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Tokens.One, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            icon = Ui.Icon(item.Symbol, "Secondary", Tokens.MenuIconSize); grid.Children.Add(icon);
            var title = Ui.Text(item.Title, "Menu");
            title.Margin = new Thickness(Tokens.MenuIconGap, Tokens.Zero, Tokens.IconGap, Tokens.Zero); Grid.SetColumn(title, 1); grid.Children.Add(title);
            var keys = new KeycapBoxesView(item.Keys); Grid.SetColumn(keys, 2); grid.Children.Add(keys);
            background.Child = grid; Content = background;
            AutomationProperties.SetName(this, item.Title);
            AutomationProperties.SetHelpText(this, string.Join("+", item.Keys));
        }
        internal void SetSelected(bool selected)
        {
            if (selected) background.SetResourceReference(Border.BackgroundProperty, "MenuSelectedFill"); else background.ClearValue(Border.BackgroundProperty);
            icon.SetResourceReference(TextBlock.ForegroundProperty, selected ? "TextPrimary" : "Secondary");
            AutomationProperties.SetItemStatus(this, selected ? "Selected" : "");
        }
    }
}

internal sealed class NoteBrowseView : NoteCardView
{
    private readonly IReadOnlyList<BrowseItem> items;
    private readonly StackPanel document = new() { Margin = new Thickness(Tokens.Zero, Tokens.CardVerticalPadding, Tokens.Zero, Tokens.CardVerticalPadding) };
    private readonly ScrollViewer scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    private readonly TextBlock message = Ui.Text("", "Message", "Secondary");
    private readonly Border footerSeparator = Ui.Separator();
    private readonly KeycapView[] hints =
    [
        new("↩", "Write here"), new("Ctrl+↩", "Open"), new("Alt+↩", "Reveal")
    ];
    private List<BrowseItem> shown = [];
    private List<BrowseRow> rows = [];
    private int? selection;
    private double visibleHeight;
    internal event Action<BrowseItem, BrowseChoice>? Chosen;
    internal string? SelectedId => selection is { } index && index < shown.Count ? shown[index].Id : null;
    internal string Query => Field.Text;
    private static double FooterHeight => Tokens.BorderWidth + Tokens.BrowseFooterHeight;
    internal override Size DesiredCardSize => new(Tokens.BrowseCardWidth, CappedHeight(ContentTop + (shown.Count == 0 ? Tokens.BrowseEmptyHeight : visibleHeight) + FooterHeight));

    internal NoteBrowseView(IReadOnlyList<BrowseItem> items, string query = "", int? selectedIndex = null) : base("Search notes…", query)
    {
        this.items = items;
        scroll.Content = document;
        message.TextAlignment = TextAlignment.Center;
        Rebuild(selectedIndex);
        BuildHeader();
        Ui.Place(Surface, scroll, Tokens.Zero, ContentTop, Tokens.BrowseCardWidth, 0);
        Ui.Place(Surface, message, Tokens.Zero, ContentTop, Tokens.BrowseCardWidth, Tokens.BrowseEmptyHeight);
        Ui.Place(Surface, footerSeparator, Tokens.Zero, 0, Tokens.BrowseCardWidth, Tokens.BorderWidth);
        var x = (double)Tokens.BrowseFooterInset;
        foreach (var hint in hints)
        {
            var width = Ui.NaturalWidth(hint);
            Ui.Place(Surface, hint, x, 0, width, Tokens.HintHeight); x += width + Tokens.FooterHintGap;
        }
        AutomationProperties.SetHelpText(hints[2], "Show in File Explorer");
        ApplySize();
        if (selection is > 0) { scroll.UpdateLayout(); rows[selection.Value].BringIntoView(); }
    }
    protected override void OnFilterChanged() { Rebuild(null); RaiseLayoutChanged(); scroll.ScrollToTop(); }
    private void Rebuild(int? preferred)
    {
        var query = Field.Text.Trim();
        var matching = query.Length == 0 ? [.. items] : items.Where(i => i.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        // Pinned first; cap the rows built so thousands of notes stay cheap per keystroke.
        shown = [.. matching.Where(i => i.IsPinned).Concat(matching.Where(i => !i.IsPinned)).Take(Tokens.BrowseMaxRows)];
        var pinned = shown.TakeWhile(i => i.IsPinned).Count();
        document.Children.Clear(); rows = [];
        double y = Tokens.CardVerticalPadding, visibleEnd = Tokens.CardVerticalPadding;
        for (var i = 0; i < shown.Count; i++)
        {
            if (i == 0 && pinned > 0 || i == pinned && shown.Count > pinned)
            {
                document.Children.Add(Header(i == 0 && pinned > 0 ? "Pinned" : "Recent")); y += Tokens.BrowseHeaderHeight;
            }
            var index = i; var item = shown[i];
            var row = new BrowseRow(item);
            row.Click += (_, _) => { Select(index); Choose(index, BrowseChoice.Write); };
            row.Hovered += () => Select(index, false);
            rows.Add(row); document.Children.Add(row);
            y += Tokens.BrowseRowHeight;
            if (i < Tokens.BrowseVisibleRows) visibleEnd = y;
        }
        visibleHeight = Math.Min(y, visibleEnd) + Tokens.CardVerticalPadding;
        message.Text = shown.Count == 0 ? (items.Count == 0 ? "No notes yet" : "No matching notes") : "";
        message.Visibility = shown.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        scroll.Visibility = shown.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        selection = preferred is { } p && p >= 0 && p < shown.Count ? p : shown.Count == 0 ? null : 0;
        for (var i = 0; i < rows.Count; i++) rows[i].SetSelected(i == selection);
    }
    private static FrameworkElement Header(string title)
    {
        var text = Ui.Text(title, "BrowseHeader", "Tertiary");
        text.Margin = new Thickness(Tokens.MenuContentInset, Tokens.Zero, Tokens.MenuContentInset, Tokens.Zero);
        return new Grid { Height = Tokens.BrowseHeaderHeight, Children = { text } };
    }
    private void Select(int index, bool scrollIntoView = true)
    {
        if (index < 0 || index >= rows.Count) return;
        selection = index;
        for (var i = 0; i < rows.Count; i++) rows[i].SetSelected(i == index);
        if (scrollIntoView) { scroll.UpdateLayout(); rows[index].BringIntoView(); }
    }
    private void Choose(int index, BrowseChoice choice)
    {
        if (index >= 0 && index < shown.Count) Chosen?.Invoke(shown[index], choice);
    }
    protected override void LayoutContent(Size size)
    {
        var area = Math.Max(Tokens.Zero, size.Height - ContentTop - FooterHeight);
        Canvas.SetTop(scroll, ContentTop); scroll.Width = size.Width; scroll.Height = area;
        Canvas.SetTop(message, ContentTop); message.Height = Tokens.BrowseEmptyHeight; message.Width = size.Width;
        Canvas.SetTop(footerSeparator, size.Height - FooterHeight); footerSeparator.Width = size.Width;
        foreach (var hint in hints) Canvas.SetTop(hint, size.Height - Tokens.BrowseFooterHeight + (Tokens.BrowseFooterHeight - Tokens.HintHeight) / 2.0);
    }
    internal override bool HandleKey(KeyEventArgs e, Key key, ModifierKeys modifiers)
    {
        switch (key)
        {
            case Key.Down or Key.Up when modifiers == ModifierKeys.None:
                if (shown.Count > 0) Select(Math.Clamp((selection ?? (key == Key.Down ? -1 : shown.Count)) + (key == Key.Down ? 1 : -1), 0, shown.Count - 1));
                return true;
            case Key.Enter:
                if (selection is { } index) Choose(index, modifiers.HasFlag(ModifierKeys.Control) ? BrowseChoice.Open : modifiers.HasFlag(ModifierKeys.Alt) ? BrowseChoice.Reveal : BrowseChoice.Write);
                return true;
            case Key.Escape: RequestClose(); return true;
            case Key.P when modifiers == ModifierKeys.Control: RequestClose(); return true;
            default: return false;
        }
    }

    private sealed class BrowseRow : CardRow
    {
        private readonly Border background = new() { CornerRadius = new CornerRadius(Tokens.MenuRowRadius), Margin = new Thickness(Tokens.MenuRowInset, Tokens.Zero, Tokens.MenuRowInset, Tokens.Zero) };
        internal BrowseRow(BrowseItem item)
        {
            Height = Tokens.BrowseRowHeight;
            var inset = Tokens.MenuContentInset - Tokens.MenuRowInset;
            var grid = new Grid { Margin = new Thickness(inset, Tokens.Zero, inset, Tokens.Zero) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Tokens.BrowseIconSize) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Tokens.One, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(Ui.Icon(item.SymbolName, "Secondary", Tokens.BrowseIconSize));
            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(Tokens.BrowseRowTextInset, Tokens.Zero, Tokens.Zero, Tokens.Zero) };
            texts.Children.Add(Ui.Text(item.Title, "BrowseTitle"));
            if (item.Detail.Length > 0)
            {
                var detail = Ui.Text(item.Detail, "Meta", "Secondary"); detail.Margin = new Thickness(Tokens.Zero, Tokens.BrowseDetailGap, Tokens.Zero, Tokens.Zero);
                texts.Children.Add(detail);
            }
            Grid.SetColumn(texts, 1); grid.Children.Add(texts);
            if (item.IsPinned)
            {
                var pin = Ui.Icon("pin.fill", "Tertiary", Tokens.BrowsePinSize); pin.Margin = new Thickness(Tokens.BrowseRowTextInset, Tokens.Zero, Tokens.Zero, Tokens.Zero);
                Grid.SetColumn(pin, 2); grid.Children.Add(pin);
            }
            background.Child = grid; Content = background;
            AutomationProperties.SetName(this, string.Join(", ", new[] { item.Title, item.Detail }.Where(s => s.Length > 0)));
        }
        internal void SetSelected(bool selected)
        {
            if (selected) background.SetResourceReference(Border.BackgroundProperty, "MenuSelectedFill"); else background.ClearValue(Border.BackgroundProperty);
            AutomationProperties.SetItemStatus(this, selected ? "Selected" : "");
        }
    }
}
