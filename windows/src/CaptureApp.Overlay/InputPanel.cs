using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;

namespace CaptureApp.Overlay;

public sealed class InputPanelView : OverlaySurface
{
    public TextBox Field { get; } = new();
    private readonly Grid fieldHost;
    private readonly string? title, secondary;
    private readonly ScrollViewer scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    public event Action<int>? Selected;
    public InputPanelView(string placeholder, string text = "", IReadOnlyList<Suggestion>? suggestions = null, int? selection = null, string? title = null, string? secondary = null)
        : base(Tokens.InputWidth, Tokens.Padding * 2 + Tokens.InputFieldHeight)
    {
        this.title = title; this.secondary = secondary;
        fieldHost = Ui.Field(Field, placeholder); Field.Text = text;
        AutomationProperties.SetName(Field, title ?? placeholder);
        if (secondary is not null) AutomationProperties.SetHelpText(Field, secondary);
        Update(suggestions ?? [], selection);
    }
    public void Update(IReadOnlyList<Suggestion> suggestions, int? selection)
    {
        Body.Children.Clear();
        var contextHeight = (title is null ? Tokens.Zero : Tokens.HeaderHeight) + (secondary is null ? Tokens.Zero : Tokens.MetaLineHeight + Tokens.Padding / 2);
        Height = Tokens.Padding * 2 + contextHeight + Tokens.InputFieldHeight + (suggestions.Count == 0 ? Tokens.Zero : Tokens.BorderWidth + Math.Min(suggestions.Count, Tokens.MaxSuggestions) * Tokens.SuggestionHeight);
        var width = Width - Tokens.Padding * 2;
        if (title is not null) Ui.Place(Body, Ui.Text(title, "Title"), Tokens.Padding, Tokens.Padding, width, Tokens.TitleLineHeight);
        if (secondary is not null) Ui.Place(Body, Ui.Text(secondary, "Meta", "Secondary"), Tokens.Padding, Tokens.Padding + (title is null ? Tokens.Zero : Tokens.HeaderHeight), width, Tokens.MetaLineHeight);
        Ui.Place(Body, fieldHost, Tokens.Padding, Tokens.Padding + contextHeight, width, Tokens.InputFieldHeight);
        if (suggestions.Count == 0) return;
        var y = Tokens.Padding + contextHeight + Tokens.InputFieldHeight;
        Ui.Place(Body, Ui.Separator(), Tokens.Padding, y, width, Tokens.BorderWidth);
        var document = new StackPanel(); ChoiceRowView? selectedRow = null;
        for (var i = 0; i < suggestions.Count; i++)
        {
            var index = i; var row = new ChoiceRowView(suggestions[i], selection == i) { Height = Tokens.SuggestionHeight };
            row.Click += (_, _) => Selected?.Invoke(index); document.Children.Add(row);
            if (selection == i) selectedRow = row;
        }
        scroll.Content = document;
        Ui.Place(Body, scroll, Tokens.Padding, y + Tokens.BorderWidth, width, Math.Min(suggestions.Count, Tokens.MaxSuggestions) * Tokens.SuggestionHeight);
        if (selectedRow is not null) { scroll.UpdateLayout(); selectedRow.BringIntoView(); }
    }
}
public class InputPanelController
{
    private OverlayWindow? panel;
    private InputPanelView? view;
    private InputRequest? request;
    private IReadOnlyList<Suggestion> suggestions = [];
    private int? selection;
    private string? submitted;
    public bool IsVisible => panel?.IsVisible == true;
    public void Present(InputRequest request, bool typingNeeded = true)
    {
        panel?.Dismiss(DismissReason.Replaced, false);
        this.request = request; submitted = null; selection = null;
        suggestions = request.Suggestions(request.InitialText);
        var content = new InputPanelView(request.Placeholder, request.InitialText, suggestions, null, request.Title, request.Secondary); view = content;
        var window = new OverlayWindow(content); panel = window;
        content.Field.TextChanged += (_, _) => { if (view != content) return; selection = null; suggestions = request.Suggestions(content.Field.Text); Refresh(); };
        content.Selected += index => { selection = index; Refresh(); };
        window.PreviewKeyDown += HandleKey;
        window.Closed += (_, _) =>
        {
            if (panel != window) return;
            var result = submitted; var handlers = this.request;
            panel = null; view = null; this.request = null; suggestions = []; selection = null; submitted = null;
            if (result is not null) handlers?.OnSubmit(result); else handlers?.OnCancel();
        };
        window.Present(typingNeeded, content.Field);
    }
    private void Refresh()
    {
        if (view is null) return;
        view.Update(suggestions, selection); panel?.ResizeVisible(view.SurfaceSize);
    }
    private void HandleKey(object sender, KeyEventArgs e)
    {
        if (view is null || request is null || e.Key == Key.ImeProcessed || e.IsRepeat && e.Key == Key.Enter) return;
        switch (e.Key)
        {
            case Key.Down: case Key.Up:
                if (suggestions.Count > 0) selection = Math.Clamp(selection is { } current ? current + (e.Key == Key.Down ? 1 : -1) : e.Key == Key.Down ? 0 : suggestions.Count - 1, 0, suggestions.Count - 1);
                Refresh(); e.Handled = true; break;
            case Key.Tab:
                if (suggestions.Count > 0) { view.Field.Text = suggestions[selection ?? 0].Title; view.Field.CaretIndex = view.Field.Text.Length; }
                e.Handled = true; break;
            case Key.Enter:
                e.Handled = true;
                if (request.SelectionOnly && selection is null) return;
                var value = selection is { } index ? suggestions[index].Value ?? suggestions[index].Title : view.Field.Text.Trim();
                submitted = string.IsNullOrWhiteSpace(value) ? null : value;
                if (submitted is not null) request.OnAccept?.Invoke(submitted);
                panel?.Dismiss(); break;
        }
    }
    public void Dismiss(DismissReason reason = DismissReason.Explicit) => panel?.Dismiss(reason);
}
public sealed class SessionPickerController : InputPanelController
{
    public void Present(IReadOnlyList<Suggestion> choices, Action<string> onSubmit, Action onCancel, bool typingNeeded = true) =>
        Present(new InputRequest("Select a session…", prefix => choices.Where(s => s.Title.Normalize().StartsWith(prefix.Trim().Normalize(), StringComparison.OrdinalIgnoreCase)).ToArray(), onSubmit, onCancel,
            Title: "Multiple sessions found with the given name", SelectionOnly: true), typingNeeded);
}
