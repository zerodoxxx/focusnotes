using System.Windows;
using System.Windows.Media;
using CaptureApp.Overlay;

namespace CaptureApp.Gallery;

internal sealed record Fixture(string Name, Func<OverlaySurface> Create, double Width, double Height, Action<OverlaySurface>? Verify = null);
internal static class Fixtures
{
    internal static readonly Suggestion[] Suggestions = [
        new("System Design", "Session · Oct 9", "record.circle"), new("MLE Interview Prep", "Session · Oct 8", "record.circle"),
        new("Rate limiting", "Note · System Design", "doc.text"), new("Distributed systems", "Note · System Design", "doc.text")];
    internal static readonly Suggestion[] Sessions = [new("System Design", "Modified Oct 9 · /vault/one.md", "record.circle", "/vault/one.md"), new("System Design", "Modified Oct 8 · /vault/two.md", "record.circle", "/vault/two.md")];
    internal static readonly SearchSection[] Recent = [new("Recent", [
        new("system", "System Design", "Design a reliable notification service at scale.", "10:04 · Edge · System Design"),
        new("limits", "Rate limiting", "Token buckets allow controlled bursts of requests.", "09:58 · Edge · System Design"),
        new("diagram", "Service architecture", "Gateway, queue, and worker topology.", "09:51 · Photos · System Design", SearchRowKind.Image, ThumbnailLoader: _ => Task.FromResult<ImageSource?>(Thumbnail())),
        new("mle", "MLE Interview Prep", "Feature stores, evaluation, and serving latency.", "Yesterday · Notes · Interview Prep", SearchRowKind.Note),
        new("cache", "Caching patterns", "Cache aside with explicit invalidation boundaries.", "Yesterday · Edge · System Design"),
        new("queue", "Message queues", "At least once delivery needs idempotent consumers.", "Oct 9 · Edge · System Design")])];
    internal static readonly SearchSection[] Matches = [new("Captures", [
        new("limit", "Rate limiting", "A rate limit protects services from traffic spikes.", "10:04 · Edge · System Design", TitleMatches: [new(5, 5)], SnippetMatches: [new(7, 5)]),
        new("token", "Token bucket limits", "Set a limit per user, route, and time window.", "09:58 · Edge · System Design", TitleMatches: [new(13, 5)], SnippetMatches: [new(6, 5)])]),
        new("Notes", [new("note", "System Design", "Rate limiting: fixed windows versus token buckets.", "Oct 9 · System Design", SearchRowKind.Note, SnippetMatches: [new(5, 5)])])];
    internal static IEnumerable<Fixture> All()
    {
        foreach (var (style, title, subtitle, stem) in new[] {
            (ToastStyle.Success, "Capture saved", "Added to System Design", "success"),
            (ToastStyle.Warning, "Choose a destination", "Your capture is waiting for a note", "warning"),
            (ToastStyle.Session, "Session started", "MLE Interview Prep", "session"),
            (ToastStyle.Copied, "Copied to clipboard", "Ready to paste into your notes", "copied") })
        foreach (var hasSubtitle in new[] { false, true })
        foreach (var hasHint in new[] { false, true })
        {
            ToastView Create() => new(new Toast(style, title, hasSubtitle ? subtitle : null, hasHint ? new ToastHint("Alt+Shift+Q", "name") : null));
            // Toast width follows measured text, within the token bounds.
            var sample = Create();
            yield return new Fixture($"toast-{stem}-{(hasSubtitle ? "subtitle" : "plain")}-{(hasHint ? "hint" : "no-hint")}", Create, sample.Width, Tokens.ToastHeight);
        }
        foreach (var (name, sections, query, selected, loading) in new (string, SearchSection[], string, int?, bool)[] {
            ("empty", [], "", null, false), ("loading", Recent, "distributed", null, true),
            ("recent", Recent, "", 0, false), ("matches", Matches, "limit", 0, false),
            ("results", Recent, "", null, false), ("selected-row", Recent, "", 2, false),
            ("no-results", [], "consistent hashing", null, false), ("error", [new("", [], "Search unavailable. Try again.")], "limit", null, false),
            ("max-results", [new("Recent", Enumerable.Range(0, Tokens.MaxResults + 2).Select(i => new SearchRow(i.ToString(), "Result " + i, "A captured thought.", "Today · System Design")).ToArray())], "", 0, false) })
        {
            SearchPanelView Create() { var view = new SearchPanelView(query); view.Update(sections, selected); view.SetLoading(loading, animate: false); return view; }
            var remaining = Tokens.MaxResults; double listHeight = Tokens.Zero;
            foreach (var section in sections) { if (remaining == 0 || section.Rows.Count == 0) continue; var count = Math.Min(remaining, section.Rows.Count); remaining -= count; listHeight += Tokens.HeaderHeight + count * Tokens.ResultHeight; }
            if (listHeight == 0) listHeight = Tokens.NoResultsHeight;
            yield return new Fixture("search-" + name, Create, Tokens.SearchWidth, Tokens.Padding * 2 + Tokens.SearchFieldHeight + Tokens.BorderWidth * 2 + listHeight + Tokens.FooterHeight);
        }
        yield return Input("input-empty", "Name this session", "", [], null);
        yield return Input("input-suggestions", "Name this session", "System", Suggestions, null);
        yield return Input("input-selected", "Name this session", "System", Suggestions, 0);
        yield return Input("input-subheading", "Subheading", "", [], null, "Add subheading", "In System Design");
        yield return Input("input-max-suggestions", "Name this session", "", Suggestions.Concat(Suggestions).ToArray(), 0);
        yield return Input("session-picker", "Select a session…", "", Sessions, null, "Multiple sessions found with the given name", "Enter resumes · Ctrl+Enter renames");
        yield return Input("session-picker-selected", "Select a session…", "", Sessions, 0, "Multiple sessions found with the given name", "Enter resumes · Ctrl+Enter renames");
        yield return Input("session-picker-empty", "Select a session…", "zzz", [], null, "Multiple sessions found with the given name", "Enter resumes · Ctrl+Enter renames");
        yield return Input("session-rename", "Name this session", "System Design", [], null, "Rename and resume session", "Enter renames and resumes · Esc returns to sessions");
        yield return Input("session-rename-error", "Name this session", "Daily sync", [], null, "Rename and resume session", "Check the name and file access. Existing files are kept.");
        foreach (var quick in QuickFixtures()) yield return quick;
    }
    internal static readonly BrowseItem[] BrowseItems =
    [
        new("a", "Weekly review", "Note · Oct 12", "doc.text", true), new("b", "System Design", "Session · Oct 9", "record.circle", true),
        new("c", "Rate limiting", "Note · Oct 9", "doc.text", false), new("d", "Caching patterns", "Note · Oct 8", "doc.text", false),
        new("e", "Message queues", "Note · Oct 8", "doc.text", false), new("f", "MLE Interview Prep", "Session · Oct 7", "record.circle", false),
        new("g", "Reading list", "Note · Oct 6", "doc.text", false), new("h", "Trip planning", "Note · Oct 5", "doc.text", false),
        new("i", "Standup notes", "Note · Oct 4", "doc.text", false), new("j", "Ideas", "Note · Oct 3", "doc.text", false)
    ];
    internal const string MarkdownSample = "# Heading one\n## Heading two\n### Heading three\n#### Heading four\nPlain with **bold**, *italic*, ~~strike~~ and `code`.\n"
        + "A [link](https://example.com) and https://example.org\n- bullet item\n1. numbered item\n- [ ] open task\n- [x] done task\n> quoted line\n```\nlet x = 1;\n```\nTyping here";
    private const string TaskSample = "- [ ] buy milk\n- [x] ship the build\nplain line";
    private const double GalleryWorkHeight = 900;
    private static IEnumerable<Fixture> QuickFixtures()
    {
        const double bands = Tokens.QuickTopBandHeight + Tokens.QuickFooterHeight;
        Fixture Quick(string name, string text, Action<QuickNoteView>? configure = null, Action<QuickNoteView>? verify = null, string? destination = null, bool pinned = false, bool restored = false, double work = GalleryWorkHeight)
        {
            QuickNoteView Create() { var view = new QuickNoteView(destination, pinned, text, restored) { WorkAreaHeight = work }; configure?.Invoke(view); return view; }
            var sample = Create(); var fixture = new Fixture(name, Create, sample.Width, sample.Height, surface => verify?.Invoke((QuickNoteView)surface)); sample.Dispose();
            return fixture;
        }
        static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        yield return Quick("quick-empty", "", verify: v =>
        {
            Require(Math.Abs(v.Width - Tokens.QuickMinWidth) < Tokens.LayoutTolerance, "quick-empty: minimum width");
            Require(Math.Abs(v.Height - Math.Ceiling(bands + v.EditorLineHeight * Tokens.EditorMinLines)) < Tokens.LayoutTolerance, "quick-empty: two-line minimum height");
        });
        yield return Quick("quick-empty-hover", "", v => { v.SetRevealed(true, false); v.Editor.ShowCaretForGallery = true; });
        yield return Quick("quick-hover-pinned", "Trip planning\nBook the train for Friday", v => v.SetRevealed(true, false), destination: "System Design", pinned: true, restored: true);
        yield return Quick("quick-markdown", MarkdownSample, verify: v =>
        {
            Require(v.Editor.RenderedCheckboxes == 2, "quick-markdown: unchecked and checked task boxes render");
            Require(v.Editor.HiddenCharacters > 0, "quick-markdown: syntax is hidden off the caret line");
            Require(v.Editor.IsSyntaxRevealed(v.Editor.LineCount), "quick-markdown: caret line shows syntax");
            Require(v.Height <= Math.Min(GalleryWorkHeight * Tokens.QuickMaxHeightFraction, Tokens.QuickMaxHeight) + Tokens.LayoutTolerance, "quick-markdown: within the height cap");
        });
        yield return Quick("quick-caret-line", MarkdownSample, v => v.Editor.CaretOffset = v.Editor.LineStart(5) + 12, v =>
        {
            Require(v.Editor.IsSyntaxRevealed(5) && !v.Editor.IsSyntaxRevealed(1), "quick-caret-line: only the caret line shows syntax");
        });
        yield return Quick("quick-tasks", TaskSample, verify: v => Require(v.Editor.RenderedCheckboxes == 2, "quick-tasks: both checkboxes render"));
        yield return Quick("quick-tasks-caret", "- [ ] first task\n- [ ] keep typing", v => v.Editor.ShowCaretForGallery = true, v =>
        {
            Require(v.Editor.RenderedCheckboxes == 2 && v.Editor.IsSyntaxRevealed(2), "quick-tasks-caret: the task being typed retains its checkbox");
            Require(v.Editor.CaretOffset == v.Editor.TextLength, "quick-tasks-caret: caret remains after the editable task text");
        });
        yield return Quick("quick-tasks-checked-caret", TaskSample, v =>
        {
            v.Editor.CaretOffset = v.Editor.LineStart(2) + "- [x] ship the build".Length;
            v.Editor.ShowCaretForGallery = true;
        }, v => Require(v.Editor.RenderedCheckboxes == 2 && v.Editor.IsSyntaxRevealed(2), "quick-tasks-checked-caret: a checked task remains a checkbox while editing"));
        yield return Quick("quick-caret-preview", TaskSample, v =>
        {
            v.Editor.CaretOffset = v.Editor.LineStart(3) + 5;
            v.Editor.ShowCaretForGallery = true;
        }, v =>
        {
            Require(v.Editor.RenderedCheckboxes == 2, "quick-caret-preview: inactive task markers retain checkbox rendering");
            Require(v.Editor.CaretBoundsForGallery is { } caret && Math.Abs(caret.Height - Tokens.EditorFontSize * Tokens.EditorCaretHeightFactor) < Tokens.LayoutTolerance,
                "quick-caret-preview: caret follows font metrics");
            Require(v.Editor.CheckboxExpectedBoundsForGallery.Count == 2,
                "quick-caret-preview: text baselines provide both checkbox target bounds");
        });
        yield return Quick("quick-wide", new string('w', 160) + " " + new string('w', 40), verify: v =>
            Require(Math.Abs(v.Width - Tokens.QuickMaxWidth) < Tokens.LayoutTolerance, "quick-wide: width caps at the maximum"));
        var longText = string.Join("\n", Enumerable.Range(1, 80).Select(i => "Line " + i));
        yield return Quick("quick-long-540", longText, verify: v =>
            Require(Math.Abs(v.Height - Math.Ceiling(GalleryWorkHeight * Tokens.QuickMaxHeightFraction)) < Tokens.LayoutTolerance, "quick-long-540: height stops at 60% of the work area"));
        yield return Quick("quick-long-680", longText, work: 1500, verify: v =>
            Require(Math.Abs(v.Height - Tokens.QuickMaxHeight) < Tokens.LayoutTolerance, "quick-long-680: height stops at 680"));
        yield return Quick("quick-actions", "Trip planning\nBook the train", v => { v.SetRevealed(true, false); v.ShowActions(); }, v =>
        {
            const double expected = Tokens.CardFieldHeight + Tokens.BorderWidth + Tokens.CardVerticalPadding * 2 + 6 * Tokens.MenuRowHeight + Tokens.MenuGroupMargin * 2 + Tokens.BorderWidth;
            Require(v.CardSize is { } size && Math.Abs(size.Width - Tokens.MenuWidth) < Tokens.LayoutTolerance && Math.Abs(size.Height - expected) < Tokens.LayoutTolerance, "quick-actions: card size from tokens");
            Require(v.Height >= Tokens.QuickTopBandHeight + Tokens.CardTopGap + expected + Tokens.CardEdgeMargin - Tokens.LayoutTolerance, "quick-actions: window extends under the card");
        });
        yield return Quick("quick-actions-pinned", "Trip planning", v => { v.SetRevealed(true, false); v.ShowActions(); }, pinned: true);
        yield return Quick("quick-append-actions", "Trip planning\nBook the train", v =>
        {
            v.ExistingTitleForText = _ => "Trip planning";
            v.SetRevealed(true, false);
            v.ShowActions();
        }, v =>
        {
            Require(v.AppendsToExisting, "quick-append-actions: typed matches append");
            Require(ActionItem.Standard(false, true, v.AppendsToExisting).Single(a => a.Id == NoteActionId.SaveAsNewNote).IsEnabled,
                "quick-append-actions: Save as New Note is available");
            Require(QuickNoteView.ShortcutAction(System.Windows.Input.Key.Enter, System.Windows.Input.ModifierKeys.Control | System.Windows.Input.ModifierKeys.Alt) == NoteActionId.SaveAsNewNote,
                "quick-append-actions: Ctrl+Alt+Enter creates a new note");
            Require(QuickNoteView.ShortcutAction(System.Windows.Input.Key.Enter, System.Windows.Input.ModifierKeys.Control) is null,
                "quick-append-actions: Ctrl+Enter keeps the default save");
        });
        yield return Quick("quick-browse", "Trip planning\nBook the train", v => { v.SetRevealed(true, false); v.BrowseItems = () => BrowseItems; v.ShowBrowse(BrowseItems); }, v =>
        {
            // Two headers and seven visible rows, pinned section first.
            const double expected = Tokens.CardFieldHeight + Tokens.BorderWidth + Tokens.CardVerticalPadding * 2 + 2 * Tokens.BrowseHeaderHeight + Tokens.BrowseVisibleRows * Tokens.BrowseRowHeight + Tokens.BorderWidth + Tokens.BrowseFooterHeight;
            Require(v.CardSize is { } size && Math.Abs(size.Width - Tokens.BrowseCardWidth) < Tokens.LayoutTolerance && Math.Abs(size.Height - expected) < Tokens.LayoutTolerance, "quick-browse: card size from tokens");
        });
        yield return Quick("quick-browse-empty", "Trip planning", v => { v.SetRevealed(true, false); v.ShowBrowse([]); }, v =>
        {
            const double expected = Tokens.CardFieldHeight + Tokens.BorderWidth + Tokens.BrowseEmptyHeight + Tokens.BorderWidth + Tokens.BrowseFooterHeight;
            Require(v.CardSize is { } size && Math.Abs(size.Height - expected) < Tokens.LayoutTolerance, "quick-browse-empty: empty card size from tokens");
        });
    }
    private static Fixture Input(string name, string placeholder, string text, Suggestion[] suggestions, int? selected, string? title = null, string? secondary = null) => new(name,
        () => new InputPanelView(placeholder, text, suggestions, selected, title, secondary), Tokens.InputWidth,
        Tokens.Padding * 2 + Tokens.InputFieldHeight + (title is null ? Tokens.Zero : Tokens.HeaderHeight) + (secondary is null ? Tokens.Zero : Tokens.MetaLineHeight + Tokens.Padding / 2) + (suggestions.Length == 0 ? Tokens.Zero : Tokens.BorderWidth + Math.Min(suggestions.Length, Tokens.MaxSuggestions) * Tokens.SuggestionHeight));
    private static DrawingImage Thumbnail()
    {
        var group = new DrawingGroup();
        group.Children.Add(new GeometryDrawing(SystemColors.HighlightBrush, null, new RectangleGeometry(new Rect(Tokens.Zero, Tokens.Zero, Tokens.ThumbnailSize, Tokens.ThumbnailSize), Tokens.ThumbnailRadius, Tokens.ThumbnailRadius)));
        group.Children.Add(new GeometryDrawing(SystemColors.HighlightTextBrush, null, new EllipseGeometry(new Point(Tokens.ThumbnailSize / 2, Tokens.ThumbnailSize / 2), Tokens.ThumbnailSize / 4, Tokens.ThumbnailSize / 4)));
        var image = new DrawingImage(group); image.Freeze(); return image;
    }
}
