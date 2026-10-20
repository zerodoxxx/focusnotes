using System.Text;
using System.Text.Json;
using Xunit;

namespace CaptureApp.Embed.Tests;

public sealed class ProtocolTests
{
    [Fact]
    public void RequestEncodesSwiftFieldNamesAndOmitsNulls()
    {
        var request = new EmbedRequest { Id = "A1", Operation = "embedDocuments", Texts = ["a", "é"], Title = "T", Dimensions = 128 };
        var line = EmbedProtocol.EncodeLine(request);
        Assert.Equal(10, line[^1]);
        Assert.Equal(1, line.Count(b => b == 10));
        using var json = JsonDocument.Parse(line.AsMemory(0, line.Length - 1));
        var names = json.RootElement.EnumerateObject().Select(p => p.Name).Order().ToArray();
        Assert.Equal(new[] { "dimensions", "id", "operation", "texts", "title" }, names);
        Assert.Equal(128, json.RootElement.GetProperty("dimensions").GetInt32());
        Assert.Equal("é", json.RootElement.GetProperty("texts")[1].GetString());
    }

    [Fact]
    public void DecodesRequestsWrittenByTheSwiftClient()
    {
        var swift = """{"id":"6F2A","operation":"embedImage","imagePNG":"AAEC","dimensions":256}""";
        var request = EmbedProtocol.DecodeLine<EmbedRequest>(Encoding.UTF8.GetBytes(swift));
        Assert.Equal(("6F2A", "embedImage", "AAEC", 256), (request.Id, request.Operation, request.ImagePng, request.Dimensions));
        Assert.Null(request.Text);
        Assert.Null(request.Texts);
    }

    [Fact]
    public void ResponseRoundTripsAndMatchesTheSwiftShape()
    {
        float[] vector = [0.5f, -0.25f, 1f];
        var response = EmbedResponse.Create("X", 256, [vector], processId: 42, visionLoaded: true);
        var decoded = EmbedProtocol.DecodeLine<EmbedResponse>(EmbedProtocol.EncodeLine(response));
        Assert.Equal(("X", Embedder.ModelID, 256, 42, true), (decoded.Id, decoded.ModelId, decoded.Dimensions, decoded.ProcessId, decoded.VisionLoaded));
        Assert.Equal(vector, Float16Vectors.Decode(Convert.FromBase64String(decoded.Vectors!.Single()), 3).Take(3), new FloatComparer());
        using var json = JsonDocument.Parse(EmbedProtocol.EncodeLine(response).AsMemory(0, EmbedProtocol.EncodeLine(response).Length - 1));
        Assert.Equal(
            new[] { "dimensions", "id", "modelID", "processID", "vectors", "visionLoaded" },
            json.RootElement.EnumerateObject().Select(p => p.Name).Order().ToArray());

        var swiftResponse = $$"""{"id":"Y","modelID":"{{Embedder.ModelID}}","dimensions":256,"error":"boom","processID":7,"visionLoaded":false}""";
        var parsed = EmbedProtocol.DecodeLine<EmbedResponse>(Encoding.UTF8.GetBytes(swiftResponse));
        Assert.Equal(("boom", null), (parsed.Error, parsed.Vectors));
    }

    [Fact]
    public void Float16RoundTripAndNormalization()
    {
        var unit = VectorMath.Normalized([3f, 4f]);
        Assert.Equal(0.6f, unit[0], 1e-6f);
        Assert.Equal(0.8f, unit[1], 1e-6f);
        var decoded = Float16Vectors.Decode(Float16Vectors.Encode(unit), 2);
        Assert.Equal(0.6f, decoded[0], 1e-3f);
        Assert.Throws<EmbeddingException>(() => VectorMath.Normalized([0f, 0f]));
        Assert.Throws<EmbeddingException>(() => VectorMath.Normalized([float.NaN]));
        Assert.Throws<EmbeddingException>(() => Float16Vectors.Encode([1e10f]));
        Assert.Throws<EmbeddingException>(() => Float16Vectors.Decode(new byte[3], 2));
        // Little-endian binary16: 1.0 is 0x3C00.
        Assert.Equal(new byte[] { 0x00, 0x3C }, Float16Vectors.Encode([1f]));
    }

    [Fact]
    public void MalformedLineIsATransportError()
    {
        var error = Assert.Throws<EmbeddingException>(() => EmbedProtocol.DecodeLine<EmbedResponse>("{nope"u8));
        Assert.Equal(EmbeddingErrorKind.Transport, error.Kind);
    }

    private sealed class FloatComparer : IEqualityComparer<float>
    {
        public bool Equals(float x, float y) => Math.Abs(x - y) < 2e-3f;

        public int GetHashCode(float value) => 0;
    }
}
