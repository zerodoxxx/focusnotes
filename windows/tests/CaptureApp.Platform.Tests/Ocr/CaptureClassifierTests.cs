using CaptureApp.Platform.Ocr;
using Xunit;

namespace CaptureApp.Platform.Tests.Ocr;

public sealed class CaptureClassifierTests
{
    [Fact]
    public void FourConfidentLinesAtTwelvePercentCoverageAreText()
    {
        var lines = Enumerable.Range(0, 4)
            .Select(index => new OcrLine("line", 0, index * 0.2, 0.6, index * 0.2 + 0.05, 0.75f))
            .ToArray();

        var result = CaptureClassifier.Classify(lines, 1920, 1080);

        Assert.Equal(0.12, result.Metrics.TextCoverage, precision: 6);
        Assert.Equal(CaptureDecision.Text, result.Decision);
        Assert.Equal(4, result.Metrics.LineCount);
    }

    [Fact]
    public void ProseRequiresTheCoverageConfidenceAndLineThresholds()
    {
        var lowCoverage = Enumerable.Range(0, 4)
            .Select(index => new OcrLine("line", 0, index * 0.2, 0.59, index * 0.2 + 0.05, 0.9f))
            .ToArray();
        var goodCoverage = lowCoverage.Select(line => line with { MaxX = 0.8 }).ToArray();
        var lowConfidence = goodCoverage.Select(line => line with { Confidence = 0.749f }).ToArray();
        var threeLines = goodCoverage.Take(3).ToArray();

        Assert.Equal(CaptureDecision.Image, CaptureClassifier.Classify(lowCoverage, 100, 100).Decision);
        Assert.Equal(CaptureDecision.Image, CaptureClassifier.Classify(lowConfidence, 100, 100).Decision);
        Assert.Equal(CaptureDecision.Image, CaptureClassifier.Classify(threeLines, 100, 100).Decision);
    }

    [Fact]
    public void DenseOneLineCropCanBeTextAtTwentyFivePercentCoverage()
    {
        var line = new OcrLine("heading", 0.25, 0.25, 0.75, 0.75, 0.75f);

        var result = CaptureClassifier.Classify([line], 800, 600);

        Assert.Equal(0.25, result.Metrics.TextCoverage, precision: 6);
        Assert.Equal(CaptureDecision.Text, result.Decision);
    }

    [Fact]
    public void EmptyLinesProduceImageDecisionAndZeroCoverage()
    {
        var result = CaptureClassifier.Classify([], 10, 10);

        Assert.Equal(CaptureDecision.Image, result.Decision);
        Assert.Equal(0, result.Metrics.TextCoverage);
        Assert.Equal(0, result.Metrics.MeanConfidence);
        Assert.Equal(0, result.Metrics.LineCount);
    }
}
