namespace CaptureApp.Core;

public sealed class CaptureService(Vault vault, SessionStore sessions, NoteWriter writer, TimeProvider? timeProvider = null, Func<Guid>? makeId = null)
{
    private readonly object gate = new();
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly Func<Guid> createId = makeId ?? Guid.NewGuid;
    private readonly HashSet<string> preparedNoteUrls = new(StringComparer.Ordinal);
    public SavedCapture SaveText(string text, CaptureSource source, string? noteTitle = null)
    {
        lock (gate)
        {
            var destination = Route(noteTitle);
            Register(destination);
            var capture = new Capture(createId(), clock.GetUtcNow(), CaptureContent.Text(text), source);
            writer.Append(capture, destination.Url, destination.Title);
            return new(capture.Id, destination);
        }
    }

    public SavedCapture SaveImage(byte[] png, CaptureSource source, string? noteTitle = null)
    {
        lock (gate)
        {
            var destination = Route(noteTitle);
            Register(destination);
            var now = clock.GetUtcNow();
            var asset = writer.SaveImage(png, now);
            var capture = new Capture(createId(), now, CaptureContent.Image(asset), source);
            writer.Append(capture, destination.Url, destination.Title);
            return new(capture.Id, destination);
        }
    }

    public PreparedCapture Prepare(Capture capture, string? noteTitle = null)
    {
        lock (gate)
        {
            var notes = LoadNotesForRouting(vault.ExternalRegistrySnapshot, vault.ListNotes);
            return new(capture, Router.Destination(noteTitle, sessions.Current(), notes, vault));
        }
    }

    public PreparedCapture PrepareNote(Capture capture, TimeZoneInfo timeZone, Destination? destination = null)
    {
        lock (gate)
        {
            if (destination is not null)
            {
                return new(capture, destination);
            }

            if (sessions.Current() is { } active)
            {
                return new(capture, Router.Destination(null, active, [], vault));
            }

            if (capture.Content.Kind != CaptureContentKind.Note)
            {
                return Prepare(capture);
            }

            var note = new TypedNote(capture.Content.Value, capture.CreatedAt, timeZone, vault.NamingRules);
            var name = note.PathName ?? throw new NotePathNameException(note.PathNameError ?? NotePathNameError.InvalidComponent);
            var selected = name;
            var location = vault.ResolveNoteName(name);
            if (!File.Exists(location.Url) && preparedNoteUrls.Contains(location.Url))
            {
                var suffix = 2;
                while (true)
                {
                    var components = name.Components.ToArray();
                    components[^1] = NoteTitle.FileStem($"{name.LeafName} {suffix++}");
                    var candidateName = NotePathName.Validated(name.Scope, components, vault.NamingRules);
                    var candidate = vault.ResolveNoteName(candidateName);
                    if (!preparedNoteUrls.Contains(candidate.Url) && !File.Exists(candidate.Url))
                    {
                        selected = candidateName;
                        location = candidate;
                        break;
                    }
                }
            }

            var creates = !File.Exists(location.Url) && !Directory.Exists(location.Url);
            var target = new Destination(location.Url, ReferenceEquals(selected, name) ? note.Title : selected.DisplayTitle, NoteKind.Note);
            preparedNoteUrls.Add(target.Url);
            return new(capture with { Content = CaptureContent.Note(note.Body) }, target, creates ? true : null, true);
        }
    }

    public SavedCapture Save(PreparedCapture prepared, byte[]? png = null)
    {
        lock (gate)
        {
            Register(prepared.Destination);
            if (prepared.CreatesNote == true)
            {
                preparedNoteUrls.Add(prepared.Destination.Url);
            }

            vault.Prepare();
            writer.AppendIfMissing(prepared.Capture, prepared.Destination, png, prepared.NoteMarkerIsIdentity == true || prepared.CreatesNote == true);
            preparedNoteUrls.Remove(prepared.Destination.Url);
            return new(prepared.Capture.Id, prepared.Destination);
        }
    }

    private Destination Route(string? title)
    {
        vault.Prepare();
        return Router.Destination(title, sessions.Current(), vault.ListNotes(), vault);
    }

    private void Register(Destination destination)
    {
        var managed = vault.ManagedLocation(destination.Url);
        if (managed.Scope == NotePathScope.Home)
        {
            vault.RegisterExternalNote(managed.Note);
        }
    }

    public static IReadOnlyList<NoteRef> LoadNotesForRouting(Func<ExternalNoteRegistry.Snapshot?> registrySnapshot, Func<ExternalNoteRegistry.Snapshot?, IReadOnlyList<NoteRef>> loadNotes)
    {
        var snapshot = registrySnapshot();
        try
        {
            return loadNotes(snapshot);
        }
        catch (IOException error) when (error is not ExternalNoteRegistryException && (snapshot?.Paths.Count ?? 0) == 0 &&
            (error is VaultFileException { Kind: VaultFileError.Unavailable } ||
             (OperatingSystem.IsWindows() ? (error.HResult & 0xFFFF) is 21 or 55 or 1117 or 1167 : (error.HResult & 0xFFFF) is 5 or 6 or 19)))
        {
            return [];
        }
    }
}
