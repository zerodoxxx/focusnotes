using System.Text.Json;
using System.Text.Json.Serialization;

namespace CaptureApp.Core;
/// Codable's tagged union and reference-date representation, used by recovery records.
public sealed class CaptureContentJsonConverter : JsonConverter<CaptureContent>
{
    public override CaptureContent Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var json = JsonDocument.ParseValue(ref reader);
        if (json.RootElement.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("Expected capture content object.");
        }

        var fields = json.RootElement.EnumerateObject().ToArray();
        if (fields.Length != 1)
        {
            throw new JsonException("Expected one capture content case.");
        }

        var field = fields[0];
        var kind = field.Name switch
        {
            "text" => CaptureContentKind.Text,
            "note" => CaptureContentKind.Note,
            "subheading" => CaptureContentKind.Subheading,
            "image" => CaptureContentKind.Image,
            _ => throw new JsonException("Unknown capture content case.")
        };
        if (field.Value.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("Expected capture content arguments.");
        }

        var key = kind == CaptureContentKind.Image ? "assetPath" : "_0";
        if (!field.Value.TryGetProperty(key, out var value) || value.ValueKind != JsonValueKind.String)
        {
            throw new JsonException("Missing capture content value.");
        }

        return new(kind, value.GetString()!);
    }

    public override void Write(Utf8JsonWriter writer, CaptureContent value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WritePropertyName(value.Kind.ToString().ToLowerInvariant());
        writer.WriteStartObject();
        writer.WriteString(value.Kind == CaptureContentKind.Image ? "assetPath" : "_0", value.Value);
        writer.WriteEndObject();
        writer.WriteEndObject();
    }
}

public sealed class NoteKindJsonConverter : JsonConverter<NoteKind>
{
    public override NoteKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var json = JsonDocument.ParseValue(ref reader);
        if (json.RootElement.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("Expected note kind object.");
        }

        var fields = json.RootElement.EnumerateObject().ToArray();
        if (fields.Length != 1 || fields[0].Value.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("Expected note kind case.");
        }

        return fields[0].Name switch
        {
            "inbox" => NoteKind.Inbox,
            "session" => NoteKind.Session,
            "note" => NoteKind.Note,
            _ => throw new JsonException("Unknown note kind.")
        };
    }

    public override void Write(Utf8JsonWriter writer, NoteKind value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WritePropertyName(value.ToString().ToLowerInvariant());
        writer.WriteStartObject();
        writer.WriteEndObject();
        writer.WriteEndObject();
    }
}

public sealed class CaptureDateJsonConverter : JsonConverter<DateTimeOffset>
{
    private static readonly DateTimeOffset Epoch = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => Epoch.AddSeconds(reader.GetDouble());
    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) => writer.WriteNumberValue((value - Epoch).TotalSeconds);
}

public sealed class CaptureIdJsonConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => Guid.TryParseExact(reader.GetString(), "D", out var value) ? value : throw new JsonException("Invalid capture UUID.");
    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) => writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

public sealed class FileUrlJsonConverter : JsonConverter<string>
{
    public override string Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var text = reader.GetString() ?? throw new JsonException("Null file URL.");
        try
        {
            return Vault.DecodeFilePath(text);
        }
        catch (IOException error)
        {
            throw new JsonException("Invalid file URL.", error);
        }
    }

    public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions options) => writer.WriteStringValue(new Uri(Path.GetFullPath(value)).AbsoluteUri);
}
