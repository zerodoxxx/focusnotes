using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using CaptureApp.Overlay.Interop;

namespace CaptureApp.Overlay;

/// <summary>A 26 pt icon button that never takes focus, so the editor keeps the caret.</summary>
internal sealed class ChromeButton : System.Windows.Controls.Button
{
    private readonly Border background = new() { CornerRadius = new CornerRadius(Tokens.QuickButtonSize / 2.0) };
    private readonly TextBlock icon;
    private bool on;
    internal ChromeButton(string symbol, string tooltip, string label)
    {
        SetResourceReference(StyleProperty, "Overlay.Row");
        Focusable = false; Width = Height = Tokens.QuickButtonSize; ToolTip = tooltip;
        icon = Ui.Icon(symbol, "Secondary", Tokens.QuickSymbolSize); icon.HorizontalAlignment = HorizontalAlignment.Center;
        background.Child = icon; Content = background;
        MouseEnter += (_, _) => UpdateAppearance(); MouseLeave += (_, _) => UpdateAppearance();
        AutomationProperties.SetName(this, label);
    }
    internal bool IsOn { get => on; set { on = value; AutomationProperties.SetItemStatus(this, value ? "On" : ""); UpdateAppearance(); } }
    protected override void OnIsPressedChanged(DependencyPropertyChangedEventArgs e) { base.OnIsPressedChanged(e); UpdateAppearance(); }
    private void UpdateAppearance()
    {
        icon.SetResourceReference(TextBlock.ForegroundProperty, IsMouseOver || IsPressed || on ? "TextPrimary" : "Secondary");
        if (IsPressed || on) background.SetResourceReference(Border.BackgroundProperty, "QuickButtonPressedFill");
        else if (IsMouseOver) background.SetResourceReference(Border.BackgroundProperty, "QuickButtonHoverFill");
        else background.ClearValue(Border.BackgroundProperty);
    }
}

/// <summary>
/// The quick-note surface: editor, top band chrome, footer hints, title line and the Actions / Browse cards.
/// The visible note keeps its own size; a card that hangs below it extends only the (transparent) overflow.
/// </summary>
public sealed class QuickNoteView : OverlaySurface, IDisposable
{
    /// <summary>Marks text that is trimmed with an ellipsis on purpose, so layout checks do not flag it.</summary>
    public const string TrimmedTag = "Trimmed";
    private const double BandsHeight = Tokens.QuickTopBandHeight + Tokens.QuickFooterHeight;
    private readonly Border topBand = Transparent(), footerBand = Transparent(), hover = Transparent();
    private readonly Canvas chrome = new(), footer = new();
    private readonly Border cluster = new() { CornerRadius = new CornerRadius(Tokens.QuickClusterRadius), BorderThickness = new Thickness(Tokens.BorderWidth) };
    private readonly ChromeButton close = new("xmark", "Close (Esc)", "Close"), open = new("arrow.up.left.and.arrow.down.right", "Open as note (Ctrl+O)", "Open as note"),
        browse = new("rectangle.on.rectangle.angled", "Browse notes (Ctrl+P)", "Browse notes"), create = new("plus", "New note (Ctrl+N)", "New note"),
        actions = new("ellipsis", "Actions (Ctrl+K)", "Actions");
    private readonly TextBlock title = Ui.Text("", "QuickTitle", accessible: true), draftLabel = Ui.Text("Draft kept", "Meta", "Tertiary");
    private readonly TextBlock pin = Ui.Icon("pin.fill", "TextPrimary", Tokens.QuickTitlePinSize);
    private readonly KeycapView actionsHint = new("Ctrl+K", "Actions"), closeHint = new("Esc", "Close");
    private KeycapView saveHint = new("Ctrl+↩", "Create note");
    private readonly bool restoredDraft;
    private readonly DispatcherTimer measureTimer = new() { Interval = TimeSpan.FromMilliseconds(Tokens.MeasureQuietMilliseconds) };
    private readonly ThemeManager quickNoteTheme;
    private double currentWidth = Tokens.QuickMinWidth, textHeight, overflow, workAreaHeight = SystemParameters.WorkArea.Height;
    private bool pointerInside, measurePending, suppressMeasure, disposed;
    private NoteCardView? card;
    private string? destination;
    private bool isPinned;

