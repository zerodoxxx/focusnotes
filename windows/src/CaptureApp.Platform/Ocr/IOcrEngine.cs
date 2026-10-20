using SkiaSharp;

namespace CaptureApp.Platform.Ocr;

public interface IOcrEngine
{
    OcrResult Recognize(byte[] png, CancellationToken cancellationToken = default);
    OcrResult Recognize(SKBitmap bitmap, CancellationToken cancellationToken = default);
}

public sealed record OcrResult(string Text, IReadOnlyList<OcrLine> Lines, double Coverage, int ImageWidth,
    int ImageHeight);

/// <summary>Normalized Vision-compatible bounds, with the origin at the bottom left.</summary>
public sealed record OcrLine(string Text, double MinX, double MinY, double MaxX, double MaxY, float Confidence)
{
    public double MidY => (MinY + MaxY) / 2.0;
    public double Height => MaxY - MinY;
}

public sealed class OcrModelsMissingException(string message) : InvalidOperationException(message);
