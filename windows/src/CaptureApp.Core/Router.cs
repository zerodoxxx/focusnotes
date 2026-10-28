namespace CaptureApp.Core;

/// Thrown when a bare title matches more than one note in the same tier; the candidates are sorted by path.
public sealed class RouterAmbiguousException(IReadOnlyList<Destination> candidates) : Exception("Several notes match this title.")
{
    public IReadOnlyList<Destination> Candidates { get; } = candidates;
}

public static class Router
{
    /// Picks the note a capture goes to (Router.swift).
    /// 1. A non-empty title matches root-note headings, then session headings, then Inbox, else creates a new root note.
    ///    Nested and HOME notes need an explicit path; ambiguous headings throw <see cref="RouterAmbiguousException"/>.
    /// 2. Otherwise the active session's note.
    /// 3. Otherwise Inbox.md.
    public static Destination Destination(string? noteTitle, Session? activeSession, IReadOnlyList<NoteRef> notes, Vault vault)
    {
        var cleaned = NoteTitle.CleanTitle(noteTitle ?? "");
        if (cleaned.Length > 0)
        {
            var name = ResolvedPathName(noteTitle ?? "", vault.NamingRules);
            if (name.Scope == NotePathScope.Home || name.Components.Count > 1)
            {
                var location = vault.ResolveNoteName(name);
                var text = vault.NamingRules.WindowsRules ? cleaned.Replace('\\', '/') : cleaned;
                return new(location.Url, NoteTitle.CleanTitle(text.Split('/')[^1]), NoteKind.Note);
            }

            var key = NoteTitle.MatchKey(cleaned);
            if (Unique(notes.Where(n => n.Kind == NoteKind.Note && IsRootNote(n, vault) && NoteTitle.MatchKey(n.Title) == key), NoteKind.Note) is { } rootNote)
            {
                return rootNote;
            }

            if (Unique(notes.Where(n => n.Kind == NoteKind.Session && NoteTitle.MatchKey(n.Title) == key), NoteKind.Session) is { } session)
            {
                return session;
            }

            if (key == NoteTitle.MatchKey(Vault.InboxTitle))
            {
                return new(vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox);
            }

            return new(vault.ResolveNoteName(name).Url, cleaned, NoteKind.Note);
        }

        return activeSession is not null ? new(vault.ManagedUrl(activeSession.NotePath), activeSession.Name, NoteKind.Session) : new(vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox);
    }

    /// Whether a title is matched against note headings rather than read as a path to a nested or HOME note.
    public static bool IsHeadingTitle(string title, VaultNamingRules rules)
    {
        try
        {
            var name = ResolvedPathName(title, rules);
            return name.Scope == NotePathScope.Vault && name.Components.Count == 1;
        }
        catch (NotePathNameException)
        {
            return false;
        }
    }

    private static bool IsRootNote(NoteRef note, Vault vault) => Vault.RelativeUnder(note.Url, vault.Root) is { } relative && !relative.Contains('/');

    private static Destination? Unique(IEnumerable<NoteRef> matches, NoteKind kind)
    {
        var candidates = matches.Select(n => new Destination(n.Url, n.Title, kind)).OrderBy(d => d.Url, StringComparer.Ordinal).ToArray();
        return candidates.Length switch
        {
            0 => null,
            1 => candidates[0],
            _ => throw new RouterAmbiguousException(candidates)
        };
    }

    // NoteTitle.resolvedPathName: malformed or whitespace-qualified relative slash forms keep the flat file name.
    private static NotePathName ResolvedPathName(string rawName, VaultNamingRules rules)
    {
        var input = rules.WindowsRules ? rawName.Replace('\\', '/') : rawName;
        NotePathName? parsed = null;
        NotePathNameError? error = null;
        try
        {
            parsed = NoteTitle.PathName(rawName, rules);
        }
        catch (NotePathNameException failure)
        {
            error = failure.Kind;
        }

        if (!NoteTitle.CanFallBackToFlatName(input, error))
        {
            return parsed ?? throw new NotePathNameException(error!.Value);
        }

        return NotePathName.Validated(NotePathScope.Vault, [rules.FileStem(NoteTitle.CleanTitle(input))], rules);
    }
}