    public MarkdownEditor Editor { get; } = new();
    public string? Destination => destination;
    public bool IsPinned => isPinned;
    public Func<IReadOnlyList<BrowseItem>> BrowseItems { get; set; } = () => [];
    private Func<string, string> titleForText = QuickNoteHandlers.DefaultTitle;
    private bool constructed;
    public Func<string, string> TitleForText
    {
        get => titleForText;
        set { titleForText = value; if (constructed) { UpdateTitle(); LayoutTitle(Width); } }
    }
    /// <summary>Height available to a card below the top of the note; the host recomputes it from the screen.</summary>
    public Func<double>? CardHeightProvider { get; set; }
    public event Action<bool>? Resized;
    public event Action? SaveRequested, CloseRequested, DragRequested;
    public event Action<NoteActionId>? ActionRequested;
    public event Action<BrowseItem, BrowseChoice>? BrowseChosen;
    public event Action<string>? TextChanged;
    public bool IsCardOpen => card is not null;
    /// <summary>Size of the open card, for layout checks; null when none is open.</summary>
    public Size? CardSize => card?.DesiredCardSize;
    public bool HoldsReveal => card is not null;
    public double TextHeight => textHeight;
    public Size NoteSize => new(currentWidth, Math.Ceiling(BandsHeight + textHeight));
    public double EditorLineHeight => Editor.LineHeight;
    public double WorkAreaHeight { get => workAreaHeight; set { workAreaHeight = value; if (constructed) Remeasure(); } }

    private static Border Transparent() => new() { Background = Brushes.Transparent };
    private static void Position(FrameworkElement element, double x, double y, double width, double height)
    {
        Canvas.SetLeft(element, x); Canvas.SetTop(element, y); element.Width = Math.Max(Tokens.Zero, width); element.Height = Math.Max(Tokens.Zero, height);
    }

    public QuickNoteView(string? destination, bool isPinned, string draft, bool restoredDraft)
        : base(Tokens.QuickMinWidth, Tokens.QuickTopBandHeight + Tokens.QuickFooterHeight + Tokens.EditorMinLines * Math.Ceiling(Tokens.EditorFontSize * 1.4), Tokens.QuickPanelRadius)
    {
        quickNoteTheme = new ThemeManager(Resources, darkOverride: true);
        this.restoredDraft = restoredDraft; this.destination = destination; this.isPinned = isPinned;
        AutomationProperties.SetName(this, "Quick Note");
        AutomationProperties.SetName(Editor, "Note text");
        cluster.SetResourceReference(Border.BackgroundProperty, "QuickClusterFill"); cluster.SetResourceReference(Border.BorderBrushProperty, "QuickClusterBorder");
        title.TextAlignment = TextAlignment.Center; title.TextTrimming = TextTrimming.CharacterEllipsis; title.TextWrapping = TextWrapping.NoWrap; title.Tag = TrimmedTag; title.IsHitTestVisible = false; title.Opacity = Tokens.QuickTitleRestAlpha; pin.Opacity = Tokens.QuickTitleRestAlpha;
        pin.IsHitTestVisible = false; pin.Visibility = isPinned ? Visibility.Visible : Visibility.Collapsed;
        footer.IsHitTestVisible = false; chrome.Opacity = Tokens.Zero; footer.Opacity = Tokens.Zero; chrome.IsHitTestVisible = false;
        foreach (var element in new UIElement[] { hover, topBand, footerBand, Editor, title, pin, chrome, footer }) Body.Children.Add(element);
        chrome.Children.Add(cluster);
        foreach (var button in new[] { close, open, browse, create, actions }) chrome.Children.Add(button);
        foreach (var hint in new UIElement[] { saveHint, actionsHint, closeHint, draftLabel }) footer.Children.Add(hint);
        close.Click += (_, _) => { HideCard(); CloseRequested?.Invoke(); };
        open.Click += (_, _) => { HideCard(); Perform(NoteActionId.OpenAsNote); };
        actions.Click += (_, _) => ToggleActions();
        browse.Click += (_, _) => Perform(NoteActionId.Browse);
        create.Click += (_, _) => { HideCard(); Perform(NoteActionId.NewNote); };
        topBand.MouseLeftButtonDown += (_, _) => DragRequested?.Invoke();
        footerBand.MouseLeftButtonDown += (_, _) => DragRequested?.Invoke();
        MouseEnter += (_, _) => { pointerInside = true; ApplyReveal(true); };
        MouseLeave += (_, _) => { pointerInside = false; ApplyReveal(true); };
        PreviewMouseLeftButtonDown += OnPreviewMouseDown;
        measureTimer.Tick += (_, _) => { measureTimer.Stop(); Remeasure(true); };
        suppressMeasure = true;
        Editor.SetText(draft);
        suppressMeasure = false;
        Editor.TextChanged += (_, _) => OnEditorChanged();
        UpdateTitle();
        Remeasure();
        constructed = true;
    }

