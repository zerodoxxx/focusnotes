namespace CaptureApp.Core;

/// An exact note chosen in a picker or Browse; its ID is resolved again when the capture is prepared.
public sealed record NotePick(string NoteId, string Title, NoteKind Kind);

/// Where a capture should go, before <see cref="CaptureService.Resolve"/> turns it into a destination (CaptureIntent.swift).
public abstract record CaptureTarget
{
    private CaptureTarget() { }

    /// The session default, Inbox, or a typed note's own name.
    public sealed record Automatic : CaptureTarget;
    /// A typed title from the picker, routed by <see cref="Router"/>.
    public sealed record Title(string Value) : CaptureTarget;
    /// An exact note that must still exist.
    public sealed record Pick(NotePick Note) : CaptureTarget;
    /// A destination fixed by an earlier resolution, replayed unchanged.
    public sealed record Resolved(Destination Destination) : CaptureTarget;
}

/// A null target is <see cref="CaptureTarget.Automatic"/>. NewNote (Save as New) applies to typed notes only.
public sealed record CaptureIntent(CaptureTarget? Target = null, bool OutsideSession = false, NoteFolder? Folder = null, bool NewNote = false);
