namespace CaptureApp.Embed;

public enum EmbeddingErrorKind
{
    Invalid,
    Runtime,
    Database,
    Transport
}

public sealed class EmbeddingException(EmbeddingErrorKind kind, string message) : Exception(message)
{
    public EmbeddingErrorKind Kind { get; } = kind;

    public static EmbeddingException Invalid(string message) => new(EmbeddingErrorKind.Invalid, message);
    public static EmbeddingException Runtime(string message) => new(EmbeddingErrorKind.Runtime, message);
    public static EmbeddingException Database(string message) => new(EmbeddingErrorKind.Database, message);
    public static EmbeddingException Transport(string message) => new(EmbeddingErrorKind.Transport, message);
}

public static class VectorMath
{
    /// Scales by the peak first so tiny or huge vectors keep precision, then to unit length.
    public static float[] Normalized(ReadOnlySpan<float> vector)
    {
        if (vector.IsEmpty)
        {
            throw EmbeddingException.Invalid("Vector must be nonempty and finite");
        }

        var peak = 0f;
        foreach (var value in vector)
        {
            if (!float.IsFinite(value))
            {
                throw EmbeddingException.Invalid("Vector must be nonempty and finite");
            }

            peak = Math.Max(peak, Math.Abs(value));
        }

        if (peak <= 0)
        {
            throw EmbeddingException.Invalid("Zero vector");
        }

        var scaled = new float[vector.Length];
        var norm = 0f;
        for (var i = 0; i < vector.Length; i++)
        {
            scaled[i] = vector[i] / peak;
            norm += scaled[i] * scaled[i];
        }

        var scale = 1 / MathF.Sqrt(norm);
        for (var i = 0; i < scaled.Length; i++)
        {
            scaled[i] *= scale;
        }

        return scaled;
    }
}

/// Portable little-endian Float16 representation used by both SQLite and IPC.
public static class Float16Vectors
{
    public static byte[] Encode(ReadOnlySpan<float> vector)
    {
        var data = new byte[vector.Length * 2];
        for (var i = 0; i < vector.Length; i++)
        {
            var half = (Half)vector[i];
            if (!float.IsFinite(vector[i]) || !Half.IsFinite(half))
            {
                throw EmbeddingException.Invalid("Vector cannot be represented as finite Float16");
            }

            var bits = BitConverter.HalfToUInt16Bits(half);
            data[2 * i] = (byte)bits;
            data[2 * i + 1] = (byte)(bits >> 8);
        }

        return data;
    }

    public static float[] Decode(ReadOnlySpan<byte> data, int dimensions)
    {
        if (dimensions <= 0 || dimensions > 768 || data.Length != dimensions * 2)
        {
            throw EmbeddingException.Invalid("Invalid Float16 vector length");
        }

        var values = new float[dimensions];
        for (var i = 0; i < dimensions; i++)
        {
            var bits = (ushort)(data[2 * i] | data[2 * i + 1] << 8);
            values[i] = (float)BitConverter.UInt16BitsToHalf(bits);
            if (!float.IsFinite(values[i]))
            {
                throw EmbeddingException.Invalid("Non-finite Float16 vector");
            }
        }

        return values;
    }
}