    // MARK: Destination and title

    public void SetDestination(string? value, bool pinned)
    {
        destination = value; isPinned = pinned;
        pin.Visibility = pinned ? Visibility.Visible : Visibility.Collapsed;
        RebuildSaveHint(); UpdateTitle();
        Remeasure(); // The caption can raise the minimum width.
    }
    private void RebuildSaveHint()
    {
        footer.Children.Remove(saveHint);
        saveHint = new KeycapView("Ctrl+↩", destination is null ? "Create note" : "Add to note");
        footer.Children.Add(saveHint);
    }
    /// <summary>Destination title, else the title the text will be saved under, else a placeholder name.</summary>
    private void UpdateTitle()
    {
        var text = Editor.Head(4_000); var value = destination ?? Tokens.QuickEmptyTitle;
        if (destination is null && text.TakeWhile(char.IsWhiteSpace).Count() is var first && first < text.Length)
        {
            // Only the head of the note can name it, so keep this cheap for long drafts.
            var named = titleForText(text.Substring(first, Math.Min(2_000, text.Length - first)));
            if (named.Length > 0) value = named;
        }
        title.Text = value;
        AutomationProperties.SetName(title, value);
    }

    // MARK: Measuring and layout

    private void OnEditorChanged()
    {
        UpdateTitle();
        TextChanged?.Invoke(Editor.Text);
        if (suppressMeasure) return;
        if (Editor.TextLength > Tokens.EditorRestyleLimit) { measureTimer.Stop(); measureTimer.Start(); return; } // Debounce measuring for large notes.
        if (measurePending) return;
        measurePending = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Send, () => { measurePending = false; if (!disposed) Remeasure(true); });
    }
    private double DraftWidth()
    {
        // A collapsed element measures zero, so measure it visible and restore.
        var visibility = draftLabel.Visibility; draftLabel.Visibility = Visibility.Visible; draftLabel.ClearValue(WidthProperty);
        var width = Ui.NaturalWidth(draftLabel); draftLabel.Visibility = visibility;
        return width;
    }
    private double FooterNaturalWidth(bool includeDraft)
    {
        var items = new FrameworkElement[] { saveHint, actionsHint, closeHint };
        var width = Tokens.QuickFooterLeadingInset * 2 + items.Sum(Ui.NaturalWidth) + Tokens.FooterHintGap * (items.Length - 1);
        if (includeDraft) width += Tokens.FooterHintGap + DraftWidth();
        return Math.Ceiling(width);
    }
    private double MaximumTextHeight => Math.Max(Editor.LineHeight * Tokens.EditorMinLines, Math.Min(workAreaHeight * Tokens.QuickMaxHeightFraction, Tokens.QuickMaxHeight) - BandsHeight);
    /// <summary>Recompute width (ratchets up only) and height (two lines up to the screen cap), then lay out.</summary>
    public void Remeasure(bool animated = false)
    {
        var floor = Math.Max(Tokens.QuickMinWidth, FooterNaturalWidth(restoredDraft));
        if (currentWidth < Tokens.QuickMaxWidth)
            currentWidth = Math.Max(currentWidth, Math.Min(Tokens.QuickMaxWidth, Math.Max(floor, Editor.NaturalTextWidth() + Tokens.QuickTextInset * 2)));
        var maximum = MaximumTextHeight; var minimum = Editor.LineHeight * Tokens.EditorMinLines;
        var used = Editor.MeasureDocument(currentWidth - Tokens.QuickTextInset * 2, maximum + 1);
        textHeight = Math.Min(maximum, Math.Max(minimum, used));
        Layout(animated);
    }
    private void Layout(bool animated)
    {
        var old = SurfaceSize;
        var note = NoteSize; var width = note.Width; var noteHeight = note.Height;
        var cardLimit = CardHeightProvider?.Invoke() ?? double.PositiveInfinity;
        if (card is not null)
        {
            card.MaximumHeight = cardLimit;
            var size = card.DesiredCardSize;
            overflow = Math.Max(Tokens.Zero, Math.Ceiling(Tokens.QuickTopBandHeight + Tokens.CardTopGap + size.Height + Tokens.CardEdgeMargin) - noteHeight);
        }
        else overflow = Tokens.Zero;
        Width = width; Height = noteHeight + overflow;
        ((Border)Children[0]).Margin = new Thickness(Tokens.Zero, Tokens.Zero, Tokens.Zero, overflow); // The tint and shadow follow the note only.
        var inset = Tokens.QuickTextInset;
        Position(hover, 0, 0, width, noteHeight);
        Position(topBand, 0, 0, width, Tokens.QuickTopBandHeight);
        Position(footerBand, 0, noteHeight - Tokens.QuickFooterHeight, width, Tokens.QuickFooterHeight);
        Position(Editor, inset, Tokens.QuickTopBandHeight, width - inset * 2, textHeight);
        LayoutChrome(width);
        LayoutTitle(width);
        Position(footer, 0, noteHeight - Tokens.QuickFooterHeight, width, Tokens.QuickFooterHeight);
        LayoutFooter(width);
        if (card is not null)
        {
            var size = card.DesiredCardSize;
            Position(card, width - Tokens.CardEdgeMargin - size.Width, Tokens.QuickTopBandHeight + Tokens.CardTopGap, size.Width, size.Height);
        }
        if (Math.Abs(old.Width - Width) > Tokens.LayoutTolerance || Math.Abs(old.Height - Height) > Tokens.LayoutTolerance) Resized?.Invoke(animated);
    }
    private void LayoutChrome(double width)
    {
        Position(chrome, 0, 0, width, Tokens.QuickTopBandHeight);
        const double size = Tokens.QuickButtonSize, gap = Tokens.QuickButtonGap, edge = Tokens.QuickChromeEdgeInset;
        var y = (Tokens.QuickTopBandHeight - size) / 2;
        var x = (double)edge;
        foreach (var button in new[] { close, open }) { Position(button, x, y, size, size); x += size + gap; }
        var clusterWidth = size * 3 + Tokens.QuickClusterPadding * 2;
        var clusterX = width - edge - clusterWidth;
        Position(cluster, clusterX, (Tokens.QuickTopBandHeight - Tokens.QuickClusterHeight) / 2, clusterWidth, Tokens.QuickClusterHeight);
        x = clusterX + Tokens.QuickClusterPadding;
        foreach (var button in new[] { browse, create, actions }) { Position(button, x, y, size, size); x += size; }
    }
    private void LayoutTitle(double width)
    {
        const double widest = Tokens.QuickChromeEdgeInset + Tokens.QuickButtonSize * 3 + Tokens.QuickClusterPadding * 2;
        var pinExtent = isPinned ? Tokens.QuickTitlePinSize + Tokens.QuickTitlePinGap : Tokens.Zero;
        var available = Math.Max(Tokens.Zero, width - 2 * (widest + Tokens.QuickTitleClusterGap));
        title.ClearValue(WidthProperty); // Measure the text itself, not the previous placement.
        var titleWidth = Math.Min(Ui.NaturalWidth(title), Math.Max(Tokens.Zero, available - pinExtent));
        var leading = (width - titleWidth - pinExtent) / 2;
        Position(pin, leading, (Tokens.QuickTopBandHeight - Tokens.QuickTitlePinSize) / 2.0, Tokens.QuickTitlePinSize, Tokens.QuickTitlePinSize);
        Position(title, leading + pinExtent, (Tokens.QuickTopBandHeight - Tokens.TitleLineHeight) / 2.0, titleWidth, Tokens.TitleLineHeight);
    }
    private void LayoutFooter(double width)
    {
        var y = (Tokens.QuickFooterHeight - Tokens.HintHeight) / 2.0; var x = (double)Tokens.QuickFooterLeadingInset;
        foreach (var hint in new FrameworkElement[] { saveHint, actionsHint, closeHint })
        {
            var hintWidth = Ui.NaturalWidth(hint); Position(hint, x, y, hintWidth, Tokens.HintHeight); x += hintWidth + Tokens.FooterHintGap;
        }
        // "Draft kept" is the first thing dropped when the footer cannot fit it.
        var showDraft = restoredDraft && FooterNaturalWidth(true) <= width;
        draftLabel.Visibility = showDraft ? Visibility.Visible : Visibility.Collapsed;
        var draftWidth = DraftWidth();
        Position(draftLabel, width - Tokens.QuickFooterLeadingInset - draftWidth, (Tokens.QuickFooterHeight - Tokens.MetaLineHeight) / 2.0, draftWidth, Tokens.MetaLineHeight);
    }

    // MARK: Reveal

    public void SetRevealed(bool revealed, bool animated)
    {
        chrome.IsHitTestVisible = revealed;
        var titleAlpha = revealed ? Tokens.QuickTitleRevealAlpha : Tokens.QuickTitleRestAlpha;
        var duration = revealed ? Tokens.QuickRevealIn : Tokens.QuickRevealOut;
        foreach (var (element, value) in new (UIElement, double)[] { (chrome, revealed ? 1 : 0), (footer, revealed ? 1 : 0), (title, titleAlpha), (pin, titleAlpha) })
        {
            var from = element.Opacity;
            element.BeginAnimation(OpacityProperty, null); element.Opacity = value;
            if (!animated || !SystemParameters.ClientAreaAnimation) continue;
            element.BeginAnimation(OpacityProperty, new DoubleAnimation(from, value, TimeSpan.FromSeconds(duration)) { EasingFunction = new CubicEase { EasingMode = revealed ? EasingMode.EaseOut : EasingMode.EaseIn } });
        }
    }
    private void ApplyReveal(bool animated) => SetRevealed(pointerInside || HoldsReveal, animated);
    /// <summary>Called once the panel is on screen, so a pointer that is already over it shows the chrome.</summary>
    public void RevealIfPointerInside() { if (IsMouseOver) { pointerInside = true; ApplyReveal(false); } }

    // MARK: Actions and cards

    public void Perform(NoteActionId id)
    {
        switch (id)
        {
            case NoteActionId.CopyMarkdown:
                if (Editor.TextLength == 0) return;
                try { Clipboard.SetText(Editor.Text); } catch (System.Runtime.InteropServices.COMException) { } // The clipboard can be locked by another process.
                break;
            case NoteActionId.DiscardDraft:
                if (Editor.TextLength > 0) Editor.Replace(0, Editor.TextLength, ""); // Undoable; raises TextChanged.
                break;
            case NoteActionId.Browse: ToggleBrowse(); break;
            default: ActionRequested?.Invoke(id); break;
        }
    }
    public void ToggleActions() { if (card is NoteActionMenuView) HideActions(); else ShowActions(); }
    public void ShowActions(string query = "", int? selectedIndex = null)
    {
        if (card is NoteActionMenuView) return;
        DetachCard();
        var menu = new NoteActionMenuView(ActionItem.Standard(isPinned, Editor.TextLength > 0), query, selectedIndex);
        menu.Run += id => { HideActions(); Perform(id); };
        menu.CloseRequested += HideActions;
        Attach(menu);
    }
    public void HideActions() { if (card is NoteActionMenuView) { DetachCard(); CardClosed(); } }
    public void ShowBrowse(IReadOnlyList<BrowseItem> items, string query = "", int? selectedIndex = null)
    {
        if (card is NoteBrowseView) return;
        DetachCard();
        Attach(NewBrowse(items, query, selectedIndex));
    }
    private NoteBrowseView NewBrowse(IReadOnlyList<BrowseItem> items, string query, int? selectedIndex)
    {
        var view = new NoteBrowseView(items, query, selectedIndex);
        view.Chosen += (item, choice) => BrowseChosen?.Invoke(item, choice);
        view.CloseRequested += HideBrowse;
        return view;
    }
    /// <summary>Rebuild an open Browse card from a fresh snapshot, keeping its filter text and selected note.</summary>
    public void RefreshBrowseItems()
    {
        if (card is not NoteBrowseView current) return;
        var query = current.Query; var selectedId = current.SelectedId; var items = BrowseItems();
        var trimmed = query.Trim();
        var matches = trimmed.Length == 0 ? items.ToList() : items.Where(i => i.Title.Contains(trimmed, StringComparison.CurrentCultureIgnoreCase)).ToList();
        var shown = matches.Where(i => i.IsPinned).Concat(matches.Where(i => !i.IsPinned)).Take(Tokens.BrowseMaxRows).ToList();
        var index = selectedId is null ? -1 : shown.FindIndex(i => i.Id == selectedId);
        DetachCard();
        Attach(NewBrowse(items, query, index >= 0 ? index : null));
    }
    public void HideBrowse() { if (card is NoteBrowseView) { DetachCard(); CardClosed(); } }
    public void ToggleBrowse() { if (card is NoteBrowseView) HideBrowse(); else ShowBrowse(BrowseItems()); }
    private void HideCard() { if (card is not null) { DetachCard(); CardClosed(); } }
    /// <summary>Closes the topmost overlay; false when none is open.</summary>
    public bool CloseOverlay()
    {
        if (card is null) return false;
        HideCard(); return true;
    }
    private void Attach(NoteCardView view)
    {
        card = view;
        view.LayoutChanged += OnCardLayoutChanged;
        browse.IsOn = view is NoteBrowseView; actions.IsOn = view is NoteActionMenuView;
        Body.Children.Add(view);
        ApplyReveal(false);
        Layout(false);
        view.UpdateLayout();
        FocusCardField(view);
    }
    private void DetachCard()
    {
        if (card is null) return;
        card.LayoutChanged -= OnCardLayoutChanged;
        Body.Children.Remove(card);
        card = null; browse.IsOn = false; actions.IsOn = false;
    }
    private void OnCardLayoutChanged() => Layout(false);
    private void CardClosed()
    {
        ApplyReveal(true);
        Layout(false);
        FocusEditor();
    }
    private void FocusCardField(NoteCardView view)
    {
        if (Window.GetWindow(this) is not { } window) return;
        if (window.IsActive) view.FocusField(); else FocusManager.SetFocusedElement(window, view.FilterField);
    }
    /// <summary>The note text regains focus; while the window is inactive only its logical focus moves.</summary>
    public void FocusEditor()
    {
        if (Window.GetWindow(this) is not { } window) return;
        if (window.IsActive) Keyboard.Focus(Editor.FocusTarget); else FocusManager.SetFocusedElement(window, Editor.FocusTarget);
    }
    /// <summary>The window lost the keyboard: a card closes and the note text becomes the logical focus again.</summary>
    public void OnResigned() { CloseOverlay(); FocusEditor(); }
    private void OnPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        // A click outside the open card closes it, but never swallows the click (text, bands and buttons still act).
        if (card is null || e.OriginalSource is not DependencyObject source || IsWithin(card, source) || IsWithin(chrome, source)) return;
        HideCard();
    }
    private static bool IsWithin(DependencyObject ancestor, DependencyObject? node)
    {
        while (node is not null)
        {
            if (node == ancestor) return true;
            node = node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node);
        }
        return false;
    }

    // MARK: Keys

    private static NoteActionId? ShortcutAction(Key key, ModifierKeys modifiers)
    {
        var ctrl = modifiers == ModifierKeys.Control; var shift = modifiers == (ModifierKeys.Control | ModifierKeys.Shift);
        return key switch
        {
            Key.C when shift => NoteActionId.CopyMarkdown,
            Key.P when shift => NoteActionId.Pin,
            Key.P when ctrl => NoteActionId.Browse,
            Key.N when ctrl => NoteActionId.NewNote,
            Key.O when ctrl => NoteActionId.OpenAsNote,
            Key.Back when shift => NoteActionId.DiscardDraft,
            _ => null
        };
    }
    /// <summary>Panel-level keys (window preview): Ctrl+Enter, Ctrl+K/P/N/O, Ctrl+Shift+P/C/Backspace and the open card's keys.</summary>
    public bool HandleKey(KeyEventArgs e)
    {
        if (e.Key == Key.ImeProcessed) return false;
        var key = e.Key == Key.System ? e.SystemKey : e.Key; var modifiers = Keyboard.Modifiers;
        if (card is { } open)
        {
            // Only the card's own field owns the keyboard; otherwise the card is stale.
            if (open.FilterField.IsKeyboardFocusWithin)
            {
                if (open.HandleKey(e, key, modifiers)) return true;
                if (open is NoteBrowseView)
                {
                    if (key != Key.K || modifiers != ModifierKeys.Control) return false;
                    ShowActions(); return true; // Swaps Browse for Actions.
                }
                if (ShortcutAction(key, modifiers) is not { } shortcut) return false;
                HideActions(); Perform(shortcut); return true;
            }
            if (key == Key.Escape || key == Key.K && modifiers == ModifierKeys.Control) { HideCard(); return true; }
        }
        if (!modifiers.HasFlag(ModifierKeys.Control) || modifiers.HasFlag(ModifierKeys.Alt)) return false;
        if (ShortcutAction(key, modifiers) is { } action) { Perform(action); return true; }
        switch (key)
        {
            case Key.K when modifiers == ModifierKeys.Control: ToggleActions(); return true;
            case Key.Enter: SaveRequested?.Invoke(); return true;
            default: return false;
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true; measureTimer.Stop(); Editor.Dispose(); quickNoteTheme.Dispose();
    }
}

