using System.Text.Json;
using System.Text.Json.Serialization;

namespace CaptureApp.Embed;

/// One JSON object per line. All requests and responses carry the same ID. Field names match EmbedProtocol.swift.
public sealed class EmbedRequest
{
    public static readonly int[] SupportedDimensions = [128, 256, 512, 768];

    [JsonPropertyName("id")] public string Id { get; init; } = Guid.NewGuid().ToString().ToUpperInvariant();
    [JsonPropertyName("operation")] public string Operation { get; init; } = "";
    [JsonPropertyName("text")] public string? Text { get; init; }
    [JsonPropertyName("texts")] public List<string>? Texts { get; init; }
    [JsonPropertyName("title")] public string? Title { get; init; }
    [JsonPropertyName("imagePNG")] public string? ImagePng { get; init; }
    [JsonPropertyName("dimensions")] public int Dimensions { get; init; } = 256;
}

public sealed class EmbedResponse
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("modelID")] public string ModelId { get; init; } = Embedder.ModelID;
    [JsonPropertyName("dimensions")] public int Dimensions { get; init; }
    [JsonPropertyName("vectors")] public List<string>? Vectors { get; init; }
    [JsonPropertyName("error")] public string? Error { get; init; }
    [JsonPropertyName("processID")] public int ProcessId { get; init; }
    [JsonPropertyName("visionLoaded")] public bool VisionLoaded { get; init; }

    // Windows background-mode report for the "status" operation; absent from other replies.
    [JsonPropertyName("ecoQoS")] public bool? EcoQos { get; init; }
    [JsonPropertyName("belowNormal")] public bool? BelowNormal { get; init; }
    [JsonPropertyName("backgroundMode")] public bool? BackgroundMode { get; init; }

    public static EmbedResponse Create(string id, int dimensions, IEnumerable<float[]>? vectors = null, string? error = null,
        int? processId = null, bool visionLoaded = false, bool? ecoQos = null, bool? belowNormal = null, bool? backgroundMode = null) => new()
    {
        Id = id,
        Dimensions = dimensions,
        Vectors = vectors?.Select(vector => Convert.ToBase64String(Float16Vectors.Encode(vector))).ToList(),
        Error = error,
        ProcessId = processId ?? Environment.ProcessId,
        VisionLoaded = visionLoaded,
        EcoQos = ecoQos,
        BelowNormal = belowNormal,
        BackgroundMode = backgroundMode
    };
}

public static class EmbedProtocol
{
    public const int MaxLineBytes = 64 * 1024 * 1024;

    private static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    /// UTF-8 JSON followed by a single newline.
    public static byte[] EncodeLine<T>(T value)
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(value, Options);
        var line = new byte[json.Length + 1];
        json.CopyTo(line, 0);
        line[^1] = 10;
        return line;
    }

    public static T DecodeLine<T>(ReadOnlySpan<byte> line)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(line, Options) ?? throw EmbeddingException.Transport("Empty protocol message");
        }
        catch (JsonException error)
        {
            throw EmbeddingException.Transport($"Invalid protocol message: {error.Message}");
        }
    }
}
