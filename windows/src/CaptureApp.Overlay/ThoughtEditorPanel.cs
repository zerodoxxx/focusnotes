using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace CaptureApp.Overlay;

internal sealed class ThoughtEditorView : OverlaySurface
{
    private const double ContentWidth = 440, ImageMaxHeight = 120, EditorHeight = 118;
    private readonly TextBlock title, detail, excerpt, error;
    private readonly TextBlock thoughtLabel = Ui.Text("My thought", "Title");
    private readonly Image image = new() { Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly KeycapView saveHint = new("Ctrl+S", "Save"), closeHint = new("Esc", "Close");
    private double excerptHeight;
    internal TextBox Editor { get; } = new()
    {
        AcceptsReturn = true, AcceptsTab = true, TextWrapping = TextWrapping.Wrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Padding = new Thickness(6), BorderThickness = new Thickness(Tokens.BorderWidth),
        VerticalContentAlignment = VerticalAlignment.Top, FontSize = Tokens.EditorFontSize
    };
    internal ThoughtEditorView(ThoughtEditorContent content, ImageSource? previewImage = null, string? errorMessage = null)
        : base(ContentWidth + Tokens.QuickTextInset * 2, 1)
    {
        title = Ui.Text(content.SourceTitle, "Title", accessible: true);
        title.Tag = QuickNoteView.TrimmedTag;
        detail = Ui.Text(content.SourceDetail ?? "", "Meta", "Secondary");
        detail.Tag = QuickNoteView.TrimmedTag;
        detail.Visibility = content.SourceDetail is null ? Visibility.Collapsed : Visibility.Visible;
        excerpt = Ui.Text(content.ExcerptText ?? "", "Snippet", accessible: true);
        excerpt.Tag = QuickNoteView.TrimmedTag;
        excerpt.TextWrapping = TextWrapping.Wrap;
        excerpt.TextTrimming = TextTrimming.CharacterEllipsis;
        excerpt.VerticalAlignment = VerticalAlignment.Top;
        error = Ui.Text(errorMessage ?? "", "Meta", "Warning", accessible: true);
        error.TextWrapping = TextWrapping.Wrap;
        error.Visibility = errorMessage is null ? Visibility.Collapsed : Visibility.Visible;
        Editor.SetResourceReference(Control.FontFamilyProperty, "Font.UI");
        Editor.SetResourceReference(Control.ForegroundProperty, "TextPrimary");
        Editor.SetResourceReference(Control.BackgroundProperty, "Transparent");
        Editor.SetResourceReference(Control.BorderBrushProperty, "SurfaceBorder");
        Editor.SetResourceReference(TextBox.CaretBrushProperty, "BrandAccent");
        Editor.SetResourceReference(TextBox.SelectionBrushProperty, "SelectedFill");
        AutomationProperties.SetName(Editor, "My thought");
        Editor.Text = content.Text;
        Editor.CaretIndex = Editor.Text.Length;
        if (content.ExcerptText is not null)
        {
            excerpt.Measure(new Size(ContentWidth, double.PositiveInfinity));
            excerptHeight = Math.Min(Tokens.SnippetLineHeight * 6, excerpt.DesiredSize.Height);
            image.Visibility = Visibility.Collapsed;
        }
        else
        {
            excerpt.Visibility = Visibility.Collapsed;
            excerptHeight = content.ExcerptImage is null ? 0 : ImageMaxHeight;
            if (previewImage is not null) SetImage(previewImage);
        }
        Layout();
    }
    internal void SetImage(ImageSource? value)
    {
        image.Source = value;
        image.Visibility = value is null ? Visibility.Collapsed : Visibility.Visible;
        excerptHeight = value is null ? 0 : value.Width > 0 ? Math.Min(ImageMaxHeight, Math.Ceiling(ContentWidth * value.Height / value.Width)) : ImageMaxHeight;
        Layout();
    }
    internal void SaveFailed(string message)
    {
        error.Text = message; error.Visibility = Visibility.Visible;
    }
    private void Layout()
    {
        Body.Children.Clear();
        const double inset = Tokens.QuickTextInset;
        Ui.Place(Body, title, inset, 16, ContentWidth, 22);
        var y = 40.0;
        if (detail.Visibility == Visibility.Visible) { Ui.Place(Body, detail, inset, y, ContentWidth, 18); y += 24; }
        if (excerpt.Visibility == Visibility.Visible) Ui.Place(Body, excerpt, inset, y, ContentWidth, excerptHeight);
        else if (image.Visibility == Visibility.Visible) Ui.Place(Body, image, inset, y, ContentWidth, excerptHeight);
        y += excerptHeight + 14;
        Ui.Place(Body, thoughtLabel, inset, y, ContentWidth, 22); y += 26;
        Ui.Place(Body, Editor, inset, y, ContentWidth, EditorHeight); y += EditorHeight + 10;
        Ui.Place(Body, error, inset, y, ContentWidth, 32); y += 38;
        var closeWidth = Ui.NaturalWidth(closeHint); var saveWidth = Ui.NaturalWidth(saveHint);
        Ui.Place(Body, closeHint, Width - inset - closeWidth, y, closeWidth, Tokens.HintHeight);
        Ui.Place(Body, saveHint, Width - inset - closeWidth - Tokens.FooterHintGap - saveWidth, y, saveWidth, Tokens.HintHeight);
        Height = y + Tokens.HintHeight + 12;
    }
}

/// <summary>UI-thread owner of the capture thought editor.</summary>
public sealed class ThoughtEditorPanel
{
    private OverlayWindow? panel;
    private ThoughtEditorView? view;
    private Action<string>? close;
    private bool saving;
    private int generation;
    public Guid? CaptureId { get; private set; }
    public bool IsVisible => panel?.IsVisible == true;
    public string? CurrentText => view?.Editor.Text;
    public int InstanceId => generation;
    internal ThoughtEditorView? ViewForChecks => view;