/// <summary>Owns the quick-note window; the App calls <see cref="TogglePresent"/> on the note hotkey.</summary>
public sealed class QuickNoteController
{
    private OverlayWindow? panel;
    private QuickNoteView? view;
    public IPanelPositionStore? PositionStore { get; set; }
    public bool IsVisible => panel?.IsVisible == true;
    public bool IsActive => panel?.IsActive == true;

    public void Present(string? destination, bool isPinned, string draft, QuickNoteHandlers handlers)
    {
        panel?.Dismiss(DismissReason.Replaced, false);
        var monitor = MonitorGeometry.UnderPointer();
        var content = new QuickNoteView(destination, isPinned, draft, draft.Length > 0)
        {
            TitleForText = handlers.TitleForText ?? QuickNoteHandlers.DefaultTitle, BrowseItems = handlers.BrowseItems, WorkAreaHeight = monitor.WorkArea.Height
        };
        var window = new OverlayWindow(content) { IsSticky = true, IsMovable = true, PositionStore = PositionStore };
        panel = window; view = content;
        content.CardHeightProvider = () => Math.Max(Tokens.Zero, MonitorGeometry.UnderPointer().WorkArea.Bottom - window.VisibleRect.Top - Tokens.QuickTopBandHeight - Tokens.CardTopGap - Tokens.CardEdgeMargin);
        // Persisting the draft is the dismissal gate: a failed write keeps the panel open.
        window.ShouldDismiss = () =>
        {
            try { handlers.OnDraft(content.Editor.Text); return true; }
            catch (Exception exception) { handlers.OnError(exception); return false; }
        };
        window.CancelHandler = content.CloseOverlay;
        window.Resigned += content.OnResigned;
        window.PreviewKeyDown += (_, e) => { if (content.HandleKey(e)) e.Handled = true; };
        content.Resized += animated => window.ResizeVisible(content.SurfaceSize, animated);
        content.DragRequested += window.MoveFromBand;
        content.CloseRequested += () => window.Dismiss();
        content.TextChanged += text =>
        {
            if (handlers.OnScheduleDraft is { } schedule) { schedule(text); return; }
            try { handlers.OnDraft(text); } catch (Exception exception) { handlers.OnError(exception); }
        };
        content.SaveRequested += () => { var text = content.Editor.Text; if (window.Dismiss()) handlers.OnSubmit(text); };
        content.ActionRequested += id =>
        {
            var text = content.Editor.Text;
            switch (id)
            {
                case NoteActionId.NewNote:
                    if (string.IsNullOrWhiteSpace(text)) handlers.OnNew("");
                    else if (window.Dismiss()) handlers.OnNew(text);
                    break;
                case NoteActionId.OpenAsNote:
                    if (window.Dismiss()) handlers.OnOpenAsNote(text);
                    break;
                case NoteActionId.Pin: content.SetDestination(content.Destination, handlers.OnTogglePin()); break;
            }
        };
        content.BrowseChosen += (item, choice) =>
        {
            if (choice == BrowseChoice.Write) { handlers.OnBrowse(item, choice); content.HideBrowse(); return; }
            if (window.Dismiss()) handlers.OnBrowse(item, choice);
        };
        window.Closed += (_, _) =>
        {
            if (panel != window) return;
            panel = null; view = null; content.Dispose(); handlers.OnClose();
        };
        window.Present(true, content.Editor.FocusTarget);
        window.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => { content.RevealIfPointerInside(); content.Editor.ScrollToCaret(); });
    }
    /// <summary>Hotkey semantics: visible but inactive reactivates in place; active closes keeping the draft; otherwise present.</summary>
    public QuickNoteToggle TogglePresent(string? destination, bool isPinned, string draft, QuickNoteHandlers handlers)
    {
        if (panel is { IsVisible: true } window && view is not null)
        {
            if (window.IsActive) { window.Dismiss(); return QuickNoteToggle.Closed; }
            Focus(); return QuickNoteToggle.Reactivated;
        }
        Present(destination, isPinned, draft, handlers);
        return QuickNoteToggle.Presented;
    }
    /// <summary>Take the keyboard again without rebuilding the editor, preserving text, caret and scroll.</summary>
    public void Focus()
    {
        if (panel is not { IsVisible: true } window || view is null) return;
        window.ActivateForTyping(view.Editor.FocusTarget);
    }
    public bool Dismiss(DismissReason reason = DismissReason.Explicit) => panel?.Dismiss(reason) ?? true;
    public void SetDestination(string? title, bool isPinned) => view?.SetDestination(title, isPinned);
    public void RefreshBrowseItems() => view?.RefreshBrowseItems();
}
