using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using CaptureApp.Overlay;
using CaptureApp.AppCore.Semantic;

namespace CaptureApp.App;

internal sealed partial class AppController
{
    private SearchPanelController? search;
    private readonly List<TaskCompletionSource> searchCloseWaiters = [];

    private sealed class SearchSnapshot
    {
        public Dictionary<string, SearchHit> Hits { get; set; } = [];
        public HashSet<string> CurrentIds { get; set; } = [];
        public int Generation { get; set; }
    }

    private void OpenSearch()
    {
        if (!RequireConsent()) { return; }
        Coordinator.Enqueue(async c =>
        {
            _ = c.CommitPending();
            await c.WaitForProcessingAsync();
            _ = c.CommitPending();
            if (!await ClosePanelsAsync()) { return; }
            await c.WaitForCommitsAsync();
            if (c.IsTerminating) { return; }
            if (!pipeline.Monitor.IsRunning) { _ = Task.Run(() => pipeline.SyncAsync()); }
            if (semantic is { } indexer) { _ = Task.Run(() => indexer.WarmAsync()); }
            var panel = new SearchPanelController();
            search = panel;
            var snapshot = new SearchSnapshot();
            panel.Present((query, token) => Task.Run<IReadOnlyList<SearchSection>>(async () =>
            {
                try
                {
                    var empty = string.IsNullOrWhiteSpace(query);
                    IReadOnlyList<SearchHit> hits;
                    if (empty) { hits = pipeline.Index.Recent(20); }
                    else
                    {
                        var keyword = pipeline.Index.Search(query);
                        var semanticHits = semantic is { } indexer ? await indexer.SearchAsync(query, null, token) : SemanticHits.Empty;
                        hits = SemanticIndexer.Fuse(keyword, semanticHits);
                    }

                    token.ThrowIfCancellationRequested();
                    // Old rows may still be rendered while the next generation is built.
                    lock (snapshot)
                    {
                        snapshot.Hits = snapshot.Hits.Where(pair => snapshot.CurrentIds.Contains(pair.Key)).ToDictionary(pair => pair.Key, pair => pair.Value);
                        snapshot.CurrentIds = [];
                        var generation = ++snapshot.Generation;
                        var rows = hits.Select(hit =>
                        {
                            var id = $"{generation}:{hit.BlockID}";
                            snapshot.Hits[id] = hit;
                            snapshot.CurrentIds.Add(id);
                            return Row(hit, id);
                        }).ToArray();
                        return [new SearchSection(empty ? Strings.RecentSection : Strings.ResultsSection, rows)];
                    }
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception error)
                {
                    log.Error($"Search failed ({error.GetType().Name}): {error}");
                    return [new SearchSection(Strings.ResultsSection, [], Strings.SearchFailed)];
                }
            }, token), new SearchActions(_ => { }, _ => { }, _ => { }, OnClose: () =>
            {
                search = null;
                var waiters = searchCloseWaiters.ToArray();
                searchCloseWaiters.Clear();
                foreach (var waiter in waiters) { waiter.TrySetResult(); }
            }, Freeze: (row, action) =>
            {
                SearchHit? hit;
                lock (snapshot) { hit = snapshot.Hits.GetValueOrDefault(row.Id); }
                if (hit is null) { return null; }
                // The full hit is captured now; later query results cannot change the action.
                return action switch
                {
                    SearchAction.Primary => () => CopyHit(hit),
                    SearchAction.Open => () =>
                    {
                        try { OpenNote(pipeline.Vault.NoteLocation(hit.NotePath).Url); }
                        catch (Exception error) { Coordinator.Report(error, Strings.CouldNotOpenNote); }
                    },
                    _ => () =>
                    {
                        try { RevealNote(pipeline.Vault.NoteLocation(hit.NotePath).Url); }
                        catch (Exception error) { Coordinator.Report(error, Strings.CouldNotRevealNote); }
                    }
                };
            }));
        });
    }

    private SearchRow Row(SearchHit hit, string id)
    {
        var parts = new List<string>();
        if (hit.CreatedAt is { } date)
        {
            var today = TimeZoneInfo.ConvertTime(date, pipeline.TimeZone).Date == TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, pipeline.TimeZone).Date;
            var pattern = today ? "HH:mm" : hit.BlockKind == BlockKind.Note ? "MMM d · HH:mm" : "MMM d";
            parts.Add(Strings.Stamp(date, pattern, pipeline.TimeZone));
        }

        if (!string.IsNullOrEmpty(hit.SourceApp)) { parts.Add(hit.SourceApp); }
        var kind = hit.BlockKind switch
        {
            BlockKind.Text => SearchRowKind.Text,
            BlockKind.Image => SearchRowKind.Image,
            _ => SearchRowKind.Note
        };
        Func<CancellationToken, Task<ImageSource?>>? loader = hit.AssetPath is { } asset ? token => LoadThumbnail(asset, token) : null;
        var matches = hit.SnippetMatches.Select(range =>
        {
            var (offset, length) = range.GetOffsetAndLength(hit.Snippet.Length);
            return new TextMatch(offset, length);
        }).ToArray();
        return new SearchRow(id, hit.Title, hit.Snippet, string.Join(" · ", parts), kind, SnippetMatches: matches, ThumbnailLoader: loader);
    }

    private Task<ImageSource?> LoadThumbnail(string asset, CancellationToken token) => Task.Run<ImageSource?>(() =>
    {
        try
        {
            var data = pipeline.AssetData(asset);
            token.ThrowIfCancellationRequested();
            using var stream = new MemoryStream(data);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.DecodePixelWidth = 72;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception error) when (error is IOException or NotSupportedException or FileNotFoundException) { return null; }
    }, token);

    /// Text copies as text; images as PNG plus a bitmap, like the Mac's PNG and TIFF flavors.
    private void CopyHit(SearchHit hit)
    {
        Task.Run(() => hit.BlockKind == BlockKind.Image && hit.AssetPath is { } path ? pipeline.AssetData(path) : null).ContinueWith(task =>
        {
            try
            {
                var data = new DataObject();
                if (task.Result is { } png)
                {
                    data.SetData("PNG", new MemoryStream(png));
                    using var stream = new MemoryStream(png);
                    var bitmap = new BitmapImage();
                    bitmap.BeginInit();
                    bitmap.CacheOption = BitmapCacheOption.OnLoad;
                    bitmap.StreamSource = stream;
                    bitmap.EndInit();
                    data.SetImage(bitmap);
                }
                else
                {
                    data.SetText(hit.Body);
                }

                Clipboard.SetDataObject(data, true);
                Coordinator.ShowToast(new(AppToastStyle.Copied, Strings.Copied));
            }
            catch (Exception error) { Coordinator.Report(error.InnerException ?? error, Strings.CouldNotCopyCapture); }
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }
}
