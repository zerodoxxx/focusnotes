using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.TextFormatting;
using System.Windows.Threading;
using ICSharpCode.AvalonEdit;
using ICSharpCode.AvalonEdit.Document;
using ICSharpCode.AvalonEdit.Editing;
using ICSharpCode.AvalonEdit.Rendering;
using Microsoft.Win32;

namespace CaptureApp.Overlay;

/// <summary>
/// The quick-note text control: AvalonEdit with live Markdown styling (MarkdownStyler), • bullets, task checkboxes,
/// list continuation and plain-text paste. It is the only type that touches AvalonEdit, so the editor can be swapped.
/// </summary>
public sealed class MarkdownEditor : Grid, ITypingSurface, IDisposable
{
    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern uint GetCaretBlinkTime();

    private enum ReplacementKind { Hidden, Bullet, Checkbox, Quote }
    private readonly record struct Replacement(int Start, int Length, ReplacementKind Kind);

    internal TextEditor Inner { get; } = new();
    private readonly Dictionary<DocumentLine, LineModel> models = [];
    private readonly Dictionary<DocumentLine, Replacement[]> replacements = [];
    private readonly Dictionary<string, Brush> brushes = [];
    private readonly List<FenceState> fenceAfter = [];
    private readonly DispatcherTimer caretBlinkTimer = new(DispatcherPriority.Background);
    private readonly CaretOverlay caretOverlay;
    private int activeFirst = -1, activeLast = -1;
    private bool composing, disposed, caretVisible = true, showCaretForGallery;
    public event EventHandler? TextChanged;
    public IInputElement FocusTarget => Inner.TextArea;
    public string Text => Inner.Document.Text;
    public int TextLength => Inner.Document.TextLength;
    public int CaretOffset { get => Inner.CaretOffset; set => Inner.CaretOffset = value; }
    public int LineCount => Inner.Document.LineCount;
    public int LineStart(int lineNumber) => Inner.Document.GetLineByNumber(lineNumber).Offset;
    public bool HasSelection => Inner.SelectionLength > 0;
    /// <summary>The first <paramref name="length"/> characters, without copying a large note.</summary>
    public string Head(int length) => Inner.Document.GetText(0, Math.Min(length, Inner.Document.TextLength));
    /// <summary>True when the line reveals editable Markdown syntax; task markers always remain checkboxes.</summary>
    public bool IsSyntaxRevealed(int lineNumber) => lineNumber >= activeFirst && lineNumber <= activeLast;
    /// <summary>Task checkboxes currently rendered in the laid-out lines.</summary>
    public int RenderedCheckboxes => Inner.TextArea.TextView.VisualLinesValid
        ? Inner.TextArea.TextView.VisualLines.Sum(line => line.Elements.OfType<InlineObjectElement>().Count(element => element.Element is CheckboxVisual))
        : 0;
    /// <summary>Document characters hidden by the renderer (syntax on inactive lines) in the laid-out lines.</summary>
    public int HiddenCharacters => Inner.TextArea.TextView.VisualLinesValid
        ? Inner.TextArea.TextView.VisualLines.Sum(line => line.Elements.OfType<HiddenElement>().Sum(element => element.DocumentLength))
        : 0;

