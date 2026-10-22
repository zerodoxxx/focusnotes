using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.AppCore;

/// Per-editor destination and pin intent, independent of the WPF editor surface.
public sealed class QuickNoteState
{
    public Destination? Destination { get; set; }
    public NoteFolder? Folder { get; }
    public string? DestinationLabel => Destination?.Title ?? (Folder is { } folder ? "Folder: " + folder.RawValue : null);
    public bool OutsideSession { get; private set; }
    public bool PinOnSave { get; private set; }
    public IReadOnlyList<NoteSuggestion> Suggestions { get; set; } = [];

    public IReadOnlyDictionary<string, NoteKind> Kinds
    {
        get
        {
            var kinds = new Dictionary<string, NoteKind>(StringComparer.Ordinal);
            foreach (var suggestion in Suggestions)
            {
                kinds.TryAdd(suggestion.Path, suggestion.Kind);
            }

            return kinds;
        }
    }

    public QuickNoteState(Destination? destination, bool pinOnSave = false, NoteFolder? folder = null)
    {
        Destination = destination;
        Folder = folder;
        OutsideSession = folder is not null;
        PinOnSave = destination is null && pinOnSave;
    }

    public bool TogglePinOnSave(NoteDraftStore drafts)
    {
        drafts.SetPinOnSave(!PinOnSave);
        PinOnSave = !PinOnSave;
        return PinOnSave;
    }

    public void ResetPinOnSave(NoteDraftStore drafts)
    {
        drafts.SetPinOnSave(false);
        PinOnSave = false;
    }

    public void ToggleOutsideSession(Destination? sessionDestination)
    {
        if (sessionDestination is null) return;
        OutsideSession = !OutsideSession;
        Destination = OutsideSession ? null : sessionDestination;
    }

    public void ReturnToSession(Destination? sessionDestination)
    {
        OutsideSession = Folder is not null;
        Destination = Folder is null ? sessionDestination : null;
    }
}
