using CaptureApp.Core;

namespace CaptureApp.AppCore;

public abstract record ThoughtSaveOutcome
{
    public sealed record Saved : ThoughtSaveOutcome;
    public sealed record Failed(string Message) : ThoughtSaveOutcome;
}

public sealed class ThoughtComposer(Func<string?, Guid, string, Task> write)
{
    public const string SaveFailedMessage = "Couldn't save your thought. Your text is kept.";
    public const string CaptureNotFoundMessage = "Couldn't find that capture in its note. Your text is kept.";
    private readonly object gate = new();
    private readonly Dictionary<Guid, string> drafts = [];
    private readonly Dictionary<Guid, string> saved = [];
    private readonly Dictionary<Guid, Func<Task<string>>> destinations = [];
    public IReadOnlyDictionary<Guid, string> Drafts { get { lock (gate) { return new Dictionary<Guid, string>(drafts); } } }

    public string Begin(Guid captureId, string? savedThought, Func<Task<string>> destination)
    {
        lock (gate)
        {
            if (savedThought is not null) saved[captureId] = savedThought;
            destinations[captureId] = destination;
            return drafts.GetValueOrDefault(captureId) ?? saved.GetValueOrDefault(captureId) ?? "";
        }
    }

    public void Close(Guid captureId, string text)
    {
        lock (gate)
        {
            if (text == (saved.GetValueOrDefault(captureId) ?? "")) drafts.Remove(captureId);
            else drafts[captureId] = text;
        }
    }

    public async Task<ThoughtSaveOutcome> SaveAsync(Guid captureId, string text)
    {
        try
        {
            Func<Task<string>> destination;
            lock (gate)
            {
                if (!destinations.TryGetValue(captureId, out destination!)) throw new ThoughtWriteException(ThoughtWriteError.CaptureNotFound);
            }
            await write(string.IsNullOrWhiteSpace(text) ? null : text, captureId, await destination().ConfigureAwait(false)).ConfigureAwait(false);
            lock (gate)
            {
                drafts.Remove(captureId);
                if (string.IsNullOrWhiteSpace(text)) saved.Remove(captureId); else saved[captureId] = text;
            }
            return new ThoughtSaveOutcome.Saved();
        }
        catch (Exception error)
        {
            lock (gate) { drafts[captureId] = text; }
            return new ThoughtSaveOutcome.Failed(error is ThoughtWriteException { Kind: ThoughtWriteError.CaptureNotFound } ? CaptureNotFoundMessage : SaveFailedMessage);
        }
    }
}
