using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CaptureApp.Core;

/// A literal vault-relative folder. Validation never silently changes a folder's identity.
[JsonConverter(typeof(NoteFolderJsonConverter))]
public sealed record NoteFolder
{
    public string RawValue { get; }
    public IReadOnlyList<string> Components => RawValue.Split('/');

    public NoteFolder(string rawValue)
    {
        if (string.IsNullOrEmpty(rawValue)) throw new NotePathNameException(NotePathNameError.EmptyPath);
        var parts = rawValue.Split('/');
        if (parts.Length > NotePathName.MaximumPathDepth - 2) throw new NotePathNameException(NotePathNameError.TooDeep);
        if (Encoding.UTF8.GetByteCount(rawValue) > NotePathName.MaximumRelativePathBytes - 240)
            throw new NotePathNameException(NotePathNameError.TooLong);
        if (parts.Any(p => p.Length == 0 || p.StartsWith('.') || p.StartsWith('~') ||
            p != NoteTitle.FileStem(p) || p != NoteTitle.CleanTitle(p)))
            throw new NotePathNameException(NotePathNameError.InvalidComponent);
        _ = NotePathName.Validated(NotePathScope.Vault, parts, new() { WindowsRules = true });
        RawValue = rawValue;
    }

    public NotePathName Scoped(NotePathName name, VaultNamingRules? rules = null)
    {
        if (name.Scope != NotePathScope.Vault) throw new NotePathNameException(NotePathNameError.InvalidComponent);
        return NotePathName.Validated(NotePathScope.Vault, Components.Concat(name.Components), rules);
    }
}

public sealed class NoteFolderJsonConverter : JsonConverter<NoteFolder>
{
    public override NoteFolder Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var json = JsonDocument.ParseValue(ref reader);
        if (json.RootElement.ValueKind != JsonValueKind.Object ||
            !json.RootElement.TryGetProperty("rawValue", out var raw) || raw.ValueKind != JsonValueKind.String)
            throw new JsonException("Folder must contain a relative rawValue.");
        try { return new(raw.GetString()!); }
        catch (NotePathNameException error) { throw new JsonException("Unsafe folder.", error); }
    }

    public override void Write(Utf8JsonWriter writer, NoteFolder value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("rawValue", value.RawValue);
        writer.WriteEndObject();
    }
}
