namespace CaptureApp.Core;

public sealed class CaptureService(Vault vault, SessionStore sessions, NoteWriter writer, TimeProvider? timeProvider = null, Func<Guid>? makeId = null)
{
    private readonly object gate = new();
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly Func<Guid> createId = makeId ?? Guid.NewGuid;
    private readonly ReservedNotes preparedNoteUrls = new();

    // Use a separate lock so the editor can inspect reservations during a disk save.
    public IReadOnlySet<string> ReservedNoteUrls => preparedNoteUrls.Snapshot;

    public Session RenameSession(SessionCandidate candidate, string newName, Action<SessionRenamePlan>? beforeRename = null,
        Action? beforeReplace = null)
    {
        lock (gate)
        {
            return sessions.RenameAndResume(candidate, newName, beforeRename, beforeReplace);
        }
    }

    private sealed class ReservedNotes
    {
        private readonly object gate = new();
        private readonly HashSet<string> urls = new(StringComparer.OrdinalIgnoreCase);

        internal IReadOnlySet<string> Snapshot
        {
            get { lock (gate) { return new HashSet<string>(urls, StringComparer.OrdinalIgnoreCase); } }
        }

        internal bool Contains(string url) => Match(url, Snapshot) is not null;
        internal void Add(string url) { lock (gate) { urls.Add(url); } }
        internal void Remove(string url) { lock (gate) { urls.Remove(url); } }

        internal static string? Match(string url, IEnumerable<string> reserved)
        {
            var wanted = Path.GetFullPath(url).Normalize();
            return reserved.Order(StringComparer.Ordinal).FirstOrDefault(candidate =>
                string.Equals(Path.GetFullPath(candidate).Normalize(), wanted, StringComparison.OrdinalIgnoreCase));
        }
    }
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

    public PreparedCapture PrepareNote(Capture capture, TimeZoneInfo timeZone, Destination? destination = null, bool newNote = false, bool outsideSession = false, NoteFolder? folder = null)
    {
        lock (gate)
        {
            if (destination is not null)
            {
                return new(capture, destination);
            }

            if (folder is null && !outsideSession && sessions.Current() is { } active)
            {
                return new(capture, Router.Destination(null, active, [], vault));
            }

            if (capture.Content.Kind != CaptureContentKind.Note)
            {
                return Prepare(capture);
            }

            var note = new TypedNote(capture.Content.Value, capture.CreatedAt, timeZone, vault.NamingRules);
            var parsedName = note.PathName ?? throw new NotePathNameException(note.PathNameError ?? NotePathNameError.InvalidComponent);
            var name = folder?.Scoped(parsedName, vault.NamingRules) ?? parsedName;
            var noteCapture = capture with { Content = CaptureContent.Note(note.Body) };
            var appendCapture = string.IsNullOrWhiteSpace(note.Body) ? capture : noteCapture;
            var appendsToMatch = !newNote && !note.IsGeneratedTitle;
            if (appendsToMatch && AppendTarget(note, preparedNoteUrls.Snapshot, vault, folder) is { } target)
            {
                return new(appendCapture, target, NoteMarkerIsIdentity: true);
            }

            var selected = name;
            var location = vault.ResolveNoteName(name);
            if (!appendsToMatch && (File.Exists(location.Url) || Directory.Exists(location.Url) || preparedNoteUrls.Contains(location.Url)))
            {
                var suffix = 2;
                while (true)
                {
                    var candidateName = NumberedName(name, suffix++);
                    var candidate = vault.ResolveNoteName(candidateName);
                    if (!preparedNoteUrls.Contains(candidate.Url) && !File.Exists(candidate.Url) && !Directory.Exists(candidate.Url))
                    {
                        selected = candidateName;
                        location = candidate;
                        break;
                    }
                }
            }

            var destinationNote = new Destination(location.Url, ReferenceEquals(selected, name) ? note.Title : selected.DisplayTitle, NoteKind.Note);
            preparedNoteUrls.Add(destinationNote.Url);
            return new(noteCapture, destinationNote, true, true);
        }
    }

    private NotePathName NumberedName(NotePathName name, int suffix)
    {
        var ending = FormattableString.Invariant($" {suffix}");
        var graphemes = NoteTitle.Graphemes(name.LeafName);
        for (var length = graphemes.Count; length > 0; length--)
        {
            var leaf = string.Concat(graphemes.Take(length)) + ending;
            // FileStem bounds both graphemes and UTF-8 bytes. Shorten the base
            // until the complete suffix survives, rather than retrying the same path.
            if (NoteTitle.FileStem(leaf) != leaf)
            {
                continue;
            }

            var components = name.Components.ToArray();
            components[^1] = leaf;
            try
            {
                return NotePathName.Validated(name.Scope, components, vault.NamingRules);
            }
            catch (NotePathNameException error) when (error.Kind == NotePathNameError.TooLong)
            {
                // A near-limit folder path may require a shorter leaf too.
            }
        }

        throw new NotePathNameException(NotePathNameError.TooLong);
    }

    // The editor and default save use the same exact-path lookup. Display titles
    // and notes in other folders never influence an independent typed save.
    public static Destination? AppendTarget(TypedNote note, IEnumerable<string> reserved, Vault vault, NoteFolder? folder = null)
    {
        if (note.IsGeneratedTitle)
        {
            return null;
        }

        var parsedName = note.PathName ?? throw new NotePathNameException(note.PathNameError ?? NotePathNameError.InvalidComponent);
        var name = folder?.Scoped(parsedName, vault.NamingRules) ?? parsedName;
        if (folder is null && name.Scope == NotePathScope.Vault && name.Components.Count == 1 &&
            NoteTitle.MatchKey(note.Title) == NoteTitle.MatchKey(Vault.InboxTitle))
        {
            return new(vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox);
        }

        var location = vault.ResolveNoteName(name);
        if (File.Exists(location.Url) || Directory.Exists(location.Url))
        {
            return new(location.Url, note.Title, NoteKind.Note);
        }

        var held = ReservedNotes.Match(location.Url, reserved);
        return held is null ? null : new(held, note.Title, NoteKind.Note);
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
