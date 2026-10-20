using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using CaptureApp.Core;

namespace CaptureApp.AppCore;

public sealed record NoteDraftSnapshot(
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("pinOnSave")] bool PinOnSave);

/// Stores the editor text and pin intent as one atomically replaced snapshot.
public sealed class NoteDraftStore : IDisposable
{
    private sealed record PendingWrite(string Text, bool? PinOnSave, Action<Exception>? OnFailure);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private readonly object gate = new();
    private readonly TimeSpan debounceInterval;
    private readonly TimeSpan maxCoalescingInterval;
    private readonly Action? beforeScheduledWriteForTesting;
    private readonly AppLog logger;
    private Timer? scheduledWrite;
    private PendingWrite? pendingWrite;
    private DateTimeOffset? firstPendingAt;
    private long generation;
    private bool disposed;

    public string Url { get; }
    public string LegacyUrl { get; }

    public NoteDraftStore(string stateDirectory, TimeSpan? debounceInterval = null, TimeSpan? maxCoalescingInterval = null,
        Action? beforeScheduledWriteForTesting = null)
    {
        var directory = Path.GetFullPath(stateDirectory);
        Url = Path.Combine(directory, "draft-note.json");
        LegacyUrl = Path.Combine(directory, "draft-note.md");
        this.debounceInterval = debounceInterval ?? TimeSpan.FromMilliseconds(180);
        this.maxCoalescingInterval = maxCoalescingInterval ?? TimeSpan.FromSeconds(1);
        this.beforeScheduledWriteForTesting = beforeScheduledWriteForTesting;
        logger = new(directory, "drafts");
    }

    public string Load() => LoadSnapshot().Text;

    public NoteDraftSnapshot LoadSnapshot()
    {
        lock (gate)
        {
            ThrowIfDisposed();
            var generationToFlush = SupersedeScheduledWrite();
            if (pendingWrite is { } pending)
            {
                WriteSnapshot(pending);
                ClearPendingWrite(generationToFlush);
            }

            return Read();
        }
    }

    public void ScheduleStore(string text, bool? pinOnSave = null, Action<Exception>? onFailure = null)
    {
        lock (gate)
        {
            ThrowIfDisposed();
            var previous = pendingWrite;
            pendingWrite = new(text, pinOnSave ?? previous?.PinOnSave, onFailure);
            generation++;
            firstPendingAt ??= DateTimeOffset.UtcNow;
            scheduledWrite?.Dispose();
            var quietDeadline = DateTimeOffset.UtcNow + debounceInterval;
            var maximumDeadline = firstPendingAt.Value + maxCoalescingInterval;
            var due = quietDeadline < maximumDeadline ? quietDeadline : maximumDeadline;
            var delay = due - DateTimeOffset.UtcNow;
            var scheduledGeneration = generation;
            scheduledWrite = new Timer(_ => PersistScheduledWrite(scheduledGeneration), null,
                delay <= TimeSpan.Zero ? TimeSpan.Zero : delay, Timeout.InfiniteTimeSpan);
        }
    }

    public void FlushScheduledStore(string text, bool? pinOnSave = null)
    {
        lock (gate)
        {
            ThrowIfDisposed();
            var pending = ReplacePendingWrite(text, pinOnSave);
            var writeGeneration = generation;
            WriteSnapshot(pending);
            ClearPendingWrite(writeGeneration);
        }
    }

    public void Store(string text, bool? pinOnSave = null)
    {
        lock (gate)
        {
            ThrowIfDisposed();
            var pending = ReplacePendingWrite(text, pinOnSave, keepFailureHandler: false);
            var writeGeneration = generation;
            WriteSnapshot(pending);
            ClearPendingWrite(writeGeneration);
        }
    }

    public void SetPinOnSave(bool pin)
    {
        lock (gate)
        {
            ThrowIfDisposed();
            var writeGeneration = SupersedeScheduledWrite(updatingPin: pin);
            if (pendingWrite is { } pending)
            {
                WriteSnapshot(pending);
            }
            else
            {
                var draft = Read();
                if (!string.IsNullOrWhiteSpace(draft.Text))
                {
                    Write(draft with { PinOnSave = pin });
                }
            }

            ClearPendingWrite(writeGeneration);
        }
    }

    public void ClearIfMatching(string text)
    {
        lock (gate)
        {
            ThrowIfDisposed();
            var writeGeneration = SupersedeScheduledWrite();
            if (pendingWrite is { } pending)
            {
                WriteSnapshot(pending);
            }

            if (CaptureFormat.NoteBody(Read().Text) == CaptureFormat.NoteBody(text))
            {
                Remove();
            }

            ClearPendingWrite(writeGeneration);
        }
    }

