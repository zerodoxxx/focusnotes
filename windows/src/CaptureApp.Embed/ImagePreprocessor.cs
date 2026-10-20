using System.Text.Json;
using SkiaSharp;

namespace CaptureApp.Embed;

internal sealed class ImagePreprocessor
{
    private static readonly byte[] PngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    public readonly record struct Prepared(float[] Pixels, long[] Positions, int Tokens);

    public int Patch { get; }
    public int Pooling { get; }
    public int Budget { get; }
    private readonly float rescale;

    public ImagePreprocessor(string directory)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, "processor_config.json")));
        int patchSize = 0, poolingSize = 0, softTokens = 0;
        const string Unsupported = "Unsupported image processor configuration";
        if (!document.RootElement.TryGetProperty("image_processor", out var image) || image.ValueKind != JsonValueKind.Object
            || !(image.TryGetProperty("image_processor_type", out var type) && type.ValueKind == JsonValueKind.String && type.GetString() == "Gemma4ImageProcessor")
            || !Flag(image, "do_resize", true) || !(image.TryGetProperty("resample", out var resample) && resample.TryGetInt32(out var resampleValue) && resampleValue == 3)
            || !Flag(image, "do_convert_rgb", true) || !Flag(image, "do_rescale", true) || !Flag(image, "do_normalize", false)
            || !(image.TryGetProperty("patch_size", out var patch) && patch.TryGetInt32(out patchSize) && patchSize == 16)
            || !(image.TryGetProperty("pooling_kernel_size", out var pooling) && pooling.TryGetInt32(out poolingSize) && poolingSize == 3)
            || !(image.TryGetProperty("max_soft_tokens", out var budget) && budget.TryGetInt32(out softTokens) && softTokens is 70 or 140 or 280 or 560 or 1120)
            || !(image.TryGetProperty("rescale_factor", out var factor) && factor.ValueKind == JsonValueKind.Number))
        {
            throw EmbeddingException.Invalid(Unsupported);
        }

        Patch = patchSize;
        Pooling = poolingSize;
        Budget = softTokens;
        rescale = (float)factor.GetDouble();
    }

    private static bool Flag(JsonElement element, string name, bool expected) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == (expected ? JsonValueKind.True : JsonValueKind.False);

    public Prepared Prepare(byte[] data)
    {
        const string Expected = "Expected a PNG image of at most 32 megapixels";
        if (data.Length < PngSignature.Length || !data.AsSpan(0, PngSignature.Length).SequenceEqual(PngSignature))
        {
            throw EmbeddingException.Invalid(Expected);
        }

        using var stream = new SKMemoryStream(data);
        using var codec = SKCodec.Create(stream);
        if (codec is null || codec.EncodedFormat != SKEncodedImageFormat.Png)
        {
            throw EmbeddingException.Invalid(Expected);
        }

        var width = codec.Info.Width;
        var height = codec.Info.Height;
        if (width <= 0 || height <= 0 || width > 16_384 || height > 16_384 || (long)width * height > 32_000_000)
        {
            throw EmbeddingException.Invalid(Expected);
        }

        // Straight (unpremultiplied) RGBA: dropping alpha then matches Pillow's RGB conversion.
        using var bitmap = SKBitmap.Decode(codec, new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Unpremul))
            ?? throw EmbeddingException.Invalid("Could not decode PNG pixels");
        var rgba = bitmap.GetPixelSpan();
        var rowBytes = bitmap.RowBytes;
        var rgb = new byte[width * height * 3];
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var source = y * rowBytes + x * 4;
                var target = (y * width + x) * 3;
                if (rgba[source + 3] == 0)
                {
                    continue;
                }

                rgb[target] = rgba[source];
                rgb[target + 1] = rgba[source + 1];
                rgb[target + 2] = rgba[source + 2];
            }
        }

        var maxPatches = Budget * Pooling * Pooling;
        var side = Patch * Pooling;
        var factor = Math.Sqrt((double)(maxPatches * Patch * Patch) / (width * height));
        var targetH = (int)Math.Floor(height * factor / side) * side;
        var targetW = (int)Math.Floor(width * factor / side) * side;
        if (targetH == 0)
        {
            targetH = side;
            targetW = Math.Min(width / height * side, Budget * side);
        }

        if (targetW == 0)
        {
            targetW = side;
            targetH = Math.Min(height / width * side, Budget * side);
        }

        if (targetH * targetW > maxPatches * Patch * Patch)
        {
            throw EmbeddingException.Invalid("Image patch budget exceeded");
        }

        var resized = Resize(rgb, width, height, targetW, targetH);
        var rows = targetH / Patch;
        var columns = targetW / Patch;
        var pixels = new float[maxPatches * Patch * Patch * 3];
        var positions = new long[maxPatches * 2];
        Array.Fill(positions, -1L);
        for (var y = 0; y < rows; y++)
        {
            for (var x = 0; x < columns; x++)
            {
                var p = y * columns + x;
                positions[2 * p] = x;
                positions[2 * p + 1] = y;
                for (var dy = 0; dy < Patch; dy++)
                {
                    for (var dx = 0; dx < Patch; dx++)
                    {
                        var source = ((y * Patch + dy) * targetW + x * Patch + dx) * 3;
                        var target = (p * Patch * Patch + dy * Patch + dx) * 3;
                        for (var c = 0; c < 3; c++)
                        {
                            pixels[target + c] = resized[source + c] * rescale;
                        }
                    }
                }
            }
        }

        return new Prepared(pixels, positions, rows * columns / (Pooling * Pooling));
    }

    private readonly record struct Coefficients(int Start, long[] Weights);

    // Pillow-compatible separable antialiased bicubic interpolation: half-pixel centers, a=-0.5,
    // widened support for downsampling, 22-bit coefficients, rounding/clamping after each pass.
    private static Coefficients[] ComputeCoefficients(int from, int to)
    {
        var scale = (double)from / to;
        var filterScale = Math.Max(1, scale);
        var support = 2 * filterScale;
        var result = new Coefficients[to];
        for (var i = 0; i < to; i++)
        {
            var center = (i + 0.5) * scale;
            var start = Math.Max(0, (int)(center - support + 0.5));
            var end = Math.Min(from, (int)(center + support + 0.5));
            var raw = new double[Math.Max(0, end - start)];
            for (var j = start; j < end; j++)
            {
                var x = Math.Abs((j - center + 0.5) / filterScale);
                raw[j - start] = x < 1 ? (1.5 * x - 2.5) * x * x + 1 : x < 2 ? (((x - 5) * x + 8) * x - 4) * -0.5 : 0;
            }

            var sum = raw.Sum();
            var weights = new long[raw.Length];
            for (var k = 0; k < raw.Length; k++)
            {
                var value = raw[k] / sum * (1 << 22);
                weights[k] = (long)(value < 0 ? value - 0.5 : value + 0.5);
            }

            result[i] = new Coefficients(start, weights);
        }

        return result;
    }

    private static byte Clamp(long sum) => (byte)Math.Clamp(sum >> 22, 0, 255);

    private static byte[] Resize(byte[] rgb, int width, int height, int targetW, int targetH)
    {
        var intermediate = rgb;
        if (targetW != width)
        {
            var weights = ComputeCoefficients(width, targetW);
            intermediate = new byte[targetW * height * 3];
            for (var y = 0; y < height; y++)
            {
                for (var x = 0; x < targetW; x++)
                {
                    var coefficient = weights[x];
                    for (var c = 0; c < 3; c++)
                    {
                        long sum = 1 << 21;
                        for (var k = 0; k < coefficient.Weights.Length; k++)
                        {
                            sum += rgb[(y * width + coefficient.Start + k) * 3 + c] * coefficient.Weights[k];
                        }

                        intermediate[(y * targetW + x) * 3 + c] = Clamp(sum);
                    }
                }
            }
        }

        if (targetH == height)
        {
            return intermediate;
        }

        var vertical = ComputeCoefficients(height, targetH);
        var result = new byte[targetW * targetH * 3];
        for (var y = 0; y < targetH; y++)
        {
            var coefficient = vertical[y];
            for (var x = 0; x < targetW; x++)
            {
                for (var c = 0; c < 3; c++)
                {
                    long sum = 1 << 21;
                    for (var k = 0; k < coefficient.Weights.Length; k++)
                    {
                        sum += intermediate[((coefficient.Start + k) * targetW + x) * 3 + c] * coefficient.Weights[k];
                    }

                    result[(y * targetW + x) * 3 + c] = Clamp(sum);
                }
            }
        }

        return result;
    }
}
