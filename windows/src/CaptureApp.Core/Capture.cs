using System.Text.Json.Serialization;

namespace CaptureApp.Core;

public sealed record CaptureSource([property: JsonPropertyName("appName"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? AppName = null, [property: JsonPropertyName("windowTitle"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? WindowTitle = null, [property: JsonPropertyName("url"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Url = null);
public enum CaptureContentKind
{
    Text,
    Subheading,
    Note,
    Image
}

[JsonConverter(typeof(CaptureContentJsonConverter))]
public sealed record CaptureContent(CaptureContentKind Kind, string Value)
{
    public static CaptureContent Text(string text) => new(CaptureContentKind.Text, text);
    public static CaptureContent Subheading(string text) => new(CaptureContentKind.Subheading, text);
    public static CaptureContent Note(string text) => new(CaptureContentKind.Note, text);
    public static CaptureContent Image(string assetPath) => new(CaptureContentKind.Image, assetPath);
}

public sealed record Capture([property: JsonPropertyName("id"), JsonConverter(typeof(CaptureIdJsonConverter))] Guid Id, [property: JsonPropertyName("createdAt"), JsonConverter(typeof(CaptureDateJsonConverter))] DateTimeOffset CreatedAt, [property: JsonPropertyName("content")] CaptureContent Content, [property: JsonPropertyName("source")] CaptureSource Source);
[JsonConverter(typeof(NoteKindJsonConverter))]
public enum NoteKind
{
    Inbox,
    Session,
    Note
}

public sealed record NoteRef(string Url, string Title, NoteKind Kind);
public sealed record Destination([property: JsonPropertyName("url"), JsonConverter(typeof(FileUrlJsonConverter))] string Url, [property: JsonPropertyName("title")] string Title, [property: JsonPropertyName("kind")] NoteKind Kind);
public sealed record SavedCapture(Guid CaptureId, Destination Destination);
public sealed record PreparedCapture([property: JsonPropertyName("capture")] Capture Capture, [property: JsonPropertyName("destination")] Destination Destination, [property: JsonPropertyName("createsNote"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? CreatesNote = null, [property: JsonPropertyName("noteMarkerIsIdentity"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] bool? NoteMarkerIsIdentity = null);
