using CaptureApp.Platform.Capture;
using Xunit;

namespace CaptureApp.Platform.Tests.Capture;

public sealed class RegionGeometryTests
{
    [Theory]
    [InlineData(100, 100, -1920, 0, 250, 120, -1670, 120)]
    [InlineData(150, 150, 1920, -300, 250, 120, 2295, -120)]
    [InlineData(200, 200, -640, 1440, 250, 120, -140, 1680)]
    public void DipAndPixelCoordinatesRoundTripAtMixedDpi(int dpiX, int dpiY, int monitorX, int monitorY,
        int dipX, int dipY, int expectedPixelX, int expectedPixelY)
    {
        var monitor = new MonitorGeometry(new PixelRect(monitorX, monitorY, 1600, 1200), dpiX / 100.0,
            dpiY / 100.0);

        var pixel = RegionGeometry.DipToPixel(new DipPoint(dipX, dipY), monitor);
        var dip = RegionGeometry.PixelToDip(pixel, monitor);

        Assert.Equal(expectedPixelX, pixel.X);
        Assert.Equal(expectedPixelY, pixel.Y);
        Assert.Equal(dipX, dip.X, precision: 6);
        Assert.Equal(dipY, dip.Y, precision: 6);
    }

    [Theory]
    [InlineData(40, 80, 10, 20, 10, 20, 30, 60)]
    [InlineData(10, 20, 40, 80, 10, 20, 30, 60)]
    [InlineData(-100, 400, 300, -200, -100, -200, 400, 600)]
    public void NormalizeSupportsAnyDragDirection(int firstX, int firstY, int secondX, int secondY,
        int expectedX, int expectedY, int expectedWidth, int expectedHeight)
    {
        Assert.Equal(new PixelRect(expectedX, expectedY, expectedWidth, expectedHeight),
            RegionGeometry.Normalize(new PixelPoint(firstX, firstY), new PixelPoint(secondX, secondY)));
    }

    [Fact]
    public void CropCopiesClippedBgraRowsFromTheFrozenDesktop()
    {
        byte[] pixels =
        [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
            12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
            24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35
        ];

        var cropped = RegionGeometry.CropBgra(pixels, imageWidth: 3, imageHeight: 3,
            crop: new PixelRect(1, 1, 5, 5));

        Assert.Equal(new byte[] { 16, 17, 18, 19, 20, 21, 22, 23, 28, 29, 30, 31, 32, 33, 34, 35 },
            cropped);
    }
}
