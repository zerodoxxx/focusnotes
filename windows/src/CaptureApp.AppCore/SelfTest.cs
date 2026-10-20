using System.Text;
using CaptureApp.Core;

namespace CaptureApp.AppCore;

/// What the App-supplied self-test sections receive.
public sealed record SelfTestContext(string RunDirectory, string? ModelsDirectory, TextWriter Output, CancellationToken CancellationToken);

/// Headless checks for AppCore. Platform, controller, and visual checks are added when those layers are connected.
public static class SelfTest
{
    public static async Task RunAsync(string directory, string? modelsDirectory = null, TextWriter? output = null,
        CancellationToken cancellationToken = default, Func<SelfTestContext, Task>? extension = null)
    {
        output ??= Console.Out;
        var parent = Path.GetFullPath(directory);
        Directory.CreateDirectory(parent);
        var runDirectory = Path.Combine(parent, "appcore-self-test-" + Guid.NewGuid().ToString("N"));
        var vaultDirectory = Path.Combine(runDirectory, "vault");
        var stateDirectory = Path.Combine(runDirectory, "state");
        var homeDirectory = Path.Combine(runDirectory, "home");
        Directory.CreateDirectory(runDirectory);
        var needle = "appcoreindexneedle" + Guid.NewGuid().ToString("N");
        var replayNeedle = "journalreplayneedle" + Guid.NewGuid().ToString("N");
        var watcherNeedle = "watcherchange" + Guid.NewGuid().ToString("N");
        var shutdownNeedle = "shutdowndrain" + Guid.NewGuid().ToString("N");
        var zone = TimeZoneInfo.Local;
        CapturePipeline? pipeline = null;

        try
        {
            pipeline = CapturePipeline.Open(vaultDirectory, stateDirectory, zone, modelsDirectory, 0.12,
                homeDirectory: homeDirectory);
            await WritePass(output, "pipeline opened").ConfigureAwait(false);

            var session = pipeline.Sessions.Start("Self-Test Session");
            var restoredSession = new SessionStore(stateDirectory, pipeline.Vault, zone).Current();
            var externalPath = Path.Combine(pipeline.Vault.HomeRoot, "External.md");
            Directory.CreateDirectory(pipeline.Vault.HomeRoot);
            await File.WriteAllTextAsync(externalPath, "# External\n", new UTF8Encoding(false), cancellationToken).ConfigureAwait(false);
            var externalNote = pipeline.Vault.ManagedLocation(externalPath);
            pipeline.Vault.RegisterExternalNote(externalNote.Note);
            if (restoredSession is null || restoredSession.Name != session.Name || restoredSession.NotePath != session.NotePath
                || restoredSession.Resumed != session.Resumed || Math.Abs((restoredSession.StartedAt - session.StartedAt).TotalSeconds) >= 1)
            {
                throw new InvalidOperationException("Session state did not survive a store reload.");
            }

            if (pipeline.Vault.ExternalNoteRegistry?.Paths().SingleOrDefault() != "External.md")
            {
                throw new InvalidOperationException("The external-note registry did not persist its HOME-relative path.");
            }

            pipeline.Sessions.End();
            await WritePass(output, "session and external-note state round-tripped").ConfigureAwait(false);

            var source = new CaptureSource("Self-Test", "Headless pipeline");
            var job = pipeline.PrepareText(needle + " full body\nSecond line for copying.", source, "Self-Test Capture");
            pipeline.Stage(job);
            var saved = pipeline.Commit(job);
            var noteBytes = File.ReadAllBytes(saved.Destination.Url);
            var relative = pipeline.Vault.RelativePath(saved.Destination.Url) ?? "";
            var directoryPart = string.Join('/', relative.Split('/', StringSplitOptions.RemoveEmptyEntries).SkipLast(1));
            var parentPath = Path.GetDirectoryName(saved.Destination.Url)!;
            var prefix = CaptureFormat.RelativePath(parentPath, pipeline.Vault.Root);
            if (prefix == ".") { prefix = ""; }
            var expectedBlock = Encoding.UTF8.GetBytes(CaptureFormat.Block(job.Prepared.Capture, directoryPart, zone, false, prefix));
            if (!Contains(noteBytes, expectedBlock))
            {
                throw new InvalidOperationException("The saved vault note did not contain the byte-identical capture block.");
            }

            var png = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03 };
            var imageJob = pipeline.PrepareImage(png, source);
            pipeline.Stage(imageJob);
            var savedImage = pipeline.Commit(imageJob);
            var imageHit = pipeline.Index.Capture(savedImage.CaptureId);
            if (imageHit?.AssetPath is not { } assetPath || !pipeline.AssetData(assetPath).SequenceEqual(png))
            {
                throw new InvalidOperationException("The saved image capture did not preserve its vault asset bytes.");
            }

            await WritePass(output, "capture persisted to vault bytes").ConfigureAwait(false);

            var recovery = pipeline.PrepareText(replayNeedle + " recovered from the journal", source);
            pipeline.Stage(recovery);
            var recoveryId = recovery.Prepared.Capture.Id;
            var recoveryPath = recovery.Prepared.Destination.Url;
            pipeline.Dispose();
            pipeline = CapturePipeline.Open(vaultDirectory, stateDirectory, zone, modelsDirectory, 0.12,
                homeDirectory: homeDirectory);
            var restored = await pipeline.ReplayUnsavedAsync(cancellationToken).ConfigureAwait(false);
            var replayedAgain = await pipeline.ReplayUnsavedAsync(cancellationToken).ConfigureAwait(false);
            var recoveredBlockCount = CountOccurrences(File.ReadAllBytes(recoveryPath), Encoding.UTF8.GetBytes("<!-- capture:" + recoveryId.ToString("D")));
            if (restored != 1 || replayedAgain != 0 || recoveredBlockCount != 1 || pipeline.Index.Capture(recoveryId) is null)
            {
                throw new InvalidOperationException("Journal replay did not restore a capture exactly once.");
            }

            await WritePass(output, "journal replayed exactly once").ConfigureAwait(false);

            pipeline.Drafts.Store("draft round-trip", false);
            var quickNote = new QuickNoteState(destination: null);
            if (!quickNote.TogglePinOnSave(pipeline.Drafts))
            {
                throw new InvalidOperationException("Quick-note pin intent did not toggle on.");
            }

            var reloadedDraft = new NoteDraftStore(stateDirectory);
            var draftSnapshot = reloadedDraft.LoadSnapshot();
            reloadedDraft.Dispose();
            pipeline.Pins.Set("Inbox.md", true);
            var pins = new NotePinStore(stateDirectory);
            if (draftSnapshot.Text != "draft round-trip" || !draftSnapshot.PinOnSave || !pins.IsPinned("Inbox.md"))
            {
                throw new InvalidOperationException("Draft or pin state did not survive a store reload.");
            }

            await WritePass(output, "drafts and pins round-tripped").ConfigureAwait(false);

            var hits = pipeline.Index.Search(needle);
            if (hits.Count != 1 || hits[0].CaptureID != saved.CaptureId)
            {
                throw new InvalidOperationException("The keyword index did not return the saved capture.");
            }

            await WritePass(output, "keyword index query passed").ConfigureAwait(false);

            pipeline.StartWatcher();
            await pipeline.SyncAsync().ConfigureAwait(false);
            var externalCapture = new Capture(Guid.NewGuid(), DateTimeOffset.UtcNow,
                CaptureContent.Text(watcherNeedle + " appended by an external editor"), new CaptureSource("External Editor"));
            var block = CaptureFormat.Block(externalCapture, "", zone, false, "");
            await File.AppendAllTextAsync(pipeline.Vault.InboxUrl, block, new UTF8Encoding(false), cancellationToken).ConfigureAwait(false);
            var watcherDeadline = DateTimeOffset.UtcNow.AddSeconds(5);
            while (DateTimeOffset.UtcNow < watcherDeadline)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (pipeline.Index.Search(watcherNeedle).Any(hit => hit.CaptureID == externalCapture.Id)) { break; }
                await Task.Delay(30, cancellationToken).ConfigureAwait(false);
            }

