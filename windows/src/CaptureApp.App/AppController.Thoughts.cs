using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using CaptureApp.Overlay;

namespace CaptureApp.App;

internal sealed partial class AppController
{
    private readonly ThoughtEditorPanel thoughtEditor = new();
    private ThoughtComposer thoughts = null!;

    private void WireThoughts()
    {
        thoughts = new ThoughtComposer((text, id, path) => pipeline.SetThoughtAsync(text, id, path));
        Coordinator.ThoughtRequested += OnThoughtRequested;
    }

    private void OnThoughtRequested(ThoughtTarget target) => dispatcher.BeginInvoke(() =>
    {
        if (disposed || quitting || Coordinator.IsTerminating) { return; }
        // The PNG in hand, since the index may not have the asset until the queued commit runs.
        Func<Task<ImageSource?>>? image = target.ExcerptImagePng is { } png ? () => LoadThoughtImage(() => png) : null;
        PresentThought(target.CaptureId, new(target.SourceTitle, target.SourceDetail, target.ExcerptText, image), null, async () =>
        {
            if (pipeline.NotePathFor(target.CaptureId) is { } note) { return pipeline.Vault.NoteLocation(note).Url; }
            if (target.Commit is { } commit) { return (await commit.ConfigureAwait(false)).Destination.Url; }
            throw new ThoughtWriteException(ThoughtWriteError.CaptureNotFound);
        });
    });

    private async Task OpenThoughtAsync(SearchHit hit, Guid id)
    {
        string? saved;
        try
        {
            saved = await pipeline.SavedThoughtAsync(id, pipeline.Vault.NoteLocation(hit.NotePath).Url).ConfigureAwait(true);
        }
        catch (Exception error)
        {
            log.Error($"Reading capture thought failed: {error.GetType().Name}");
            if (!disposed && !quitting) { Coordinator.ShowToast(new(AppToastStyle.Warning, "Couldn't read that capture's thought.")); }
            return;
        }

        var title = string.IsNullOrWhiteSpace(hit.WindowTitle) && string.IsNullOrWhiteSpace(hit.SourceApp)
            ? hit.NoteTitle : CaptureFormat.SourceHeading(new(hit.SourceApp, hit.WindowTitle));
        Func<Task<ImageSource?>>? image = hit.BlockKind == BlockKind.Image && hit.AssetPath is { } asset
            ? () => LoadThoughtImage(() => pipeline.AssetData(asset)) : null;
        PresentThought(id, new(title, string.IsNullOrWhiteSpace(hit.SourceApp) ? null : hit.SourceApp,
            hit.BlockKind == BlockKind.Image ? null : hit.Body, image), saved,
            () => Task.FromResult(pipeline.Vault.NoteLocation(pipeline.NotePathFor(id) ?? hit.NotePath).Url), savedStateLoaded: true);
    }

    private void PresentThought(Guid id, ThoughtEditorContent content, string? saved, Func<Task<string>> destination, bool savedStateLoaded = false)
    {
        if (disposed || quitting || Coordinator.IsTerminating) { return; }
        // Preserve even when reopening the same capture: Present closes the previous panel after Begin.
        if (thoughtEditor.CaptureId is { } previous && thoughtEditor.CurrentText is { } text) { thoughts.Close(previous, text); }
        content = content with { Text = thoughts.Begin(id, saved, destination, savedStateLoaded) };
        thoughtEditor.Present(id, content, text => _ = SaveThoughtAsync(id, text, thoughtEditor.InstanceId), text => thoughts.Close(id, text));
    }

    private async Task SaveThoughtAsync(Guid id, string text, int editorInstance)
    {
        var outcome = await thoughts.SaveAsync(id, text).ConfigureAwait(false);
        await dispatcher.InvokeAsync(() =>
        {
            if (disposed || quitting || thoughtEditor.CaptureId != id || thoughtEditor.InstanceId != editorInstance) { return; }
            switch (outcome)
            {
                case ThoughtSaveOutcome.Saved:
                    thoughtEditor.SaveSucceeded(text);
                    if (host?.StagedToastVisible != true && Coordinator.Pending is null)
                    {
                        Coordinator.ShowToast(new(AppToastStyle.Success, "Thought saved"));
                    }
                    break;
                case ThoughtSaveOutcome.Failed failed:
                    thoughtEditor.SaveFailed(failed.Message);
                    break;
            }
        });
    }

    private static Task<ImageSource?> LoadThoughtImage(Func<byte[]> read) => Task.Run<ImageSource?>(() =>
    {
        try
        {
            var bytes = read();
            using var stream = new MemoryStream(bytes);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception) { return null; } // An unavailable excerpt must not block writing a thought.
    });
}