    public void Present(Guid captureId, ThoughtEditorContent content, Action<string> onSave, Action<string> onClose)
    {
        Finish(true);
        var token = ++generation;
        var editor = new ThoughtEditorView(content);
        var window = new OverlayWindow(editor);
        panel = window; view = editor; close = onClose; CaptureId = captureId; saving = false;
        window.Dismissed += _ => { if (generation == token) Finish(true, alreadyDismissed: true); };
        window.Closed += (_, _) => { if (generation == token) Finish(true, alreadyDismissed: true); };
        window.PreviewKeyDown += (_, e) =>
        {
            if (generation != token) return;
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (!Keyboard.Modifiers.HasFlag(ModifierKeys.Control) || (key != Key.S && key != Key.Enter)) return;
            e.Handled = true;
            if (saving || e.IsRepeat) return;
            saving = true;
            onSave(editor.Editor.Text);
        };
        window.Present(true, editor.Editor);
        editor.Editor.CaretIndex = editor.Editor.Text.Length;
        editor.Editor.ScrollToEnd();
        if (content.ExcerptImage is { } load && content.ExcerptText is null) _ = LoadImage(load, token, editor, window);
    }
    private async Task LoadImage(Func<Task<ImageSource?>> load, int token, ThoughtEditorView editor, OverlayWindow window)
    {
        ImageSource? result;
        try { result = await load(); }
        catch (Exception) { result = null; } // An unavailable excerpt must not prevent writing.
        if (generation != token) return;
        editor.SetImage(result);
        window.ResizeVisible(editor.SurfaceSize);
    }
    private void Finish(bool notifyClose, bool alreadyDismissed = false)
    {
        generation++;
        var previous = panel; var text = view?.Editor.Text; var callback = close;
        panel = null; view = null; close = null; CaptureId = null; saving = false;
        if (!alreadyDismissed) previous?.Dismiss(animated: false);
        if (notifyClose && text is not null) callback?.Invoke(text);
    }
    // Text typed while the save was pending keeps the editor open and saveable.
    public void SaveSucceeded(string savedText) { if (CurrentText == savedText) Finish(false); else saving = false; }
    public void SaveFailed(string message) { saving = false; view?.SaveFailed(message); }
    public void Dismiss() => Finish(false);

    internal static OverlaySurface Preview(ThoughtEditorContent content, ImageSource? image = null, string? error = null)
        => new ThoughtEditorView(content, image, error);
}
