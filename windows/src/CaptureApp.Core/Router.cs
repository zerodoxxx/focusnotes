namespace CaptureApp.Core;

public static class Router
{
    public static Destination Destination(string? noteTitle, Session? activeSession, IReadOnlyList<NoteRef> notes, Vault vault)
    {
        var cleaned = NoteTitle.CleanTitle(noteTitle ?? "");
        if (cleaned.Length > 0)
        {
            var name = NoteTitle.PathName(cleaned, vault.NamingRules);
            if (name.Scope == NotePathScope.Home || name.Components.Count > 1)
            {
                var location = vault.ResolveNoteName(name);
                var text = vault.NamingRules.WindowsRules ? cleaned.Replace('\\', '/') : cleaned;
                return new(location.Url, NoteTitle.CleanTitle(text.Split('/')[^1]), NoteKind.Note);
            }

            var key = NoteTitle.MatchKey(cleaned);
            var note = notes.FirstOrDefault(n => n.Kind == NoteKind.Note && NoteTitle.MatchKey(n.Title) == key) ?? notes.FirstOrDefault(n => n.Kind == NoteKind.Session && NoteTitle.MatchKey(n.Title) == key);
            if (note is not null)
            {
                return new(note.Url, note.Title, note.Kind);
            }

            if (key == NoteTitle.MatchKey(Vault.InboxTitle))
            {
                return new(vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox);
            }

            return new(vault.ResolveNoteName(name).Url, cleaned, NoteKind.Note);
        }

        return activeSession is not null ? new(vault.ManagedUrl(activeSession.NotePath), activeSession.Name, NoteKind.Session) : new(vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox);
    }
}