    /// Applies the save's explicit intent or the intent on the matching current draft, then consumes it.
    public void CompleteSave(string matchingText, bool? pinOnSave, Action<bool> applyPin)
    {
        lock (gate)
        {
            ThrowIfDisposed();
            var writeGeneration = SupersedeScheduledWrite();
            if (pendingWrite is { } pending)
            {
                WriteSnapshot(pending);
            }

            var draft = Read();
            var matches = CaptureFormat.NoteBody(draft.Text) == CaptureFormat.NoteBody(matchingText);
            applyPin(pinOnSave ?? (matches && draft.PinOnSave));
            if (matches)
            {
                Remove();
            }

            ClearPendingWrite(writeGeneration);
        }
    }

    private void PersistScheduledWrite(long expectedGeneration)
    {
        Action<Exception>? failure = null;
        Exception? error = null;
        lock (gate)
        {
            if (disposed || generation != expectedGeneration || pendingWrite is not { } pending)
            {
                return;
            }

            try
            {
                beforeScheduledWriteForTesting?.Invoke();
                WriteSnapshot(pending);
                ClearPendingWrite(expectedGeneration);
            }
            catch (Exception caught)
            {
                scheduledWrite?.Dispose();
                scheduledWrite = null;
                firstPendingAt = DateTimeOffset.UtcNow;
                failure = pendingWrite?.OnFailure;
                error = caught;
                logger.Error($"Scheduled draft write failed: {caught.Message}");
            }
        }

        if (error is not null)
        {
            try { failure?.Invoke(error); }
            catch (Exception callbackError) { logger.Error($"Draft write failure handler failed: {callbackError}"); }
        }
    }

    private PendingWrite ReplacePendingWrite(string text, bool? pinOnSave, bool keepFailureHandler = true)
    {
        var previous = pendingWrite;
        var pending = new PendingWrite(text, pinOnSave ?? previous?.PinOnSave,
            keepFailureHandler ? previous?.OnFailure : null);
        generation++;
        scheduledWrite?.Dispose();
        scheduledWrite = null;
        firstPendingAt = null;
        pendingWrite = pending;
        return pending;
    }

    private long SupersedeScheduledWrite(bool? updatingPin = null)
    {
        generation++;
        scheduledWrite?.Dispose();
        scheduledWrite = null;
        firstPendingAt = null;
        if (updatingPin is { } pin && pendingWrite is { } pending)
        {
            pendingWrite = pending with { PinOnSave = pin };
        }

        return generation;
    }

    private void ClearPendingWrite(long expectedGeneration)
    {
        if (generation != expectedGeneration)
        {
            return;
        }

        pendingWrite = null;
        scheduledWrite?.Dispose();
        scheduledWrite = null;
        firstPendingAt = null;
    }

    private void WriteSnapshot(PendingWrite pending)
    {
        if (string.IsNullOrWhiteSpace(pending.Text))
        {
            Remove();
            return;
        }

        var pin = pending.PinOnSave ?? Read().PinOnSave;
        Write(new(pending.Text, pin));
    }

    private NoteDraftSnapshot Read()
    {
        try
        {
            var bytes = File.ReadAllBytes(Url);
            var draft = JsonSerializer.Deserialize<NoteDraftSnapshot>(bytes, JsonOptions);
            if (draft?.Text is null)
            {
                throw new JsonException("Draft text is missing.");
            }

            return draft;
        }
        catch (JsonException)
        {
            var corrupt = Path.Combine(Path.GetDirectoryName(Url)!, "draft-note.corrupt.json");
            try { File.Move(Url, corrupt, true); }
            catch (FileNotFoundException) { }
            return new("", false);
        }
        catch (FileNotFoundException)
        {
            try { return new(File.ReadAllText(LegacyUrl, new UTF8Encoding(false, true)), false); }
            catch (FileNotFoundException) { return new("", false); }
            catch (DirectoryNotFoundException) { return new("", false); }
        }
        catch (DirectoryNotFoundException)
        {
            return new("", false);
        }
    }

    private void Write(NoteDraftSnapshot draft)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(draft, JsonOptions);
        AtomicJsonFile.Write(Url, bytes);
        RemoveFile(LegacyUrl);
    }

    private void Remove()
    {
        RemoveFile(LegacyUrl);
        RemoveFile(Url);
    }

    private static void RemoveFile(string path)
    {
        try { File.Delete(path); }
        catch (DirectoryNotFoundException) { }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(disposed, this);

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            scheduledWrite?.Dispose();
            scheduledWrite = null;
        }
    }
}
