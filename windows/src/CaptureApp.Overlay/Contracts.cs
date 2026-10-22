using System.Windows.Media;

namespace CaptureApp.Overlay;

public enum ToastStyle { Success, Warning, Session, Copied }
public sealed record ToastHint(string Key, string Label = "");
public sealed record Toast(ToastStyle Style, string Title, string? Subtitle = null, ToastHint? Hint = null, double? Duration = null)
{
    public double DurationSeconds => Duration ?? (Style == ToastStyle.Warning ? Tokens.WarningToastDuration : Tokens.DefaultToastDuration);
}
public sealed record Suggestion(string Title, string? Secondary = null, string? SymbolName = null, string? Value = null);
/// <summary>Ranges are UTF-16 offsets, matching the Swift NSRange contract.</summary>
public readonly record struct TextMatch(int Start, int Length);
public enum SearchRowKind { Text, Image, Note }
public sealed record SearchRow(string Id, string Title, string Snippet = "", string Meta = "", SearchRowKind Kind = SearchRowKind.Text,
    IReadOnlyList<TextMatch>? TitleMatches = null, IReadOnlyList<TextMatch>? SnippetMatches = null,
    Func<CancellationToken, Task<ImageSource?>>? ThumbnailLoader = null);
public sealed record SearchSection(string Title, IReadOnlyList<SearchRow> Rows, string? ErrorMessage = null);
public enum SearchAction { Primary, Open, Reveal }
public sealed record SearchActions(Action<SearchRow> Primary, Action<SearchRow> Open, Action<SearchRow> Reveal,
    Action? OnClose = null, Func<SearchRow, SearchAction, Action?>? Freeze = null);
public sealed record InputRequest(string Placeholder, Func<string, IReadOnlyList<Suggestion>> Suggestions,
    Action<string> OnSubmit, Action OnCancel, string InitialText = "", string? Title = null, string? Secondary = null,
    bool SelectionOnly = false, Action<string>? OnAccept = null, Action<string>? OnAlternateSubmit = null,
    string? SelectedValue = null, bool SelectInitialText = false, Action? OnEscape = null,
    bool AllowEmptySubmission = false);

// Stable UI-only contracts for the cards in step 6b, mirroring NoteContracts.swift.
public enum NoteActionId { NewNote, Browse, Pin, OpenAsNote, CopyMarkdown, DiscardDraft, SaveAsNewNote }
public sealed record BrowseItem(string Id, string Title, string Detail, string SymbolName, bool IsPinned);
public enum BrowseChoice { Write, Open, Reveal }
/// <summary>Callbacks for the quick-note panel, mirroring NoteEditorHandlers.</summary>
public sealed record QuickNoteHandlers(
    Action<string> OnDraft, Action<string> OnSubmit, Action<string> OnNew, Action<string> OnOpenAsNote,
    Func<IReadOnlyList<BrowseItem>> BrowseItems, Action<BrowseItem, BrowseChoice> OnBrowse,
    Func<bool> OnTogglePin, Action OnClose, Action<Exception> OnError,
    Func<string, string>? TitleForText = null, Action<string>? OnScheduleDraft = null,
    Func<string, string?>? ExistingTitleForText = null, Action<string>? OnSaveAsNew = null)
{
    private static readonly System.Text.RegularExpressions.Regex Marker = new(@"^[ \t]*(?:#+[ \t]+|[-*+][ \t]+(?:\[[ xX]\][ \t]*)?|[0-9]+[.)][ \t]+|>[ \t]*)");
    /// <summary>First non-blank line with leading Markdown markers removed, cut at 60 characters.</summary>
    public static string DefaultTitle(string text)
    {
        var line = text.Split('\n').Select(l => l.TrimEnd('\r')).FirstOrDefault(l => l.Any(c => !char.IsWhiteSpace(c)));
        if (line is null) return "";
        while (Marker.Match(line) is { Success: true, Length: > 0 } match) line = line[match.Length..];
        line = line.Trim(' ', '\t');
        return line.Length > Tokens.QuickTitleLimit ? line[..Tokens.QuickTitleLimit].Trim(' ', '\t') + "…" : line;
    }
}
public enum QuickNoteToggle { Presented, Reactivated, Closed }
