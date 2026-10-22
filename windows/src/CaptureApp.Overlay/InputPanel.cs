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
public enum InputSubmitAction { Ignore, Submit, Alternate }

public class InputPanelController
{
    public static InputSubmitAction SubmissionAction(ModifierKeys modifiers, bool hasAlternate) => modifiers switch
    {
        ModifierKeys.None => InputSubmitAction.Submit,
        ModifierKeys.Control when hasAlternate => InputSubmitAction.Alternate,
        _ when !hasAlternate => InputSubmitAction.Submit,
        _ => InputSubmitAction.Ignore
    };
    private OverlayWindow? panel;
    private InputPanelView? view;
    private InputRequest? request;
    private IReadOnlyList<Suggestion> suggestions = [];
    private int? selection;
    private abstract record Outcome
    {
        public sealed record Submit(string Value) : Outcome;
        public sealed record Alternate(string Value) : Outcome;
        public sealed record Escape : Outcome;
        public sealed record Cancel : Outcome;
    }
    private Outcome outcome = new Outcome.Cancel();
    public bool IsVisible => panel?.IsVisible == true;
    internal string? SelectedValueForChecks => selection is { } i ? suggestions[i].Value ?? suggestions[i].Title : null;
    internal InputPanelView? ViewForChecks => view;
    public void Present(InputRequest request, bool typingNeeded = true)
    {
        panel?.Dismiss(DismissReason.Replaced, false);
        this.request = request; outcome = new Outcome.Cancel(); selection = null;
        suggestions = request.Suggestions(request.InitialText);
        if (request.SelectedValue is { } selected)
        {
            var index = suggestions.ToList().FindIndex(s => (s.Value ?? s.Title) == selected);
            if (index >= 0) selection = index;
        }
        var content = new InputPanelView(request.Placeholder, request.InitialText, suggestions, selection, request.Title, request.Secondary); view = content;
        var window = new OverlayWindow(content); panel = window;
        window.CancelHandler = () => { outcome = new Outcome.Escape(); return false; };
        content.Field.TextChanged += (_, _) => { if (view != content) return; selection = null; suggestions = request.Suggestions(content.Field.Text); Refresh(); };
        content.Selected += index => { selection = index; Refresh(); };
        window.PreviewKeyDown += HandleKey;
        window.Closed += (_, _) =>
        {
            if (panel != window) return;
            var result = outcome; var handlers = this.request;
            panel = null; view = null; this.request = null; suggestions = []; selection = null; outcome = new Outcome.Cancel();
            switch (result)
            {
                case Outcome.Submit submit: handlers?.OnSubmit(submit.Value); break;
                case Outcome.Alternate alternate: handlers?.OnAlternateSubmit?.Invoke(alternate.Value); break;
                case Outcome.Escape when handlers?.OnEscape is { } onEscape: onEscape(); break;
                default: handlers?.OnCancel(); break;
            }
        };
        window.Present(typingNeeded, content.Field);
        if (request.SelectInitialText) content.Field.SelectAll();
    }
    private void Refresh()
    {
        if (view is null) return;
        view.Update(suggestions, selection); panel?.ResizeVisible(view.SurfaceSize);
    }
    private void HandleKey(object sender, KeyEventArgs e)
    {
        if (HandleInput(e.Key, Keyboard.Modifiers, e.IsRepeat)) e.Handled = true;
    }
    internal bool HandleInput(Key key, ModifierKeys modifiers = ModifierKeys.None, bool isRepeat = false)
    {
        if (view is null || request is null || key == Key.ImeProcessed) return false;
        if (isRepeat && key == Key.Enter) return true;
        switch (key)
        {
            case Key.Escape:
                outcome = new Outcome.Escape(); panel?.Dismiss(); return true;
            case Key.Down: case Key.Up:
                if (suggestions.Count > 0) selection = Math.Clamp(selection is { } current ? current + (key == Key.Down ? 1 : -1) : key == Key.Down ? 0 : suggestions.Count - 1, 0, suggestions.Count - 1);
                Refresh(); return true;
            case Key.Tab:
                if (suggestions.Count > 0) { view.Field.Text = suggestions[selection ?? 0].Title; view.Field.CaretIndex = view.Field.Text.Length; }
                return true;
            case Key.Enter:
                var action = SubmissionAction(modifiers, request.OnAlternateSubmit is not null);
                if (action == InputSubmitAction.Ignore || (action == InputSubmitAction.Alternate || request.SelectionOnly) && selection is null) return true;
                var value = selection is { } index ? suggestions[index].Value ?? suggestions[index].Title : view.Field.Text.Trim();
                if (!request.AllowEmptySubmission && string.IsNullOrWhiteSpace(value)) outcome = new Outcome.Cancel();
                else
                {
                    outcome = action == InputSubmitAction.Alternate ? new Outcome.Alternate(value) : new Outcome.Submit(value);
                    request.OnAccept?.Invoke(value);
                }
                panel?.Dismiss(); return true;
        }
        return false;
    }
    public void Dismiss(DismissReason reason = DismissReason.Explicit, bool animated = true) => panel?.Dismiss(reason, animated);
}
public sealed class SessionPickerController : InputPanelController
{
    public void Present(IReadOnlyList<Suggestion> choices, Action<string> onSubmit, Action onCancel, bool typingNeeded = true,
        Action<string>? onRename = null) =>
        Present(new InputRequest("Select a session…", prefix => choices.Where(s => s.Title.Normalize().StartsWith(prefix.Trim().Normalize(), StringComparison.OrdinalIgnoreCase)).ToArray(), onSubmit, onCancel,
            Title: "Multiple sessions found with the given name", Secondary: onRename is null ? null : "Enter resumes · Ctrl+Enter renames",
            SelectionOnly: true, OnAlternateSubmit: onRename), typingNeeded);
}
