using CaptureApp.Platform.Ocr;
using Xunit;

namespace CaptureApp.Platform.Tests.Ocr;

public sealed class OcrTextLayoutTests
{
    [Fact]
    public void ReadingOrderGroupsRowsThenSortsLeftToRightAndPreservesParagraphGaps()
    {
        OcrLine[] lines =
        [
            new("right top", 0.6, 0.8, 0.9, 0.84, 0.9f),
            new("bottom", 0.1, 0.65, 0.4, 0.69, 0.9f),
            new("left top", 0.1, 0.81, 0.4, 0.85, 0.9f)
        ];

        var ordered = OcrTextLayout.ReadingOrder(lines);

        Assert.Equal(new[] { "left top", "right top", "bottom" }, ordered.Select(line => line.Text));
        Assert.Equal("left top\nright top\n\nbottom", OcrTextLayout.JoinText(ordered));
    }
}
