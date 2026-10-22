using System.Text.Json;
using CaptureApp.Core;

namespace CaptureApp.AppCore;

public sealed record CaptureJob(PreparedCapture Prepared, byte[]? Png = null, string? Ocr = null, string? NoteDraft = null);

/// Durable append intent. Records are written before a capture reaches the vault.
public sealed class CaptureJournal
{
    private sealed record JournalRecord(PreparedCapture Prepared, bool HasPNG, string? Ocr, string? NoteDraft);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    private readonly AppLog logger;
    private readonly object gate = new();
    private readonly string redirectsPath;
    private readonly Dictionary<Guid, Destination> redirects;
    public string DirectoryPath { get; }

    public CaptureJournal(string stateDirectory)
    {
        var state = Path.GetFullPath(stateDirectory);
        DirectoryPath = Path.Combine(state, "unsaved");
        redirectsPath = Path.Combine(state, "capture-destinations.json");
        redirects = File.Exists(redirectsPath)
            ? JsonSerializer.Deserialize<Dictionary<Guid, Destination>>(File.ReadAllBytes(redirectsPath), JsonOptions)
                ?? throw new IOException("The capture destination state is empty.")
            : [];
        logger = new(state, "capture-journal");
        var durableIds = RecordPaths().Select(path => Guid.TryParse(Path.GetFileNameWithoutExtension(path), out var id) ? id : Guid.Empty).ToHashSet();
        var completed = redirects.Keys.Where(id => !durableIds.Contains(id)).ToArray();
        foreach (var id in completed) redirects.Remove(id);
        if (completed.Length != 0)
            AtomicJsonFile.Write(redirectsPath, JsonSerializer.SerializeToUtf8Bytes(redirects, JsonOptions));
    }

