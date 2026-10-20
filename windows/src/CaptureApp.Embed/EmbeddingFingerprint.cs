using System.Security.Cryptography;
using System.Text;

namespace CaptureApp.Embed;

public static class EmbeddingFingerprint
{
    /// Hash the exact prompt plus title/body (or OCR) sent to the tokenizer.
    public static string Document(string text, string? title) => Digest(EmbeddingKind.Document(title).Input(text));

    /// Metadata avoids reading all image bytes on every reconciliation. Includes the resolved path so
    /// moving to a different asset also changes the input.
    public static string Image(string path, long size, DateTimeOffset modifiedAt)
    {
        var seconds = (double)(modifiedAt.UtcTicks - DateTimeOffset.UnixEpoch.UtcTicks) / TimeSpan.TicksPerSecond;
        return Digest($"{path}\0{size}\0{BitConverter.DoubleToUInt64Bits(seconds)}");
    }

    private static string Digest(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
}
