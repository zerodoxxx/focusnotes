using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CaptureApp.Platform.Capture;
using WpfImage = System.Windows.Controls.Image;
using WpfRect = System.Windows.Rect;
using WpfSize = System.Windows.Size;
using Xunit;

namespace CaptureApp.Platform.Tests.Capture;

[Collection("CaptureOverlay")]
public sealed class RegionOverlayLayoutTests
{
    [Theory]
    [InlineData(1.0)]
    [InlineData(1.5)]
    [InlineData(2.0)]
    public void OverlayImagesFillTheMonitorDipBounds(double dpiScale)
    {
        var imageSize = RunOnSta(() => MeasureOverlayImages(dpiScale));
        var expectedWidth = 300 / dpiScale;
        var expectedHeight = 150 / dpiScale;

        Assert.Equal(2, imageSize.Length);
        Assert.All(imageSize, size =>
        {
            Assert.Equal(expectedWidth, size.Width);
            Assert.Equal(expectedHeight, size.Height);
        });
    }

    [Theory]
    [InlineData(1.0)]
    [InlineData(1.5)]
    [InlineData(2.0)]
    public void OverlayStartsDimmedBeforeASelection(double dpiScale)
    {
        var pixel = RunOnSta(() =>
        {
            var pixels = new byte[300 * 150 * 4];
            for (var offset = 0; offset < pixels.Length; offset += 4)
            {
                pixels[offset + 2] = 255;
                pixels[offset + 3] = 255;
            }
            var window = CreateOverlay(dpiScale, pixels);
            try
            {
                var content = (UIElement)window.Content;
                content.Measure(new WpfSize(window.Width, window.Height));
                content.Arrange(new WpfRect(0, 0, window.Width, window.Height));
                var bitmap = new RenderTargetBitmap(300, 150, dpiScale * 96, dpiScale * 96, PixelFormats.Pbgra32);
                bitmap.Render(content);
                var center = new byte[4];
                bitmap.CopyPixels(new Int32Rect(150, 75, 1, 1), center, 4, 0);
                return center;
            }
            finally { window.Close(); }
        });

        Assert.Equal(0, pixel[0]);
        Assert.Equal(0, pixel[1]);
        Assert.InRange(pixel[2], (byte)136, (byte)138);
        Assert.Equal(255, pixel[3]);
    }

    private static (double Width, double Height)[] MeasureOverlayImages(double dpiScale)
    {
        // Measure the production tree: Canvas does not constrain its child to the monitor bounds.
        var window = CreateOverlay(dpiScale);
        try
        {
            var content = (UIElement)window.Content;
            content.Measure(new WpfSize(window.Width, window.Height));
            content.Arrange(new WpfRect(0, 0, window.Width, window.Height));

            var images = new List<WpfImage>();
            CollectImages(content, images);
            return images.Select(image => (image.RenderSize.Width, image.RenderSize.Height)).ToArray();
        }
        finally
        {
            window.Close();
        }
    }

    private static Window CreateOverlay(double dpiScale, byte[]? pixels = null)
    {
        const int pixelWidth = 300;
        const int pixelHeight = 150;
        var monitor = new MonitorGeometry(new PixelRect(0, 0, pixelWidth, pixelHeight), dpiScale);
        pixels ??= new byte[pixelWidth * pixelHeight * 4];
        var source = BitmapSource.Create(pixelWidth, pixelHeight, 96, 96, PixelFormats.Bgra32, null, pixels,
            pixelWidth * 4);
        source.Freeze();

        var overlayType = typeof(RegionCapturer).GetNestedType("MonitorOverlayWindow", BindingFlags.NonPublic)
                         ?? throw new InvalidOperationException("The production overlay window was not found.");
        var constructor = overlayType.GetConstructors(BindingFlags.Instance | BindingFlags.Public
                                                      | BindingFlags.NonPublic).Single();
        return (Window)constructor.Invoke([monitor, source, null]);
    }

    private static void CollectImages(DependencyObject root, List<WpfImage> images)
    {
        if (root is WpfImage image)
        {
            images.Add(image);
        }

        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            CollectImages(VisualTreeHelper.GetChild(root, index), images);
        }
    }

    private static T RunOnSta<T>(Func<T> action)
    {
        T? result = default;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                result = action();
            }
            catch (Exception exception)
            {
                failure = exception;
            }
            finally
            {
                if (!Dispatcher.CurrentDispatcher.HasShutdownFinished) { Dispatcher.CurrentDispatcher.InvokeShutdown(); }
            }
        })
        {
            IsBackground = true,
            Name = "Capture overlay layout test"
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(TimeSpan.FromSeconds(30)))
        {
            throw new TimeoutException("The WPF layout fixture did not finish within 30 seconds.");
        }

        if (failure is not null)
        {
            throw new InvalidOperationException("The WPF layout fixture failed.", failure);
        }

        return result!;
    }
}
