using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace CaptureApp.Embed;

public readonly record struct EmbeddingKind(bool IsQuery, string? Title)
{
    public static EmbeddingKind Query => new(true, null);

    public static EmbeddingKind Document(string? title) => new(false, title);

    public string Input(string text) => IsQuery ? "task: search result | query: " + text : $"title: {Title ?? "none"} | text: " + text;
}

/// Synchronous inference intended for EmbedHelper. Construction is cheap; the tokenizer and sessions
/// are created on the first actual request. Calls are serialized by a lock, including lazy initialization.
public sealed class Embedder : IDisposable
{
    public const string ModelID = "onnx-community/embeddinggemma-2-ONNX@daa72c51243991dfcaf9f9137d2c573d8f7790c0:text-q8,vision-q4";

    private readonly object gate = new();
    private readonly string directory;
    private Tokenizer? tokenizer;
    private InferenceSession? text;
    private InferenceSession? vision;
    private ImagePreprocessor? processor;

    public Embedder(string modelsDirectory, int dimensions = 256)
    {
        if (!EmbedRequest.SupportedDimensions.Contains(dimensions))
        {
            throw EmbeddingException.Invalid("Dimensions must be 128, 256, 512 or 768");
        }

        directory = modelsDirectory;
        Dimensions = dimensions;
    }

    public int Dimensions { get; }

    public bool VisionLoaded
    {
        get { lock (gate) return vision is not null; }
    }

    public IReadOnlyList<float[]> Embed(IReadOnlyList<string> texts, EmbeddingKind kind)
    {
        lock (gate)
        {
            if (texts.Count == 0)
            {
                return [];
            }

            LoadText();
            // Per-item inference avoids quadratic work from padding unrelated document lengths.
            var vectors = new List<float[]>(texts.Count);
            foreach (var input in texts)
            {
                var ids = tokenizer!.Encode(kind.Input(input), 2048);
                if (ids.Contains(258880) || ids.Contains(258881) || ids.Contains(258884))
                {
                    throw EmbeddingException.Invalid("Text contains a media placeholder; use the image path for images");
                }

                vectors.Add(Shared(ids, null));
            }

            return vectors;
        }
    }

    public float[] Embed(byte[] imagePng)
    {
        lock (gate)
        {
            LoadText();
            processor ??= new ImagePreprocessor(directory);
            var prepared = processor.Prepare(imagePng);
            vision ??= CreateSession(Path.Combine(directory, "onnx", "vision_encoder_q4.onnx"));
            var patches = processor.Budget * processor.Pooling * processor.Pooling;
            using var pixels = Tensor(prepared.Pixels, [1, patches, 768]);
            using var positions = Tensor(prepared.Positions, [1, patches, 2]);
            using var features = Run(vision, [("pixel_values", pixels), ("pixel_position_ids", positions)], "image_features");
            if (features.GetTensorTypeAndShape().ElementCount != prepared.Tokens * 512L)
            {
                throw EmbeddingException.Runtime("Vision feature count does not match image token count");
            }

            var ids = new long[prepared.Tokens + 4];
            ids[0] = 2;
            ids[1] = 255999;
            Array.Fill(ids, 258880L, 2, prepared.Tokens);
            ids[^2] = 258882;
            ids[^1] = 1;
            return Shared(ids, features);
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            text?.Dispose();
            vision?.Dispose();
            text = null;
            vision = null;
        }
    }

    private void LoadText()
    {
        text ??= CreateSession(Path.Combine(directory, "onnx", "model_quantized.onnx"));
        tokenizer ??= new Tokenizer(Path.Combine(directory, "tokenizer.json"));
    }

    private static InferenceSession CreateSession(string model)
    {
        try
        {
            OrtEnv.Instance().DisableTelemetryEvents();
            using var options = new SessionOptions
            {
                IntraOpNumThreads = 4,
                InterOpNumThreads = 1,
                GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL
            };
            // Avoid spinning worker threads between requests.
            options.AddSessionConfigEntry("session.intra_op.allow_spinning", "0");
            return new InferenceSession(model, options);
        }
        catch (OnnxRuntimeException error)
        {
            throw EmbeddingException.Runtime(error.Message);
        }
    }

    private static OrtValue Tensor<T>(T[] values, long[] shape) where T : unmanaged
    {
        var value = OrtValue.CreateAllocatedTensorValue(OrtAllocator.DefaultInstance, TensorElementTypeOf<T>(), shape);
        values.AsSpan().CopyTo(value.GetTensorMutableDataAsSpan<T>());
        return value;
    }

    private static TensorElementType TensorElementTypeOf<T>() =>
        typeof(T) == typeof(float) ? TensorElementType.Float
        : typeof(T) == typeof(long) ? TensorElementType.Int64
        : throw new NotSupportedException();

    private static OrtValue Run(InferenceSession session, (string Name, OrtValue Value)[] inputs, string output)
    {
        try
        {
            using var options = new RunOptions();
            using var results = session.Run(options, inputs.Select(i => i.Name).ToArray(), inputs.Select(i => i.Value).ToArray(), [output]);
            // The collection owns its values; detach the one we return by copying it to an independent tensor.
            var result = results[0];
            var info = result.GetTensorTypeAndShape();
            var copy = OrtValue.CreateAllocatedTensorValue(OrtAllocator.DefaultInstance, info.ElementDataType, info.Shape);
            result.GetTensorDataAsSpan<float>().CopyTo(copy.GetTensorMutableDataAsSpan<float>());
            return copy;
        }
        catch (OnnxRuntimeException error)
        {
            throw EmbeddingException.Runtime(error.Message);
        }
    }

    private float[] Shared(long[] ids, OrtValue? imageFeatures)
    {
        var mask = new long[ids.Length];
        Array.Fill(mask, 1L);
        using var tokenTensor = Tensor(ids, [1, ids.Length]);
        using var maskTensor = Tensor(mask, [1, ids.Length]);
        using var empty = Tensor(Array.Empty<float>(), [0, 512]);
        using var video = Tensor(Array.Empty<float>(), [0, 512]);
        using var audio = Tensor(Array.Empty<float>(), [0, 512]);
        using var output = Run(text!, [("input_ids", tokenTensor), ("attention_mask", maskTensor), ("image_features", imageFeatures ?? empty),
            ("video_features", video), ("audio_features", audio)], "sentence_embedding");
        var vector = output.GetTensorDataAsSpan<float>();
        if (vector.Length != 768)
        {
            throw EmbeddingException.Runtime("Expected 768-d shared embedding");
        }

        var full = VectorMath.Normalized(vector);
        return VectorMath.Normalized(full.AsSpan(0, Dimensions));
    }
}