            if (!pipeline.Index.Search(watcherNeedle).Any(hit => hit.CaptureID == externalCapture.Id))
            {
                throw new TimeoutException("A vault watcher change was not indexed within five seconds.");
            }

            await WritePass(output, "watcher change reindexed").ConfigureAwait(false);

            var shutdownJob = pipeline.PrepareText(shutdownNeedle + " pending capture", source);
            pipeline.Stage(shutdownJob);
            var shutdownTask = Task.Run(() => pipeline.Commit(shutdownJob), cancellationToken);
            if (!await ShutdownWait.WaitAsync(shutdownTask, TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false))
            {
                throw new TimeoutException("Shutdown did not drain the pending capture before the deadline.");
            }

            var shutdownSaved = await shutdownTask.ConfigureAwait(false);
            if (pipeline.Index.Capture(shutdownSaved.CaptureId) is null || pipeline.Journal.RecordPaths().Count != 0)
            {
                throw new InvalidOperationException("Shutdown completed without saving and clearing pending journal work.");
            }

            await pipeline.StopWatcherAsync().ConfigureAwait(false);
            await WritePass(output, "shutdown drain passed").ConfigureAwait(false);
            await Shell.ControllerSelfTest.RunAsync(Path.Combine(runDirectory, "controller"), zone, output, cancellationToken).ConfigureAwait(false);
            // Platform sections (OCR, helper status, architecture) and semantic checks are supplied by the App.
            if (extension is not null)
            {
                await extension(new SelfTestContext(runDirectory, modelsDirectory, output, cancellationToken)).ConfigureAwait(false);
            }
        }
        finally
        {
            pipeline?.Dispose();
        }
    }

    private static async Task WritePass(TextWriter output, string section) =>
        await output.WriteLineAsync("PASS  " + section).ConfigureAwait(false);

    private static bool Contains(byte[] haystack, byte[] needle)
    {
        if (needle.Length == 0 || needle.Length > haystack.Length) { return false; }
        return haystack.AsSpan().IndexOf(needle) >= 0;
    }

    private static int CountOccurrences(byte[] haystack, byte[] needle)
    {
        if (needle.Length == 0) { return 0; }
        var count = 0;
        var offset = 0;
        while (offset <= haystack.Length - needle.Length)
        {
            var found = haystack.AsSpan(offset).IndexOf(needle);
            if (found < 0) { break; }
            count++;
            offset += found + needle.Length;
        }

        return count;
    }
}