    public MarkdownEditor()
    {
        caretOverlay = new CaretOverlay(this) { IsHitTestVisible = false };
        Children.Add(Inner);
        Children.Add(caretOverlay);
        Inner.SetResourceReference(Control.FontFamilyProperty, "Font.UI");
        Inner.SetResourceReference(Control.ForegroundProperty, "TextPrimary");
        Inner.SetResourceReference(Control.BackgroundProperty, "Transparent");
        Inner.FontSize = Tokens.EditorFontSize;
        Inner.BorderThickness = new Thickness(Tokens.Zero);
        Inner.Padding = new Thickness(Tokens.Zero);
        Inner.WordWrap = true;
        Inner.ShowLineNumbers = false;
        Inner.ContextMenu = null;
        Inner.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        Inner.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        var options = Inner.Options;
        options.EnableHyperlinks = false; options.EnableEmailHyperlinks = false; options.CutCopyWholeLine = false;
        options.AllowScrollBelowDocument = false; options.HighlightCurrentLine = false; options.EnableRectangularSelection = false;
        options.ConvertTabsToSpaces = true; options.IndentationSize = 2;
        var area = Inner.TextArea;
        area.SetResourceReference(TextArea.SelectionBrushProperty, "SelectedFill");
        area.SetResourceReference(TextArea.SelectionForegroundProperty, "SelectedText");
        area.SelectionBorder = null;
        area.SelectionCornerRadius = Tokens.Zero;
        area.FocusVisualStyle = null;
        area.Caret.CaretBrush = Brushes.Transparent;
        var view = area.TextView;
        view.LineTransformers.Add(new MarkdownColorizer(this));
        view.ElementGenerators.Insert(0, new MarkdownGenerator(this));
        view.ElementGenerators.Insert(0, new LineSpacerGenerator(this));
        view.BackgroundRenderers.Add(new MarkdownBackground(this));
        Inner.Document.Changed += OnDocumentChanged;
        Inner.TextChanged += (_, e) => { TextChanged?.Invoke(this, e); ResetCaretBlink(); };
        area.Caret.PositionChanged += (_, _) => { UpdateActiveLines(); ResetCaretBlink(); };
        area.SelectionChanged += (_, _) => { UpdateActiveLines(); ResetCaretBlink(); };
        area.GotKeyboardFocus += (_, _) => ResetCaretBlink();
        area.LostKeyboardFocus += (_, _) => { composing = false; ResetCaretBlink(); };
        view.VisualLinesChanged += (_, _) => caretOverlay.InvalidateVisual();
        view.ScrollOffsetChanged += (_, _) => caretOverlay.InvalidateVisual();
        Inner.SizeChanged += (_, _) => caretOverlay.InvalidateVisual();
        caretBlinkTimer.Tick += (_, _) =>
        {
            if (!ShouldShowCaret) { caretBlinkTimer.Stop(); caretVisible = true; }
            else caretVisible = !caretVisible;
            caretOverlay.InvalidateVisual();
        };
        TextCompositionManager.AddPreviewTextInputStartHandler(area, (_, e) => { composing = e.TextComposition.CompositionText.Length > 0; ResetCaretBlink(); });
        TextCompositionManager.AddPreviewTextInputUpdateHandler(area, (_, e) => { composing = e.TextComposition.CompositionText.Length > 0; ResetCaretBlink(); });
        CommandManager.AddPreviewExecutedHandler(area, OnPreviewExecuted);
        Loaded += (_, _) => { if (disposed) return; area.Caret.CaretBrush = Brushes.Transparent; SystemEvents.UserPreferenceChanged += PreferenceChanged; ResetCaretBlink(); };
        Unloaded += (_, _) => { SystemEvents.UserPreferenceChanged -= PreferenceChanged; caretBlinkTimer.Stop(); };
        UpdateActiveLines();
    }

    // MARK: Text access

    /// <summary>Replace the whole text without leaving an undo step.</summary>
    public void SetText(string text)
    {
        Inner.Document.Text = text;
        Inner.Document.UndoStack.ClearAll();
        Inner.CaretOffset = Inner.Document.TextLength;
    }
    /// <summary>Replace a range as one undo step; the caret lands after the new text.</summary>
    public void Replace(int offset, int length, string text)
    {
        Inner.Document.Replace(offset, length, text);
        Inner.Select(offset + text.Length, 0);
    }
    public void Select(int start, int length) => Inner.Select(start, length);
    /// <summary>Body line height: the font's natural height times the Mac 1.25 multiple.</summary>
    public double LineHeight => Math.Ceiling(NaturalLineHeight * Tokens.EditorLineHeightMultiple);
    private double NaturalLineHeight => Family("Font.UI").LineSpacing * Tokens.EditorFontSize;
    /// <summary>Height above the baseline that brings a body line up to <see cref="LineHeight"/>.</summary>
    internal double SpacerRise => LineHeight - (Family("Font.UI").LineSpacing - Family("Font.UI").Baseline) * Tokens.EditorFontSize;
    public double VerticalOffset => Inner.VerticalOffset;
    public void ScrollToCaret() => Inner.TextArea.Caret.BringCaretToView();
    public void ScrollToVerticalOffset(double offset) => Inner.ScrollToVerticalOffset(offset);
    public bool Undo() { if (!Inner.CanUndo) return false; Inner.Undo(); return true; }
    public bool Redo() { if (!Inner.CanRedo) return false; Inner.Redo(); return true; }