    public void Store(CaptureJob job)
    {
        lock (gate)
        {
            job = Resolve(job);
            Directory.CreateDirectory(DirectoryPath);
            var stem = job.Prepared.Capture.Id.ToString("D").ToLowerInvariant();
            if (job.Png is not null)
            {
                AtomicJsonFile.Write(Path.Combine(DirectoryPath, stem + ".png"), job.Png);
            }

            var record = new JournalRecord(job.Prepared, job.Png is not null, job.Ocr, job.NoteDraft);
            AtomicJsonFile.Write(Path.Combine(DirectoryPath, stem + ".json"), JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions));
            logger.Debug($"Stored capture journal record {stem}.");
        }
    }

    public IReadOnlyList<string> RecordPaths()
    {
        if (!System.IO.Directory.Exists(DirectoryPath)) { return []; }
        return System.IO.Directory.EnumerateFiles(DirectoryPath, "*.json")
            .Select(path => (Path: path, Date: RecordDate(path)))
            .OrderBy(value => value.Date)
            .ThenBy(value => Path.GetFileName(value.Path), StringComparer.Ordinal)
            .Select(value => value.Path)
            .ToArray();
    }

    public CaptureJob Load(string recordPath)
    {
        lock (gate)
        {
            var bytes = File.ReadAllBytes(recordPath);
            JournalRecord record;
            try
            {
                record = JsonSerializer.Deserialize<JournalRecord>(bytes, JsonOptions)
                    ?? throw new RecordException("The journal record is empty.");
            }
            catch (RecordException) { throw; }
            catch (Exception error) when (error is JsonException or NotSupportedException or InvalidOperationException)
            {
                throw new RecordException("The journal record could not be decoded.", error);
            }

            if (record.Prepared is null || record.Prepared.Capture is null || record.Prepared.Destination is null)
                throw new RecordException("The journal record is missing capture or destination data.");
            var stem = Path.GetFileNameWithoutExtension(recordPath);
            if (!string.Equals(stem, record.Prepared.Capture.Id.ToString("D").ToLowerInvariant(), StringComparison.Ordinal))
            {
                throw new RecordException("The journal filename does not match its capture identity.");
            }

            byte[]? png = null;
            if (record.HasPNG)
            {
                try { png = File.ReadAllBytes(Path.Combine(DirectoryPath, stem + ".png")); }
                catch (FileNotFoundException)
                {
                    if (string.IsNullOrWhiteSpace(record.Ocr))
                    {
                        throw new RecordException("The journal image is missing and has no OCR recovery text.");
                    }

                    var original = record.Prepared;
                    var textCapture = original.Capture with { Content = CaptureContent.Text(record.Ocr) };
                    var recovered = new PreparedCapture(textCapture, original.Destination, original.CreatesNote, original.NoteMarkerIsIdentity);
                    return Resolve(new(recovered));
                }
                catch (DirectoryNotFoundException)
                {
                    if (string.IsNullOrWhiteSpace(record.Ocr))
                    {
                        throw new RecordException("The journal image is missing and has no OCR recovery text.");
                    }

                    var original = record.Prepared;
                    var textCapture = original.Capture with { Content = CaptureContent.Text(record.Ocr) };
                    var recovered = new PreparedCapture(textCapture, original.Destination, original.CreatesNote, original.NoteMarkerIsIdentity);
                    return Resolve(new(recovered));
                }
            }

            return Resolve(new(record.Prepared, png, record.Ocr, record.NoteDraft));
        }
    }

    public CaptureJob Resolve(CaptureJob job)
    {
        lock (gate)
        {
            return redirects.TryGetValue(job.Prepared.Capture.Id, out var destination)
                ? job with { Prepared = job.Prepared with { Destination = destination } } : job;
        }
    }

    public IReadOnlyList<Guid> CaptureIdsTargeting(string noteUrl)
    {
        lock (gate)
        {
            var ids = redirects.Where(pair => SameUrl(pair.Value.Url, noteUrl)).Select(pair => pair.Key).ToHashSet();
            foreach (var path in RecordPaths())
            {
                try
                {
                    var job = Resolve(Load(path));
                    if (SameUrl(job.Prepared.Destination.Url, noteUrl)) ids.Add(job.Prepared.Capture.Id);
                }
                catch (RecordException) { /* Startup replay quarantines malformed captures independently. */ }
            }
            return ids.ToArray();
        }
    }

    // Persist the identity follow-up before rewriting individual records. Stale in-memory retries
    // are resolved by capture ID, so a later, independent note may safely reuse the old filename.
    public void Relocate(IReadOnlyList<Guid> ids, Destination destination)
    {
        lock (gate)
        {
            var updated = new Dictionary<Guid, Destination>(redirects);
            foreach (var id in ids) updated[id] = destination;
            AtomicJsonFile.Write(redirectsPath, JsonSerializer.SerializeToUtf8Bytes(updated, JsonOptions));
            foreach (var id in ids) redirects[id] = destination;
            foreach (var id in ids)
            {
                var path = Path.Combine(DirectoryPath, id.ToString("D").ToLowerInvariant() + ".json");
                if (!File.Exists(path)) continue;
                try { Store(Resolve(Load(path))); }
                catch (RecordException) { /* Preserve it for the normal replay quarantine path. */ }
            }
        }
    }

    private static bool SameUrl(string left, string right) => string.Equals(Path.GetFullPath(left).Normalize(),
        Path.GetFullPath(right).Normalize(), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    public void Quarantine(string recordPath)
    {
        lock (gate)
        {
            var corrupt = Path.Combine(DirectoryPath, "corrupt");
            System.IO.Directory.CreateDirectory(corrupt);
            var stem = Path.GetFileNameWithoutExtension(recordPath);
            var targetStem = File.Exists(Path.Combine(corrupt, stem + ".json"))
                ? stem + "-" + Guid.NewGuid().ToString("N")
                : stem;
            foreach (var extension in new[] { ".json", ".png" })
            {
                var source = Path.Combine(DirectoryPath, stem + extension);
                if (File.Exists(source))
                {
                    File.Move(source, Path.Combine(corrupt, targetStem + extension));
                }
            }

            logger.Notice($"Quarantined corrupt capture journal record {stem}.");
        }
    }

    public void Remove(Guid id)
    {
        lock (gate)
        {
            var stem = id.ToString("D").ToLowerInvariant();
            File.Delete(Path.Combine(DirectoryPath, stem + ".json"));
            File.Delete(Path.Combine(DirectoryPath, stem + ".png"));
            // Keep redirects for this instance: an older commit can still retry its prepared object
            // after a newer commit removed the journal record. Fresh startup prunes completed IDs.
        }
    }

    private static DateTimeOffset RecordDate(string path)
    {
        try
        {
            var record = JsonSerializer.Deserialize<JournalRecord>(File.ReadAllBytes(path), JsonOptions);
            return record?.Prepared.Capture.CreatedAt ?? DateTimeOffset.MinValue;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or NotSupportedException or InvalidOperationException)
        {
            return DateTimeOffset.MinValue;
        }
    }

    public sealed class RecordException(string message, Exception? inner = null) : IOException(message, inner);
}
