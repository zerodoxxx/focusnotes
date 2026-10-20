namespace CaptureApp.Platform.Ocr;

public enum CaptureDecision
{
    Text,
    Image
}

public readonly record struct CaptureMetrics(double TextCoverage, float MeanConfidence, int LineCount);

public sealed record CaptureClassification(CaptureDecision Decision, CaptureMetrics Metrics);

/// <summary>Geometry-based capture classification ported from CaptureKit/CaptureClassifier.swift.</summary>
public static class CaptureClassifier
{
    public const double MinimumTextCoverage = 0.12;
    public const float MinimumMeanConfidence = 0.75f;
    public const int MinimumLineCount = 4;
    public const double DenseCropCoverage = 0.25;

    public static CaptureClassification Classify(OcrResult result) =>
        Classify(result.Lines, result.ImageWidth, result.ImageHeight);

    public static CaptureClassification Classify(IReadOnlyCollection<OcrLine> lines, int imageWidth, int imageHeight)
    {
        var imageArea = (double)imageWidth * imageHeight;
        var usable = lines.Where(line => !string.IsNullOrWhiteSpace(line.Text)).ToArray();
        var coverage = 0.0;
        foreach (var line in usable)
        {
            var width = Math.Min(1.0, line.MaxX) - Math.Max(0.0, line.MinX);
            var height = Math.Min(1.0, line.MaxY) - Math.Max(0.0, line.MinY);
            if (width > 0 && height > 0)
            {
                coverage += width * height;
            }
        }

        if (!double.IsFinite(imageArea) || imageArea <= 0)
        {
            coverage = 0;
        }

        var meanConfidence = usable.Length == 0 ? 0 : usable.Average(line => line.Confidence);
        var isProse = coverage >= MinimumTextCoverage && usable.Length >= MinimumLineCount;
        var isDenseCrop = coverage >= DenseCropCoverage && usable.Length > 0;
        var decision = meanConfidence >= MinimumMeanConfidence && (isProse || isDenseCrop)
            ? CaptureDecision.Text
            : CaptureDecision.Image;
        return new CaptureClassification(decision, new CaptureMetrics(coverage, meanConfidence, usable.Length));
    }
}
