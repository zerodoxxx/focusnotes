using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using DrawingColor = System.Drawing.Color;
using DrawingPixelFormat = System.Drawing.Imaging.PixelFormat;
using DrawingRectangle = System.Drawing.Rectangle;
using WpfBrushes = System.Windows.Media.Brushes;
using WpfImage = System.Windows.Controls.Image;
using WpfRectangle = System.Windows.Shapes.Rectangle;

namespace CaptureApp.Platform.Capture;

/// <summary>Freezes every display, presents one selection overlay per monitor, and returns a cropped PNG.</summary>
public sealed class RegionCapturer
{
    private const int SourceCopy = 0x00CC0020;
    private const int CaptureBlt = 0x40000000;
    private const uint MonitorEffectiveDpi = 0;
    private const uint SwpShowWindow = 0x0040;
    private static readonly IntPtr HwndTopmost = new(-1);
    private static readonly IntPtr PerMonitorAwareV2 = new(-4);
    private static readonly MonitorEnumProcedure MonitorCallback = EnumerateMonitor;

    /// <summary>Returns null when the user presses Escape, cancels, or selects less than 4×4 pixels.</summary>
    public Task<byte[]?> CaptureAsync(CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return Task.FromResult<byte[]?>(null);
        }

        var dispatcher = System.Windows.Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
        return dispatcher.CheckAccess()
            ? StartOnDispatcher(dispatcher, cancellationToken)
            : dispatcher.InvokeAsync(() => StartOnDispatcher(dispatcher, cancellationToken)).Task.Unwrap();
    }

    private static Task<byte[]?> StartOnDispatcher(Dispatcher dispatcher, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var dpiContext = ThreadDpiContext.Enter();
        var monitors = GetMonitors();
        if (monitors.Count == 0)
        {
            return Task.FromResult<byte[]?>(null);
        }

        var desktopBounds = Union(monitors.Select(monitor => monitor.Bounds));
        var frozenDesktop = CaptureDesktop(desktopBounds, monitors);
        var completion = new TaskCompletionSource<byte[]?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var overlay = new OverlayController(frozenDesktop, monitors, completion);
        overlay.Show();
        if (cancellationToken.CanBeCanceled)
        {
            overlay.SetCancellationRegistration(cancellationToken.Register(
                () => dispatcher.BeginInvoke(new Action(overlay.Cancel))));
        }

        return completion.Task;
    }

    private static FrozenDesktop CaptureDesktop(PixelRect bounds, IReadOnlyList<MonitorGeometry> monitors)
    {
        using var bitmap = new Bitmap(bounds.Width, bounds.Height, DrawingPixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(DrawingColor.Black);
        var destination = graphics.GetHdc();
        var desktop = GetDC(IntPtr.Zero);
        if (desktop == IntPtr.Zero)
        {
            graphics.ReleaseHdc(destination);
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not get the desktop device context.");
        }

        try
        {
            foreach (var monitor in monitors)
            {
                var source = monitor.Bounds;
                if (!BitBlt(destination, source.X - bounds.X, source.Y - bounds.Y, source.Width, source.Height,
                        desktop, source.X, source.Y, SourceCopy | CaptureBlt))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not freeze a monitor image.");
                }
            }
        }
        finally
        {
            ReleaseDC(IntPtr.Zero, desktop);
            graphics.ReleaseHdc(destination);
        }

        var data = bitmap.LockBits(new DrawingRectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly,
            DrawingPixelFormat.Format32bppArgb);
        try
        {
            var stride = Math.Abs(data.Stride);
            var pixels = new byte[checked(stride * bitmap.Height)];
            for (var row = 0; row < bitmap.Height; row++)
            {
                var rowPointer = data.Stride >= 0
                    ? IntPtr.Add(data.Scan0, row * data.Stride)
                    : IntPtr.Add(data.Scan0, (bitmap.Height - row - 1) * data.Stride);
                Marshal.Copy(rowPointer, pixels, row * stride, stride);
            }

            if (stride != bitmap.Width * 4)
            {
                var packed = new byte[checked(bitmap.Width * bitmap.Height * 4)];
                for (var row = 0; row < bitmap.Height; row++)
                {
                    Buffer.BlockCopy(pixels, row * stride, packed, row * bitmap.Width * 4, bitmap.Width * 4);
                }

                pixels = packed;
            }

            return new FrozenDesktop(bounds, pixels);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    private static IReadOnlyList<MonitorGeometry> GetMonitors()
    {
        var result = new List<MonitorGeometry>();
        var state = new MonitorEnumerationState(result);
        var handle = GCHandle.Alloc(state);
        bool enumerated;
        try
        {
            enumerated = EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, MonitorCallback, GCHandle.ToIntPtr(handle));
        }
        finally
        {
            handle.Free();
        }

        if (!enumerated)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not enumerate the displays.");
        }

        return result;
    }

    private static bool EnumerateMonitor(IntPtr monitor, IntPtr deviceContext, ref NativeRect clip, IntPtr data)
    {
        // EnumDisplayMonitors invokes this rooted delegate. The thread-local list is supplied through data
        // to keep the unmanaged callback free of captured delegates.
        var handle = GCHandle.FromIntPtr(data);
        var state = (MonitorEnumerationState)handle.Target!;
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>(), Device = string.Empty };
        if (!GetMonitorInfo(monitor, ref info))
        {
            return true;
        }

        uint dpiX = 96;
        uint dpiY = 96;
        try
        {
            if (GetDpiForMonitor(monitor, MonitorEffectiveDpi, out dpiX, out dpiY) != 0 || dpiX == 0 || dpiY == 0)
            {
                dpiX = 96;
                dpiY = 96;
            }
        }
        catch (DllNotFoundException)
        {
            // The standard 96-DPI scale is used only on systems without Shcore.
        }

        var rectangle = info.Monitor;
        var bounds = new PixelRect(rectangle.Left, rectangle.Top, rectangle.Right - rectangle.Left,
            rectangle.Bottom - rectangle.Top);
        if (!bounds.IsEmpty)
        {
            state.Monitors.Add(new MonitorGeometry(bounds, dpiX / 96.0, dpiY / 96.0));
        }

        return true;
    }

    private static PixelRect Union(IEnumerable<PixelRect> rectangles)
    {
        var bounds = rectangles.ToArray();
        var left = bounds.Min(rectangle => rectangle.X);
        var top = bounds.Min(rectangle => rectangle.Y);
        var right = bounds.Max(rectangle => rectangle.Right);
        var bottom = bounds.Max(rectangle => rectangle.Bottom);
        return new PixelRect(left, top, right - left, bottom - top);
    }

    private static byte[] EncodePixelsAsPng(byte[] pixels, int width, int height)
    {
        var source = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
        source.Freeze();
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    private sealed record FrozenDesktop(PixelRect Bounds, byte[] BgraPixels);

    private sealed class OverlayController(FrozenDesktop desktop, IReadOnlyList<MonitorGeometry> monitors,
        TaskCompletionSource<byte[]?> completion)
    {
        private readonly List<MonitorOverlayWindow> _windows = [];
        private PixelPoint? _anchor;
        private PixelPoint? _pendingPoint;
        private TimeSpan? _lastRenderingTime;
        private Dispatcher? _renderDispatcher;
        private bool _renderingSubscribed;
        private bool _completed;
        private CancellationTokenRegistration _cancellationRegistration;

        public bool IsSelecting => !_completed && _anchor is not null;

        public void SetCancellationRegistration(CancellationTokenRegistration registration) =>
            _cancellationRegistration = registration;

        public void Show()
        {
            CreateWindows();
            foreach (var window in _windows)
            {
                window.Show();
            }

            _windows[0].Activate();
            _windows[0].Focus();
        }

        private void CreateWindows()
        {
            foreach (var monitor in monitors)
            {
                var localBounds = new PixelRect(monitor.Bounds.X - desktop.Bounds.X,
                    monitor.Bounds.Y - desktop.Bounds.Y, monitor.Bounds.Width, monitor.Bounds.Height);
                var pixels = RegionGeometry.CropBgra(desktop.BgraPixels, desktop.Bounds.Width, desktop.Bounds.Height,
                    localBounds);
                var image = BitmapSource.Create(monitor.Bounds.Width, monitor.Bounds.Height, 96, 96,
                    PixelFormats.Bgra32, null, pixels, monitor.Bounds.Width * 4);
                image.Freeze();
                var window = new MonitorOverlayWindow(monitor, image, this);
                window.Closed += OnWindowClosed;
                _windows.Add(window);
            }
        }

        public void Begin(MonitorGeometry monitor, DipPoint point)
        {
            if (_completed || _anchor is not null)
            {
                return;
            }

            _anchor = RegionGeometry.DipToPixel(point, monitor);
            Update(_anchor.Value);
            _renderDispatcher = Dispatcher.CurrentDispatcher;
            _renderDispatcher.ShutdownStarted += OnDispatcherShutdown;
            CompositionTarget.Rendering += OnRendering;
            _renderingSubscribed = true;
        }

        public void Update(MonitorGeometry monitor, DipPoint point)
        {
            if (IsSelecting)
            {
                // Input may arrive faster than the display can present. Retain one latest point
                // rather than enqueueing a layout and composition update for every mouse message.
                _pendingPoint = RegionGeometry.DipToPixel(point, monitor);
            }
        }

        public void Complete(MonitorGeometry monitor, DipPoint point)
        {
            if (_completed || _anchor is not { } anchor)
            {
                return;
            }

            var current = RegionGeometry.DipToPixel(point, monitor);
            StopRendering();
            var selection = RegionGeometry.Intersect(RegionGeometry.Normalize(anchor, current), desktop.Bounds);
            if (selection.Width < 4 || selection.Height < 4)
            {
                Finish(null);
                return;
            }

            var local = new PixelRect(selection.X - desktop.Bounds.X, selection.Y - desktop.Bounds.Y,
                selection.Width, selection.Height);
            var crop = RegionGeometry.CropBgra(desktop.BgraPixels, desktop.Bounds.Width, desktop.Bounds.Height, local);
            Finish(EncodePixelsAsPng(crop, selection.Width, selection.Height));
        }

        public void Cancel() => Finish(null);

        private void OnRendering(object? sender, EventArgs args)
        {
            if (!IsSelecting || args is not RenderingEventArgs rendering
                || _lastRenderingTime == rendering.RenderingTime)
            {
                return;
            }

            _lastRenderingTime = rendering.RenderingTime;
            if (_pendingPoint is { } point)
            {
                _pendingPoint = null;
                Update(point);
            }
        }

        private void StopRendering()
        {
            _pendingPoint = null;
            if (!_renderingSubscribed) { return; }
            _renderingSubscribed = false;
            CompositionTarget.Rendering -= OnRendering;
            _renderDispatcher!.ShutdownStarted -= OnDispatcherShutdown;
            _renderDispatcher = null;
        }

        private void OnDispatcherShutdown(object? sender, EventArgs args) => Cancel();

        private void OnWindowClosed(object? sender, EventArgs args)
        {
            if (sender is MonitorOverlayWindow window)
            {
                window.Closed -= OnWindowClosed;
                _windows.Remove(window);
            }
            Cancel();
        }

        private void Update(PixelPoint current)
        {
            var selection = RegionGeometry.Normalize(_anchor!.Value, current);
            foreach (var window in _windows)
            {
                window.UpdateSelection(selection);
            }
        }

        private void Finish(byte[]? png)
        {
            if (_completed)
            {
                return;
            }

            _completed = true;
            StopRendering();
            _cancellationRegistration.Dispose();
            foreach (var window in _windows.ToArray())
            {
                window.Closed -= OnWindowClosed;
                window.Close();
            }

            completion.TrySetResult(png);
        }
    }

    private sealed class MonitorOverlayWindow : Window
    {
        private readonly MonitorGeometry _monitor;
        private readonly OverlayController _controller;
        private readonly Canvas _inputCanvas = new();
        private readonly WpfImage _selectedImage = new()
        {
            Stretch = Stretch.Fill,
            IsHitTestVisible = false,
            Clip = Geometry.Empty
        };
        private readonly WpfRectangle _selectionBorder = new()
        {
            Stroke = WpfBrushes.White,
            StrokeThickness = 1.5,
            Fill = WpfBrushes.Transparent,
            IsHitTestVisible = false
        };

        public MonitorOverlayWindow(MonitorGeometry monitor, BitmapSource frozenImage, OverlayController controller)
        {
            _monitor = monitor;
            _controller = controller;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            Topmost = true;
            ShowActivated = true;
            Focusable = true;
            Cursor = System.Windows.Input.Cursors.Cross;
            Left = 0;
            Top = 0;
            Width = monitor.Bounds.Width / monitor.DpiScaleX;
            Height = monitor.Bounds.Height / monitor.DpiScaleY;

            var content = new Grid();
            content.Children.Add(new WpfImage { Source = frozenImage, Stretch = Stretch.Fill, IsHitTestVisible = false });
            content.Children.Add(new WpfRectangle
            {
                Fill = new SolidColorBrush(System.Windows.Media.Color.FromArgb(118, 0, 0, 0))
            });
            _inputCanvas.Background = WpfBrushes.Transparent;
            _selectedImage.Source = frozenImage;
            _selectedImage.Width = Width;
            _selectedImage.Height = Height;
            _inputCanvas.Children.Add(_selectedImage);
            _inputCanvas.Children.Add(_selectionBorder);
            content.Children.Add(_inputCanvas);
            Content = content;

            SourceInitialized += (_, _) => PositionOnMonitor();
            PreviewMouseLeftButtonDown += OnMouseDown;
            PreviewMouseMove += OnMouseMove;
            PreviewMouseLeftButtonUp += OnMouseUp;
            LostMouseCapture += OnLostMouseCapture;
            PreviewKeyDown += OnKeyDown;
        }

        public void UpdateSelection(PixelRect selection)
        {
            var clipped = RegionGeometry.Intersect(selection, _monitor.Bounds);
            if (clipped.IsEmpty)
            {
                _selectedImage.Clip = Geometry.Empty;
                _selectionBorder.Width = 0;
                _selectionBorder.Height = 0;
                return;
            }

            var first = RegionGeometry.PixelToDip(new PixelPoint(clipped.X, clipped.Y), _monitor);
            var second = RegionGeometry.PixelToDip(new PixelPoint(clipped.Right, clipped.Bottom), _monitor);
            var rectangle = new Rect(first.X, first.Y, second.X - first.X, second.Y - first.Y);
            _selectedImage.Clip = new RectangleGeometry(rectangle);
            Canvas.SetLeft(_selectionBorder, rectangle.Left);
            Canvas.SetTop(_selectionBorder, rectangle.Top);
            _selectionBorder.Width = rectangle.Width;
            _selectionBorder.Height = rectangle.Height;
        }

        private void OnMouseDown(object sender, MouseButtonEventArgs args)
        {
            if (args.ChangedButton == MouseButton.Left)
            {
                _controller.Begin(_monitor, ToDip(args.GetPosition(_inputCanvas)));
                if (!Mouse.Capture(_inputCanvas, CaptureMode.SubTree)) { _controller.Cancel(); }
                args.Handled = true;
            }
        }

        private void OnMouseMove(object sender, System.Windows.Input.MouseEventArgs args)
        {
            if (_controller.IsSelecting && args.LeftButton == MouseButtonState.Pressed)
            {
                _controller.Update(_monitor, ToDip(args.GetPosition(_inputCanvas)));
                args.Handled = true;
            }
        }

        private void OnMouseUp(object sender, MouseButtonEventArgs args)
        {
            if (args.ChangedButton == MouseButton.Left && _controller.IsSelecting)
            {
                _controller.Complete(_monitor, ToDip(args.GetPosition(_inputCanvas)));
                Mouse.Capture(null);
                args.Handled = true;
            }
        }

        private void OnLostMouseCapture(object sender, System.Windows.Input.MouseEventArgs args)
        {
            if (_controller.IsSelecting && Mouse.Captured != _inputCanvas) { _controller.Cancel(); }
        }

        private void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs args)
        {
            if (args.Key == Key.Escape)
            {
                _controller.Cancel();
                args.Handled = true;
            }
        }

        private static DipPoint ToDip(System.Windows.Point point) => new(point.X, point.Y);

        private void PositionOnMonitor()
        {
            var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
            if (!SetWindowPos(handle, HwndTopmost, _monitor.Bounds.X, _monitor.Bounds.Y,
                    _monitor.Bounds.Width, _monitor.Bounds.Height, SwpShowWindow))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not position the capture overlay.");
            }
        }
    }

    private sealed class ThreadDpiContext : IDisposable
    {
        private readonly IntPtr _previous;

        private ThreadDpiContext(IntPtr previous) => _previous = previous;

        public static ThreadDpiContext Enter()
        {
            var previous = SetThreadDpiAwarenessContext(PerMonitorAwareV2);
            if (previous == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not enable per-monitor DPI awareness.");
            }

            return new ThreadDpiContext(previous);
        }

        public void Dispose() => _ = SetThreadDpiAwarenessContext(_previous);
    }

    private sealed class MonitorEnumerationState(List<MonitorGeometry> monitors)
    {
        public List<MonitorGeometry> Monitors { get; } = monitors;
    }

    private delegate bool MonitorEnumProcedure(IntPtr monitor, IntPtr deviceContext, ref NativeRect clip, IntPtr data);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfo
    {
        public uint Size;
        public NativeRect Monitor;
        public NativeRect Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string? Device;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplayMonitors(IntPtr deviceContext, IntPtr clip, MonitorEnumProcedure callback,
        IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMonitorInfoW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, uint dpiType, out uint dpiX, out uint dpiY);

    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BitBlt(IntPtr destination, int x, int y, int width, int height, IntPtr source,
        int sourceX, int sourceY, int operation);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetDC(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr window, IntPtr deviceContext);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height,
        uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
}
