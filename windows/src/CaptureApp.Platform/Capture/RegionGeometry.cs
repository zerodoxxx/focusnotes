namespace CaptureApp.Platform.Capture;

/// <summary>A point in monitor-local WPF device-independent pixels.</summary>
public readonly record struct DipPoint(double X, double Y);

/// <summary>A point in the physical-pixel coordinate space of the virtual desktop.</summary>
public readonly record struct PixelPoint(int X, int Y);

/// <summary>A rectangle in physical pixels. X and Y may be negative on a multi-monitor desktop.</summary>
public readonly record struct PixelRect(int X, int Y, int Width, int Height)
{
    public int Right => checked(X + Width);
    public int Bottom => checked(Y + Height);
    public bool IsEmpty => Width <= 0 || Height <= 0;
}

/// <summary>Physical monitor bounds and the scale used by its WPF overlay.</summary>
public readonly record struct MonitorGeometry(PixelRect Bounds, double DpiScaleX, double DpiScaleY)
{
    public MonitorGeometry(PixelRect bounds, double dpiScale) : this(bounds, dpiScale, dpiScale) { }
}

/// <summary>Pure coordinate conversion, rectangle normalization, and BGRA crop helpers.</summary>
public static class RegionGeometry
{
    public static PixelPoint DipToPixel(DipPoint point, MonitorGeometry monitor)
    {
        ValidateScale(monitor.DpiScaleX, nameof(monitor.DpiScaleX));
        ValidateScale(monitor.DpiScaleY, nameof(monitor.DpiScaleY));
        return new PixelPoint(
            checked(monitor.Bounds.X + RoundToPixel(point.X * monitor.DpiScaleX)),
            checked(monitor.Bounds.Y + RoundToPixel(point.Y * monitor.DpiScaleY)));
    }

    public static DipPoint PixelToDip(PixelPoint point, MonitorGeometry monitor)
    {
        ValidateScale(monitor.DpiScaleX, nameof(monitor.DpiScaleX));
        ValidateScale(monitor.DpiScaleY, nameof(monitor.DpiScaleY));
        return new DipPoint(
            (point.X - (double)monitor.Bounds.X) / monitor.DpiScaleX,
            (point.Y - (double)monitor.Bounds.Y) / monitor.DpiScaleY);
    }

    public static PixelRect Normalize(PixelPoint first, PixelPoint second)
    {
        var left = Math.Min(first.X, second.X);
        var top = Math.Min(first.Y, second.Y);
        var right = Math.Max(first.X, second.X);
        var bottom = Math.Max(first.Y, second.Y);
        return new PixelRect(left, top, right - left, bottom - top);
    }

    public static PixelRect Intersect(PixelRect first, PixelRect second)
    {
        var left = Math.Max(first.X, second.X);
        var top = Math.Max(first.Y, second.Y);
        var right = Math.Min(first.Right, second.Right);
        var bottom = Math.Min(first.Bottom, second.Bottom);
        return right <= left || bottom <= top
            ? new PixelRect(left, top, 0, 0)
            : new PixelRect(left, top, right - left, bottom - top);
    }

    /// <summary>Copies a clipped rectangle from top-down, tightly packed BGRA pixel data.</summary>
    public static byte[] CropBgra(ReadOnlySpan<byte> pixels, int imageWidth, int imageHeight, PixelRect crop,
        int stride = 0, int bytesPerPixel = 4)
    {
        if (imageWidth <= 0 || imageHeight <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(imageWidth), "Image dimensions must be positive.");
        }

        if (bytesPerPixel <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(bytesPerPixel));
        }

        var minimumStride = checked(imageWidth * bytesPerPixel);
        stride = stride == 0 ? minimumStride : stride;
        if (stride < minimumStride)
        {
            throw new ArgumentOutOfRangeException(nameof(stride), "Stride must cover a complete image row.");
        }

        if (pixels.Length < checked(stride * imageHeight))
        {
            throw new ArgumentException("The pixel buffer is shorter than the image dimensions and stride.", nameof(pixels));
        }

        var clipped = Intersect(crop, new PixelRect(0, 0, imageWidth, imageHeight));
        if (clipped.IsEmpty)
        {
            return [];
        }

        var rowBytes = checked(clipped.Width * bytesPerPixel);
        var result = new byte[checked(rowBytes * clipped.Height)];
        for (var row = 0; row < clipped.Height; row++)
        {
            var sourceOffset = checked((clipped.Y + row) * stride + clipped.X * bytesPerPixel);
            pixels.Slice(sourceOffset, rowBytes).CopyTo(result.AsSpan(row * rowBytes, rowBytes));
        }

        return result;
    }

    private static int RoundToPixel(double value)
    {
        if (!double.IsFinite(value) || value < int.MinValue || value > int.MaxValue)
        {
            throw new ArgumentOutOfRangeException(nameof(value), "The DIP coordinate cannot be represented in pixels.");
        }

        return checked((int)Math.Round(value, MidpointRounding.AwayFromZero));
    }

    private static void ValidateScale(double scale, string parameterName)
    {
        if (!double.IsFinite(scale) || scale <= 0)
        {
            throw new ArgumentOutOfRangeException(parameterName, "DPI scale must be a positive finite number.");
        }
    }
}
