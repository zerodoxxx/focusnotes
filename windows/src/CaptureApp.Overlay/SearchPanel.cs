using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace CaptureApp.Overlay;

public sealed class SearchPanelView : OverlaySurface, IDisposable
{
    public TextBox Field { get; } = new();
    private readonly Grid fieldHost;
    private readonly ScrollViewer scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly TextBlock spinner = Ui.Icon("arrow.triangle.2.circlepath", "Secondary", Tokens.SpinnerSize);
    private readonly RotateTransform rotation = new();
    private CancellationTokenSource? thumbnails;
    private IReadOnlyList<SearchSection> sections = [];
    private int? selection;
    private bool loading;
    public event Action<int>? Selected;
    public event Action<int>? Primary;
    public SearchPanelView(string query = "") : base(Tokens.SearchWidth, Tokens.Padding * 2 + Tokens.SearchFieldHeight)
    {
        fieldHost = Ui.Field(Field, "Search notes"); Field.Text = query;
        spinner.RenderTransformOrigin = new Point(Tokens.Center, Tokens.Center); spinner.RenderTransform = rotation;
        AutomationProperties.SetName(spinner, "Searching");
        Update([], null);
    }
    public void SetLoading(bool value, bool animate = true)
    {
        loading = value; spinner.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        if (value && animate && SystemParameters.ClientAreaAnimation) rotation.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(Tokens.Zero, Tokens.FullRotation, TimeSpan.FromSeconds(Tokens.SpinnerRotationSeconds)) { RepeatBehavior = RepeatBehavior.Forever });
        else rotation.BeginAnimation(RotateTransform.AngleProperty, null);
    }
    public void Select(int? value) { selection = value; Rebuild(); }
    public void Update(IReadOnlyList<SearchSection> value, int? selected)
    {
        thumbnails?.Cancel(); thumbnails?.Dispose(); thumbnails = new CancellationTokenSource();
        sections = value; selection = selected; Rebuild();
    }
    public async Task WaitForThumbnailsAsync()
    {
        await Task.WhenAll(thumbnailTasks);
    }
    private readonly List<Task> thumbnailTasks = [];
    private void Rebuild()
    {
        thumbnailTasks.Clear(); Body.Children.Clear();
        var width = Width - Tokens.Padding * 2;
        var remaining = Tokens.MaxResults; var listHeight = Tokens.Zero;
        foreach (var section in sections.Where(s => s.Rows.Count > 0))
        {
            if (remaining == 0) break;
            var count = Math.Min(remaining, section.Rows.Count); remaining -= count;
            listHeight += Tokens.HeaderHeight + count * Tokens.ResultHeight;
        }
        if (listHeight == 0) listHeight = Tokens.NoResultsHeight;
        Height = Tokens.Padding * 2 + Tokens.SearchFieldHeight + Tokens.BorderWidth * 2 + listHeight + Tokens.FooterHeight;
        Ui.Place(Body, Ui.Icon("magnifyingglass"), Tokens.Padding, Tokens.Padding + (Tokens.SearchFieldHeight - Tokens.IconSize) / 2, Tokens.IconSize, Tokens.IconSize);
        var fieldX = Tokens.Padding + Tokens.IconSize + Tokens.IconGap;
        Ui.Place(Body, fieldHost, fieldX, Tokens.Padding, Width - fieldX - Tokens.Padding - Tokens.SpinnerSize - Tokens.IconGap, Tokens.SearchFieldHeight);
        Ui.Place(Body, spinner, Width - Tokens.Padding - Tokens.SpinnerSize, Tokens.Padding + (Tokens.SearchFieldHeight - Tokens.SpinnerSize) / 2, Tokens.SpinnerSize, Tokens.SpinnerSize);
        SetLoading(loading);
        double top = Tokens.Padding + Tokens.SearchFieldHeight;
        Ui.Place(Body, Ui.Separator(), Tokens.Padding, top, width, Tokens.BorderWidth);
        top += Tokens.BorderWidth;
        var document = new StackPanel(); var index = 0; ChoiceRowView? selectedRow = null;
        foreach (var section in sections.Where(s => s.Rows.Count > 0))
        {
            var header = Ui.Text(section.Title.ToUpperInvariant(), "Header", "Secondary");
            header.Margin = new Thickness(Tokens.RowInset, Tokens.Zero, Tokens.RowInset, Tokens.Zero);
            document.Children.Add(new Grid { Height = Tokens.HeaderHeight, Children = { header } });
            foreach (var model in section.Rows)
            {
                var rowIndex = index++; var row = new ChoiceRowView(model, selection == rowIndex) { Height = Tokens.ResultHeight };
                row.Click += (_, _) => Selected?.Invoke(rowIndex);
                row.MouseDoubleClick += (_, e) => { Primary?.Invoke(rowIndex); e.Handled = true; };
                document.Children.Add(row);
                if (selection == rowIndex) selectedRow = row;
                if (model.ThumbnailLoader is { } loader && row.Thumbnail is { } image && thumbnails is not null)
                    thumbnailTasks.Add(LoadThumbnail(loader, image, thumbnails.Token));
            }
        }
        if (index > 0)
        {
            scroll.Content = document;
            Ui.Place(Body, scroll, Tokens.Padding, top, width, listHeight);
            if (selectedRow is not null) { scroll.UpdateLayout(); selectedRow.BringIntoView(); }
        }
        else
        {
            var message = Ui.Text(sections.Select(s => s.ErrorMessage).FirstOrDefault(s => s is not null) ?? $"No matches for “{Field.Text}”", "Message", "Secondary", accessible: true);
            message.TextAlignment = TextAlignment.Center;
            AutomationProperties.SetName(message, message.Text);
            Ui.Place(Body, message, Tokens.Padding, top + (listHeight - Tokens.TitleLineHeight) / 2, width, Tokens.TitleLineHeight);
        }
        top += listHeight;
        Ui.Place(Body, Ui.Separator(), Tokens.Padding, top, width, Tokens.BorderWidth);
        var footer = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var (key, label) in new[] { ("Enter", "Copy"), ("Ctrl+Enter", "Open"), ("Alt+Enter", "Show in File Explorer"), ("Esc", "Close") })
        {
            var hint = new KeycapView(key, label) { Margin = new Thickness(Tokens.Zero, Tokens.Zero, Tokens.FooterHintGap, Tokens.Zero) }; footer.Children.Add(hint);
        }
        Ui.Place(Body, footer, Tokens.Padding, top + Tokens.BorderWidth, width, Tokens.FooterHeight);
    }
    private static async Task LoadThumbnail(Func<CancellationToken, Task<ImageSource?>> loader, Image image, CancellationToken token)
    {
        try { var result = await loader(token); if (!token.IsCancellationRequested) image.Source = result; }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception) { /* A failed thumbnail leaves the placeholder; the result remains usable. */ }
    }
    public void Dispose() { thumbnails?.Cancel(); thumbnails?.Dispose(); thumbnails = null; SetLoading(false); thumbnailTasks.Clear(); }
}
public sealed class SearchPanelController
{
    private OverlayWindow? panel;
    private SearchPanelView? view;
    private SearchActions? actions;
    private Func<string, CancellationToken, Task<IReadOnlyList<SearchSection>>>? provider;
    private CancellationTokenSource? query;
    private IReadOnlyList<SearchRow> rows = [];
    private int? selection;
    private int generation;
    private Action? pendingAction;
    public bool IsVisible => panel?.IsVisible == true;
    public void Present(Func<string, CancellationToken, Task<IReadOnlyList<SearchSection>>> provider, SearchActions actions, bool typingNeeded = true)
    {
        panel?.Dismiss(DismissReason.Replaced, false);
        this.provider = provider; this.actions = actions; rows = []; selection = null; pendingAction = null;
        var content = new SearchPanelView(); view = content;
        var window = new OverlayWindow(content); panel = window;
        content.Field.TextChanged += (_, _) => Schedule(true);
        content.Selected += Select;
        content.Primary += index => Perform(index, SearchAction.Primary);
        window.PreviewKeyDown += HandleKey;
        window.Dismissed += _ => CancelQuery();
        window.Closed += (_, _) =>
        {
            if (panel != window) return;
            CancelQuery(); content.Dispose();
            var close = this.actions?.OnClose; var action = pendingAction;
            panel = null; view = null; this.provider = null; this.actions = null; rows = []; selection = null; pendingAction = null;
            close?.Invoke(); action?.Invoke();
        };
        window.Present(typingNeeded, content.Field); Schedule(false);
    }
    private void CancelQuery() { generation++; query?.Cancel(); query?.Dispose(); query = null; }
    private void Schedule(bool debounce)
    {
        CancelQuery(); query = new CancellationTokenSource();
        view?.SetLoading(false);
        _ = RunQuery(debounce, generation, query.Token);
    }
    private async Task RunQuery(bool debounce, int version, CancellationToken token)
    {
        var currentProvider = provider; var text = view?.Field.Text ?? "";
        if (currentProvider is null) return;
        try
        {
            if (debounce) await Task.Delay(Tokens.QueryDebounceMilliseconds, token);
            using var spinner = CancellationTokenSource.CreateLinkedTokenSource(token);
            var loadingTask = DelayedLoading(version, spinner.Token);
            IReadOnlyList<SearchSection> result;
            try { result = await currentProvider(text, token); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
            catch (Exception) { result = [new SearchSection("", [], "Search unavailable. Try again.")]; }
            finally { spinner.Cancel(); await loadingTask; }
            if (token.IsCancellationRequested || version != generation || view is null) return;
            view.SetLoading(false); rows = result.SelectMany(s => s.Rows).ToArray(); selection = rows.Count == 0 ? null : 0;
            view.Update(result, selection); panel?.ResizeVisible(view.SurfaceSize);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }
    private async Task DelayedLoading(int version, CancellationToken token)
    {
        try { await Task.Delay(Tokens.LoadingDelayMilliseconds, token); if (version == generation) view?.SetLoading(true); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }
    private void Select(int index) { if (index < 0 || index >= rows.Count) return; selection = index; view?.Select(index); }
    private void HandleKey(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Down || key == Key.Up) { if (rows.Count > 0) Select(Math.Clamp((selection ?? 0) + (key == Key.Down ? 1 : -1), 0, rows.Count - 1)); e.Handled = true; }
        if (key == Key.Enter) { if (selection is { } index) Perform(index, Keyboard.Modifiers.HasFlag(ModifierKeys.Control) ? SearchAction.Open : Keyboard.Modifiers.HasFlag(ModifierKeys.Alt) ? SearchAction.Reveal : SearchAction.Primary); e.Handled = true; }
    }
    private void Perform(int index, SearchAction kind)
    {
        if (index < 0 || index >= rows.Count || actions is null) return;
        var row = rows[index]; var handlers = actions;
        pendingAction = handlers.Freeze is { } freeze ? freeze(row, kind) : () => { switch (kind) { case SearchAction.Open: handlers.Open(row); break; case SearchAction.Reveal: handlers.Reveal(row); break; default: handlers.Primary(row); break; } };
        panel?.Dismiss();
    }
    public void Dismiss(DismissReason reason = DismissReason.Explicit) => panel?.Dismiss(reason);
}