    /// <summary>Lay the text out at <paramref name="width"/> and return the document height, capped to what is built.</summary>
    internal double MeasureDocument(double width, double maximumHeight)
    {
        Width = width; Height = double.NaN;
        Measure(new Size(width, maximumHeight));
        return Inner.TextArea.TextView.DocumentHeight;
    }
    /// <summary>The widest unwrapped paragraph (first N only) plus an allowance for list and quote indents.</summary>
    internal double NaturalTextWidth()
    {
        var doc = Inner.Document; var widest = Tokens.Zero;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var family = (FontFamily)(TryFindResource("Font.UI") ?? new FontFamily("Segoe UI"));
        var display = (FontFamily)(TryFindResource("Font.Display") ?? family);
        var count = Math.Min(doc.LineCount, Tokens.EditorMeasuredLines);
        for (var i = 1; i <= count; i++)
        {
            var line = doc.GetLineByNumber(i);
            if (line.Length == 0) continue;
            var text = doc.GetText(line);
            var size = Tokens.EditorFontSize; var face = family;
            var hashes = text.TakeWhile(c => c == '#').Count();
            if (hashes > 0 && hashes < text.Length && text[hashes] == ' ') { size = Tokens.EditorHeadingSizes[Math.Min(hashes, 4) - 1]; face = size > Tokens.EditorHeadingSizes[2] ? display : family; }
            var formatted = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                new Typeface(face, FontStyles.Normal, size == Tokens.EditorFontSize ? FontWeights.Normal : FontWeights.SemiBold, FontStretches.Normal), size, Brushes.Black, dpi);
            widest = Math.Max(widest, Math.Ceiling(formatted.WidthIncludingTrailingWhitespace));
        }
        return widest + Tokens.QuickIndentAllowance;
    }

    // MARK: Styling model

    internal Brush Resolve(string key)
    {
        if (!brushes.TryGetValue(key, out var brush))
        {
            brush = TryFindResource(key) as Brush ?? Brushes.Gray;
            brushes[key] = brush;
        }
        return brush;
    }
    private FontFamily Family(string key) => TryFindResource(key) as FontFamily ?? new FontFamily("Segoe UI");
    internal void Apply(VisualLineElementTextRunProperties properties, MarkdownStyle style)
    {
        if (style.Color is { } color) properties.SetForegroundBrush(Resolve(color));
        var typeface = properties.Typeface;
        var family = style.Mono ? Family("Font.Mono") : style.Display ? Family("Font.Display") : typeface.FontFamily;
        var weight = style.Bold ? FontWeights.SemiBold : style.Mono ? FontWeights.Normal : typeface.Weight;
        var fontStyle = style.Italic ? FontStyles.Italic : typeface.Style;
        if (style.Mono || style.Display || style.Bold || style.Italic) properties.SetTypeface(new Typeface(family, fontStyle, weight, typeface.Stretch));
        if (style.Mono) properties.SetFontRenderingEmSize(Tokens.EditorCodeFontSize);
        else if (style.Size is { } size) properties.SetFontRenderingEmSize(size);
        if (style.Strike) properties.SetTextDecorations(TextDecorations.Strikethrough);
    }
    internal LineModel ModelFor(DocumentLine line)
    {
        if (models.TryGetValue(line, out var model)) return model;
        if (models.Count > 512) { models.Clear(); replacements.Clear(); }
        model = MarkdownParser.Parse(Inner.Document.GetText(line), FenceBefore(line.LineNumber), out _);
        models[line] = model;
        return model;
    }
    private FenceState FenceBefore(int lineNumber)
    {
        if (lineNumber <= 1) return FenceState.Outside;
        var doc = Inner.Document;
        while (fenceAfter.Count < lineNumber - 1)
        {
            var previous = fenceAfter.Count == 0 ? FenceState.Outside : fenceAfter[^1];
            fenceAfter.Add(MarkdownParser.Advance(doc.GetText(doc.GetLineByNumber(fenceAfter.Count + 1)), previous, out _));
        }
        return fenceAfter[lineNumber - 2];
    }
    internal bool IsLineActive(DocumentLine line) => line.LineNumber >= activeFirst && line.LineNumber <= activeLast;
    private Replacement[] ReplacementsFor(DocumentLine line)
    {
        if (replacements.TryGetValue(line, out var cached)) return cached;
        var model = ModelFor(line); var list = new List<Replacement>();
        // Fence delimiters vanish off the caret line, like other syntax.
        if (model.Kind == LineKind.Fence && !IsLineActive(line) && line.Length > 0) list.Add(new Replacement(0, line.Length, ReplacementKind.Hidden));
        if (model.Kind == LineKind.Text)
        {
            var active = IsLineActive(line);
            // A task stays a checkbox while its text is edited, including on the caret and selection lines.
            if (model.TaskMarker is { } task) list.Add(new Replacement(task.Start, task.Length, ReplacementKind.Checkbox));
            if (!active)
            {
                if (model.QuoteMarker is { } quote) list.Add(new Replacement(quote.Start, quote.Length, ReplacementKind.Quote));
                list.AddRange(model.Syntax.Select(s => new Replacement(s.Start, s.Length, ReplacementKind.Hidden)));
            }
            if (model.BulletIndex is { } bullet && model.TaskMarker is null) list.Add(new Replacement(bullet, 2, ReplacementKind.Bullet)); // The marker and its space become one fixed-width cell.
        }
        var ordered = new List<Replacement>(); var end = 0;
        foreach (var item in list.Where(r => r.Length > 0).OrderBy(r => r.Start))
        {
            if (item.Start < end) continue;
            ordered.Add(item); end = item.Start + item.Length;
        }
        return replacements[line] = [.. ordered];
    }
    internal int NextReplacementOffset(DocumentLine line, int startOffset)
    {
        foreach (var item in ReplacementsFor(line)) if (line.Offset + item.Start >= startOffset) return line.Offset + item.Start;
        return -1;
    }
    internal VisualLineElement? ConstructReplacement(DocumentLine line, int offset)
    {
        foreach (var item in ReplacementsFor(line))
        {
            if (line.Offset + item.Start != offset) continue;
            return item.Kind switch
            {
                ReplacementKind.Hidden => new HiddenElement(item.Length),
                ReplacementKind.Bullet => new InlineObjectElement(item.Length, BulletCell()),
                ReplacementKind.Quote => new InlineObjectElement(item.Length, new Canvas { Width = Tokens.EditorQuoteIndent, Height = 1 }),
                _ => new InlineObjectElement(item.Length, new CheckboxVisual(this, line, item.Start + 3, ModelFor(line).TaskChecked))
            };
        }
        return null;
    }
    private TextBlock BulletCell()
    {
        var cell = new TextBlock { Text = Tokens.EditorBullet, FontSize = Tokens.EditorFontSize, FontWeight = FontWeights.SemiBold, FontFamily = Family("Font.UI"), Width = ListMarkerWidth };
        cell.Foreground = Resolve("Secondary");
        return cell;
    }
    internal const double ListMarkerWidth = Tokens.EditorCheckboxSize + 3;
    private void OnDocumentChanged(object? sender, DocumentChangeEventArgs e)
    {
        models.Clear(); replacements.Clear();
        var doc = Inner.Document;
        var first = doc.GetLineByOffset(Math.Min(e.Offset, doc.TextLength)).LineNumber - 1;
        if (fenceAfter.Count > first) fenceAfter.RemoveRange(first, fenceAfter.Count - first);
    }
    /// <summary>The caret and selection lines reveal syntax other than task markers; other lines render without it.</summary>
    private void UpdateActiveLines()
    {
        var area = Inner.TextArea; var doc = Inner.Document;
        var first = Math.Clamp(area.Caret.Line, 1, Math.Max(1, doc.LineCount)); var last = first;
        if (!area.Selection.IsEmpty)
        {
            first = Math.Min(first, Math.Clamp(area.Selection.StartPosition.Line, 1, doc.LineCount));
            last = Math.Max(last, Math.Clamp(area.Selection.EndPosition.Line, 1, doc.LineCount));
        }
        if (first == activeFirst && last == activeLast) return;
        var from = activeFirst < 0 ? first : Math.Min(first, activeFirst); var to = activeLast < 0 ? last : Math.Max(last, activeLast);
        activeFirst = first; activeLast = last; replacements.Clear();
        from = Math.Clamp(from, 1, doc.LineCount); to = Math.Clamp(to, 1, doc.LineCount);
        var start = doc.GetLineByNumber(from).Offset;
        area.TextView.Redraw(start, doc.GetLineByNumber(to).EndOffset - start);
    }
    /// <summary>Brushes are cached per theme; redraw after a palette change.</summary>
    public void RefreshTheme()
    {
        if (disposed) return;
        brushes.Clear(); replacements.Clear();
        Inner.TextArea.Caret.CaretBrush = Brushes.Transparent;
        ResetCaretBlink();
        caretOverlay.InvalidateVisual();
        Inner.TextArea.TextView.Redraw();
    }
    private void PreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => Dispatcher.BeginInvoke(RefreshTheme, System.Windows.Threading.DispatcherPriority.ApplicationIdle);

    /// <summary>Gallery-only switch that snapshots the focused caret without creating an HWND.</summary>
    internal bool ShowCaretForGallery
    {
        get => showCaretForGallery;
        set { showCaretForGallery = value; ResetCaretBlink(); }
    }
    internal Rect? CaretBoundsForGallery => CalculateCaretBounds();
    internal IReadOnlyList<Rect> CheckboxExpectedBoundsForGallery
    {
        get
        {
            var textView = Inner.TextArea.TextView;
            if (!textView.VisualLinesValid) textView.EnsureVisualLines();
            var bounds = new List<Rect>();
            foreach (var visualLine in textView.VisualLines)
            foreach (var inline in visualLine.Elements.OfType<InlineObjectElement>())
            {
                if (inline.Element is not CheckboxVisual checkbox) continue;
                var line = visualLine.FirstDocumentLine;
                var visualColumn = visualLine.GetVisualColumn(line.Offset - visualLine.FirstDocumentLine.Offset);
                var baseline = visualLine.GetVisualPosition(visualColumn, VisualYPosition.Baseline).Y - textView.VerticalOffset;
                var elementOrigin = checkbox.TranslatePoint(new Point(Tokens.Zero, Tokens.Zero), textView);
                var centerY = baseline - EditorCapHeight / 2;
                var center = textView.TranslatePoint(new Point(elementOrigin.X, centerY), this);
                bounds.Add(new Rect(center.X, center.Y - Tokens.EditorCheckboxSize / 2.0,
                    Tokens.EditorCheckboxSize, Tokens.EditorCheckboxSize));
            }
            return bounds;
        }
    }

    private bool ShouldShowCaret => showCaretForGallery || Inner.TextArea.IsKeyboardFocusWithin && (Inner.SelectionLength == 0 || composing);
    private void ResetCaretBlink()
    {
        caretBlinkTimer.Stop(); caretVisible = true;
        if (disposed) { caretOverlay.InvalidateVisual(); return; }
        if (ShouldShowCaret && !showCaretForGallery && GetSystemCaretBlinkInterval() is { } interval)
        {
            caretBlinkTimer.Interval = interval;
            caretBlinkTimer.Start();
        }
        caretOverlay.InvalidateVisual();
    }
    private static TimeSpan? GetSystemCaretBlinkInterval()
    {
        var milliseconds = GetCaretBlinkTime();
        return milliseconds is 0 or uint.MaxValue ? null : TimeSpan.FromMilliseconds(milliseconds);
    }
    private void DrawCaret(DrawingContext drawingContext)
    {
        if (!caretVisible || !ShouldShowCaret || CalculateCaretBounds() is not { } rect) return;
        drawingContext.DrawRoundedRectangle(Resolve("BrandAccent"), null, rect, Tokens.EditorCaretRadius, Tokens.EditorCaretRadius);
    }
    private Rect? CalculateCaretBounds()
    {
        var textView = Inner.TextArea.TextView;
        try
        {
            if (!textView.VisualLinesValid) textView.EnsureVisualLines();
            var caret = Inner.TextArea.Caret;
            var systemRect = caret.CalculateCaretRectangle();
            var baseline = textView.GetVisualPosition(caret.Position, VisualYPosition.Baseline).Y;
            var viewOrigin = textView.TranslatePoint(new Point(Tokens.Zero, Tokens.Zero), this);
            if (!double.IsFinite(systemRect.X) || !double.IsFinite(baseline) || !double.IsFinite(viewOrigin.X) || !double.IsFinite(viewOrigin.Y)) return null;
            var size = CaretFontSizeAtPosition();
            var height = size * Tokens.EditorCaretHeightFactor;
            var bottom = viewOrigin.Y + baseline - textView.VerticalOffset + size * Tokens.EditorCaretDescentFactor;
            return new Rect(viewOrigin.X + systemRect.X - textView.HorizontalOffset, bottom - height,
                Tokens.EditorCaretWidth, height);
        }
        catch (InvalidOperationException) { return null; }
    }
    private double CaretFontSizeAtPosition()
    {
        var doc = Inner.Document;
        var offset = Math.Clamp(Inner.CaretOffset, 0, doc.TextLength);
        var line = doc.GetLineByOffset(offset);
        var model = ModelFor(line);
        if (model.Kind is LineKind.Code or LineKind.Fence) return Tokens.EditorCodeFontSize;
        if (line.Length == 0) return FenceBefore(line.LineNumber).IsOpen ? Tokens.EditorCodeFontSize : Tokens.EditorFontSize;
        var index = Math.Clamp(offset - line.Offset, 0, line.Length - 1);
        var size = Tokens.EditorFontSize;
        foreach (var style in model.Styles.Where(style => index >= style.Start && index < style.End))
        {
            if (style.Mono) size = Tokens.EditorCodeFontSize;
            else if (style.Size is { } styledSize) size = styledSize;
        }
        return size;
    }
    private double? CheckboxTop(FrameworkElement element, DocumentLine line)
    {
        var textView = Inner.TextArea.TextView;
        try
        {
            if (!textView.VisualLinesValid) textView.EnsureVisualLines();
            var visualLine = textView.VisualLines.FirstOrDefault(candidate => candidate.FirstDocumentLine == line);
            if (visualLine is null) return null;
            var visualColumn = visualLine.GetVisualColumn(line.Offset - visualLine.FirstDocumentLine.Offset);
            var baseline = visualLine.GetVisualPosition(visualColumn, VisualYPosition.Baseline).Y - textView.VerticalOffset;
            var elementOrigin = element.TranslatePoint(new Point(Tokens.Zero, Tokens.Zero), textView);
            return baseline - EditorCapHeight / 2 - Tokens.EditorCheckboxSize / 2.0 - elementOrigin.Y;
        }
        catch (InvalidOperationException) { return null; }
    }
    private double EditorCapHeight
    {
        get
        {
            var family = Family("Font.UI");
            foreach (var typeface in family.GetTypefaces())
                if (typeface.TryGetGlyphTypeface(out var glyphTypeface) && glyphTypeface.CapsHeight > 0)
                    return glyphTypeface.CapsHeight * Tokens.EditorFontSize;
            return Tokens.EditorFontSize * 0.7;
        }
    }
    internal void ToggleTask(DocumentLine line, int index)
    {
        var doc = Inner.Document; var offset = line.Offset + index;
        if (line.IsDeleted || offset >= doc.TextLength) return;
        var replacement = doc.GetCharAt(offset) == ' ' ? "x" : " ";
        doc.UndoStack.StartUndoGroup(); // One undo step per toggle.
        try { doc.Replace(offset, 1, replacement); } finally { doc.UndoStack.EndUndoGroup(); }
    }

    // MARK: Keys

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        // A composing IME owns Return and the arrows (WPF reports those as ImeProcessed).
        if (e.Handled || e.Key == Key.ImeProcessed || composing) return;
        var modifiers = Keyboard.Modifiers; var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (modifiers == (ModifierKeys.Control | ModifierKeys.Shift) && key == Key.Z) { Redo(); e.Handled = true; return; }
        if (modifiers is not (ModifierKeys.None or ModifierKeys.Shift)) return;
        var shift = modifiers == ModifierKeys.Shift;
        switch (key)
        {
            case Key.Enter:
                if (shift) Insert("\n"); else InsertLineBreak();
                e.Handled = true; break;
            case Key.Tab: IndentList(shift); e.Handled = true; break;
            case Key.Back when !shift && TaskMarkerBackspace(): e.Handled = true; break;
        }
    }
    protected override void OnPreviewTextInput(TextCompositionEventArgs e)
    {
        base.OnPreviewTextInput(e);
        var wasComposing = composing; composing = false;
        if (wasComposing || e.Handled || e.Text != " " || Inner.SelectionLength > 0) return;
        // "- []" + space becomes "- [ ] " in one undo step.
        var doc = Inner.Document; var caret = Inner.CaretOffset; var line = doc.GetLineByOffset(caret);
        if (!MarkdownParser.TaskAutocorrect().IsMatch(doc.GetText(line.Offset, caret - line.Offset)) || FenceBefore(line.LineNumber).IsOpen) return;
        doc.UndoStack.StartUndoGroup();
        try { Replace(caret - 2, 2, "[ ] "); } finally { doc.UndoStack.EndUndoGroup(); }
        e.Handled = true;
    }
    private void OnPreviewExecuted(object sender, ExecutedRoutedEventArgs e)
    {
        if (e.Command != ApplicationCommands.Paste) return;
        e.Handled = true; PastePlainText();
    }
    private void PastePlainText()
    {
        string? text = null;
        try { if (Clipboard.ContainsText(TextDataFormat.UnicodeText)) text = Clipboard.GetText(TextDataFormat.UnicodeText); }
        catch (COMException) { } // The clipboard can be locked by another process.
        if (string.IsNullOrEmpty(text)) return;
        Insert(text.ReplaceLineEndings("\n"));
    }
    /// <summary>Insert text over the selection as one undo step.</summary>
    private void Insert(string text) => Replace(Inner.SelectionStart, Inner.SelectionLength, text);

    private bool TaskMarkerBackspace()
    {
        if (Inner.SelectionLength > 0) return false;
        var doc = Inner.Document; var caret = Inner.CaretOffset; var line = doc.GetLineByOffset(caret);
        if (MarkdownParser.TaskMarkerLine().Match(doc.GetText(line)) is not { Success: true } match || caret != line.Offset + match.Length) return false;
        // Delete "[ ] " and keep the list bullet.
        var start = line.Offset + match.Groups[1].Length + match.Groups[2].Length;
        Replace(start, 4, "");
        return true;
    }
    private void InsertLineBreak()
    {
        var doc = Inner.Document; var line = doc.GetLineByOffset(Inner.SelectionStart);
        if (FenceBefore(line.LineNumber).IsOpen) { Insert("\n"); return; }
        if (MarkdownParser.ListLine().Match(doc.GetText(line)) is not { Success: true } match) { Insert("\n"); return; }
        var indent = match.Groups[1].Value; var marker = match.Groups[2].Value; var rest = match.Groups[4];
        if (rest.Value.Trim(' ', '\t').Length == 0) { Replace(line.Offset, rest.Index, ""); return; } // An empty item exits the list.
        string next;
        if (match.Groups[3].Success && int.TryParse(match.Groups[3].Value, out var number) && number < int.MaxValue) next = (number + 1).ToString(CultureInfo.InvariantCulture) + ". ";
        else if (marker.Contains('[')) next = marker[..2] + "[ ] ";
        else next = marker;
        Insert("\n" + indent + next);
    }
    private void IndentList(bool outdent)
    {
        var doc = Inner.Document; var selection = Inner.SelectionStart; var length = Inner.SelectionLength;
        var first = doc.GetLineByOffset(selection);
        var last = doc.GetLineByOffset(length > 0 ? selection + length - 1 : selection); // Exclude a line the selection only touches.
        var changed = false; doc.UndoStack.StartUndoGroup();
        try
        {
            for (var line = last; ; line = line.PreviousLine!)
            {
                var text = doc.GetText(line);
                if (MarkdownParser.ListLine().IsMatch(text))
                {
                    if (outdent)
                    {
                        var spaces = Math.Min(2, text.TakeWhile(c => c == ' ').Count());
                        if (spaces > 0) { doc.Remove(line.Offset, spaces); changed = true; }
                    }
                    else { doc.Insert(line.Offset, "  "); changed = true; }
                }
                if (line == first) break;
            }
        }
        finally { doc.UndoStack.EndUndoGroup(); }
        if (changed && length > 0) Inner.Select(first.Offset, last.EndOffset - first.Offset);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        caretBlinkTimer.Stop();
        SystemEvents.UserPreferenceChanged -= PreferenceChanged;
    }

    // MARK: Rendering helpers

    private sealed class CaretOverlay(MarkdownEditor owner) : FrameworkElement
    {
        protected override void OnRender(DrawingContext drawingContext) => owner.DrawCaret(drawingContext);
    }

    /// <summary>Syntax on an inactive line: an empty run that still owns the document characters.</summary>
    private sealed class HiddenElement(int length) : FormattedTextElement("", length);
    /// <summary>
    /// Emulates the 1.25 line height: a zero-width inline object at each line start whose rise lifts the line to the body height.
    /// </summary>
    private sealed class LineSpacerGenerator(MarkdownEditor owner) : VisualLineElementGenerator
    {
        private bool produced;
        public override void StartGeneration(ITextRunConstructionContext context) { base.StartGeneration(context); produced = false; }
        public override int GetFirstInterestedOffset(int startOffset)
        {
            if (produced) return -1;
            var line = CurrentContext.VisualLine.FirstDocumentLine;
            if (owner.ModelFor(line).Kind == LineKind.Fence && !owner.IsLineActive(line)) return -1; // Collapsed delimiter.
            return startOffset <= line.Offset ? line.Offset : -1;
        }
        public override VisualLineElement? ConstructElement(int offset)
        {
            produced = true;
            return new InlineObjectElement(0, new Canvas { Width = 0, Height = owner.SpacerRise });
        }
    }
    private sealed class MarkdownColorizer(MarkdownEditor owner) : DocumentColorizingTransformer
    {
        protected override void ColorizeLine(DocumentLine line)
        {
            var model = owner.ModelFor(line);
            foreach (var style in model.Styles)
            {
                var end = Math.Min(style.End, line.Length);
                if (end <= style.Start) continue;
                ChangeLinePart(line.Offset + style.Start, line.Offset + end, element => owner.Apply(element.TextRunProperties, style));
            }
            // A collapsed fence delimiter keeps only a sliver of height.
            if (model.Kind == LineKind.Fence && !owner.IsLineActive(line) && line.Length > 0)
                ChangeLinePart(line.Offset, line.EndOffset, element => element.TextRunProperties.SetFontRenderingEmSize(4));
        }
    }
    private sealed class MarkdownGenerator(MarkdownEditor owner) : VisualLineElementGenerator
    {
        public override int GetFirstInterestedOffset(int startOffset) =>
            owner.NextReplacementOffset(CurrentContext.Document.GetLineByOffset(startOffset), startOffset);
        public override VisualLineElement? ConstructElement(int offset) =>
            owner.ConstructReplacement(CurrentContext.Document.GetLineByOffset(offset), offset);
    }
    private sealed class MarkdownBackground(MarkdownEditor owner) : IBackgroundRenderer
    {
        public KnownLayer Layer => KnownLayer.Background;
        public void Draw(TextView textView, DrawingContext drawingContext)
        {
            if (!textView.VisualLinesValid) return;
            var scroll = textView.VerticalOffset; Rect? block = null;
            void Flush()
            {
                if (block is { } rect) drawingContext.DrawRoundedRectangle(owner.Resolve("CodeBackground"), null, Rect.Inflate(rect, Tokens.Zero, 2), Tokens.CodeBlockRadius, Tokens.CodeBlockRadius);
                block = null;
            }
            foreach (var visual in textView.VisualLines)
            {
                var line = visual.FirstDocumentLine; var model = owner.ModelFor(line);
                var area = new Rect(Tokens.Zero, visual.VisualTop - scroll, textView.ActualWidth, visual.Height);
                if (model.Kind == LineKind.Fence && !owner.IsLineActive(line)) { Flush(); continue; }
                if (model.Kind != LineKind.Text) { block = block is { } open ? Rect.Union(open, area) : area; continue; }
                Flush();
                if (model.IsQuote)
                    drawingContext.DrawRoundedRectangle(owner.Resolve("Tertiary"), null, new Rect(Tokens.EditorQuoteBarInset, area.Y, Tokens.EditorQuoteBarWidth, area.Height), Tokens.EditorQuoteBarWidth / 2.0, Tokens.EditorQuoteBarWidth / 2.0);
                foreach (var code in model.InlineCode)
                    foreach (var rect in BackgroundGeometryBuilder.GetRectsForSegment(textView, new TextSegment { StartOffset = line.Offset + code.Start, Length = code.Length }))
                        drawingContext.DrawRoundedRectangle(owner.Resolve("CodeBackground"), null,
                            new Rect(rect.X - Tokens.InlineCodePadding, rect.Y, rect.Width + Tokens.InlineCodePadding * 2, rect.Height), Tokens.InlineCodeRadius, Tokens.InlineCodeRadius);
            }
            Flush();
        }
    }
    /// <summary>The accent checkbox that replaces a task marker, including while editing; a click toggles the task.</summary>
    private sealed class CheckboxVisual : FrameworkElement
    {
        private readonly MarkdownEditor owner; private readonly DocumentLine line; private readonly int index; private readonly bool isChecked;
        public CheckboxVisual(MarkdownEditor owner, DocumentLine line, int index, bool isChecked)
        {
            this.owner = owner; this.line = line; this.index = index; this.isChecked = isChecked;
            Width = ListMarkerWidth; Height = Tokens.EditorCheckboxSize + 2;
            Cursor = Cursors.Hand;
        }
        protected override void OnRender(DrawingContext drawingContext)
        {
            if (owner.CheckboxTop(this, line) is not { } top) return;
            var box = new Rect(Tokens.Zero, top, Tokens.EditorCheckboxSize, Tokens.EditorCheckboxSize);
            drawingContext.DrawRectangle(Brushes.Transparent, null, new Rect(Tokens.Zero, top, ListMarkerWidth, Tokens.EditorCheckboxSize));
            if (isChecked)
            {
                drawingContext.DrawRoundedRectangle(owner.Resolve("BrandAccent"), null, box, Tokens.EditorCheckboxRadius, Tokens.EditorCheckboxRadius);
                var points = Tokens.EditorCheckboxCheckPoints.Select(p => new Point(box.X + p.X * box.Width, box.Y + p.Y * box.Height)).ToArray();
                var figure = new PathFigure(points[0], [new PolyLineSegment(points[1..], true)], false);
                var pen = new Pen(owner.Resolve("EditorCheckboxCheck"), Tokens.EditorCheckboxStroke) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
                drawingContext.DrawGeometry(null, pen, new PathGeometry([figure]));
            }
            else
            {
                var half = Tokens.EditorCheckboxStroke / 2;
                drawingContext.DrawRoundedRectangle(null, new Pen(owner.Resolve("BrandAccent"), Tokens.EditorCheckboxStroke), Rect.Inflate(box, -half, -half),
                    Tokens.EditorCheckboxRadius - half, Tokens.EditorCheckboxRadius - half);
            }
        }
        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            e.Handled = true; owner.ToggleTask(line, index);
        }
    }
}
