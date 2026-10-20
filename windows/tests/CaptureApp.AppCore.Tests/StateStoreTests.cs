using System.Text;
using System.Text.Json;
using CaptureApp.AppCore;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class StateStoreTests
{
    [Fact]
    public void StateDirectoryUsesPerUserApplicationSupportAndBundleId()
    {
        var actual = StatePaths.DefaultDirectory();
        var parent = OperatingSystem.IsWindows()
            ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
            : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support");
        Assert.Equal(System.IO.Path.GetFullPath(System.IO.Path.Combine(parent, AppInfo.BundleId)), actual);
    }

    [Fact]
    public void DraftMigratesLegacyMarkdownAndQuarantinesInvalidJson()
    {
        using var temp = new TempDirectory();
        var store = new NoteDraftStore(temp.Path);
        File.WriteAllText(store.LegacyUrl, "legacy draft", new UTF8Encoding(false));
        Assert.Equal(new NoteDraftSnapshot("legacy draft", false), store.LoadSnapshot());
        store.Store("legacy draft", true);
        Assert.False(File.Exists(store.LegacyUrl));
        Assert.Equal(new NoteDraftSnapshot("legacy draft", true), new NoteDraftStore(temp.Path).LoadSnapshot());

        File.WriteAllText(store.Url, "{ invalid", new UTF8Encoding(false));
        Assert.Equal(new NoteDraftSnapshot("", false), store.LoadSnapshot());
        Assert.True(File.Exists(System.IO.Path.Combine(temp.Path, "draft-note.corrupt.json")));
        store.Dispose();
    }

    [Fact]
    public async Task DraftWritesCoalesceLatestSnapshotAndRespectMaximumWait()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var temp = new TempDirectory();
        var writes = 0;
        using var coalesced = new NoteDraftStore(System.IO.Path.Combine(temp.Path, "coalesced"),
            TimeSpan.FromMilliseconds(100), TimeSpan.FromSeconds(1), () => Interlocked.Increment(ref writes));
        coalesced.ScheduleStore("older", true);
        await Task.Delay(15, cancellationToken);
        coalesced.ScheduleStore("latest", false);
        Assert.False(File.Exists(coalesced.Url));
        await WaitUntil(() => File.Exists(coalesced.Url), cancellationToken);
        Assert.Equal(new NoteDraftSnapshot("latest", false), JsonSerializer.Deserialize<NoteDraftSnapshot>(File.ReadAllBytes(coalesced.Url)));
        Assert.Equal(1, Volatile.Read(ref writes));

        var firstWrite = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var producerFinished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var bounded = new NoteDraftStore(System.IO.Path.Combine(temp.Path, "bounded"),
            TimeSpan.FromMilliseconds(400), TimeSpan.FromMilliseconds(120), () => firstWrite.TrySetResult());
        var producer = Task.Run(async () =>
        {
            for (var index = 0; index < 10; index++)
            {
                bounded.ScheduleStore("continuous " + index, false);
                await Task.Delay(25, cancellationToken);
            }

            producerFinished.TrySetResult();
        }, cancellationToken);
        await firstWrite.Task.WaitAsync(TimeSpan.FromSeconds(3), cancellationToken);
        Assert.False(producerFinished.Task.IsCompleted);
        await producer;
        await WaitUntil(() =>
        {
            try { return bounded.LoadSnapshot().Text == "continuous 9"; }
            catch (Exception) { return false; }
        }, cancellationToken);
    }

    [Fact]
    public async Task DraftFlushOrdersAfterInflightWriteAndRetriesFailedBackgroundWrite()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var temp = new TempDirectory();
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        using var ordered = new NoteDraftStore(System.IO.Path.Combine(temp.Path, "ordered"),
            TimeSpan.FromMilliseconds(10), TimeSpan.FromSeconds(1), () =>
            {
                entered.Set();
                if (!release.Wait(TimeSpan.FromSeconds(3))) { throw new IOException("Test write barrier timed out."); }
            });
        ordered.ScheduleStore("stale", false);
        Assert.True(await Task.Run(() => entered.Wait(TimeSpan.FromSeconds(3)), cancellationToken));
        var flush = Task.Run(() => ordered.FlushScheduledStore("latest", true), cancellationToken);
        release.Set();
        await flush.WaitAsync(TimeSpan.FromSeconds(3), cancellationToken);
        Assert.Equal(new NoteDraftSnapshot("latest", true), ordered.LoadSnapshot());

        var failedWrite = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var retry = new NoteDraftStore(System.IO.Path.Combine(temp.Path, "retry"),
            TimeSpan.FromMilliseconds(20), TimeSpan.FromSeconds(1), () => throw new IOException("Injected background failure."));
        retry.ScheduleStore("latest after failure", true, error => failedWrite.TrySetResult(error));
        Assert.IsType<IOException>(await failedWrite.Task.WaitAsync(TimeSpan.FromSeconds(3), cancellationToken));
        retry.FlushScheduledStore("latest after failure", true);
        Assert.Equal(new NoteDraftSnapshot("latest after failure", true), retry.LoadSnapshot());
    }

    [Fact]
    public async Task DraftClearPreventsDelayedWriteFromResurrectingCommittedText()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var temp = new TempDirectory();
        using var store = new NoteDraftStore(temp.Path, TimeSpan.FromMilliseconds(80), TimeSpan.FromSeconds(1));
        store.ScheduleStore("committed text");
        store.ClearIfMatching("committed text");
        await Task.Delay(180, cancellationToken);
        Assert.False(File.Exists(store.Url));

        store.ScheduleStore("latest", false);
        store.SetPinOnSave(true);
        Assert.Equal(new NoteDraftSnapshot("latest", true), store.LoadSnapshot());
    }

    [Fact]
    public void PinStoreAndQuickNoteStateRoundTripSortedIdentitiesAndIntent()
    {
        using var temp = new TempDirectory();
        var pins = new NotePinStore(temp.Path);
        pins.Set("Z.md", true);
        pins.Toggle("A.md");
        var disk = File.ReadAllText(pins.Url);
        Assert.True(disk.IndexOf("A.md", StringComparison.Ordinal) < disk.IndexOf("Z.md", StringComparison.Ordinal));
        var reloaded = new NotePinStore(temp.Path);
        Assert.True(reloaded.IsPinned("A.md"));
        Assert.True(reloaded.IsPinned("Z.md"));
        Assert.False(reloaded.Toggle("A.md"));
        Assert.False(new NotePinStore(temp.Path).IsPinned("A.md"));

        using var drafts = new NoteDraftStore(System.IO.Path.Combine(temp.Path, "drafts"));
        drafts.Store("draft", false);
        var state = new QuickNoteState(destination: null, pinOnSave: true);
        Assert.True(state.TogglePinOnSave(drafts) == false);
        Assert.False(drafts.LoadSnapshot().PinOnSave);
        state.ResetPinOnSave(drafts);
        Assert.False(state.PinOnSave);

        var suggestion = new NoteSuggestion("A", NoteKind.Note, "A.md", DateTimeOffset.UtcNow);
        state.Suggestions = [suggestion, suggestion with { Kind = NoteKind.Inbox }];
        Assert.Equal(NoteKind.Note, state.Kinds["A.md"]);
    }

    [Fact]
    public void JournalCanRecoverOCRTextWhenAnImagePayloadWasLost()
    {
        using var temp = new TempDirectory();
        using var pipeline = CapturePipeline.Open(System.IO.Path.Combine(temp.Path, "vault"), System.IO.Path.Combine(temp.Path, "state"));
        var image = pipeline.PrepareImage([1, 2, 3, 4], new CaptureSource("Test"), ocr: "recovered OCR text");
        pipeline.Stage(image);
        var path = Assert.Single(pipeline.Journal.RecordPaths());
        using (var document = JsonDocument.Parse(File.ReadAllBytes(path)))
        {
            Assert.True(document.RootElement.GetProperty("hasPNG").GetBoolean());
            Assert.True(document.RootElement.TryGetProperty("prepared", out _));
            Assert.True(document.RootElement.TryGetProperty("ocr", out _));
            Assert.True(document.RootElement.TryGetProperty("noteDraft", out _));
        }

        File.Delete(System.IO.Path.ChangeExtension(path, ".png"));
        var recovered = pipeline.Journal.Load(path);
        Assert.Equal(CaptureContentKind.Text, recovered.Prepared.Capture.Content.Kind);
        Assert.Equal("recovered OCR text", recovered.Prepared.Capture.Content.Value);
        Assert.Null(recovered.Png);
    }

    private static async Task WaitUntil(Func<bool> predicate, CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(3);
        while (!predicate())
        {
            Assert.True(DateTimeOffset.UtcNow < deadline, "The scheduled draft state did not converge.");
            await Task.Delay(10, cancellationToken);
        }
    }
}
