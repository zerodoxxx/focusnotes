using System.Collections;
using System.Reflection;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CaptureApp.Platform.Capture;
using Xunit;
using WpfImage = System.Windows.Controls.Image;
using WpfRectangle = System.Windows.Shapes.Rectangle;

namespace CaptureApp.Platform.Tests.Capture;

public sealed class RegionOverlayInputTests
{
    [Fact]
    public void FastMouseMovesUseOnlyTheLatestPointForEachRenderingTime()
    {
        RunOnSta(() =>
        {
            using var fixture = new OverlayFixture();
            fixture.Begin(new DipPoint(10, 10));
            for (var index = 20; index <= 100; index++) { fixture.Move(new DipPoint(index, 80)); }
            Assert.Equal(0, fixture.Border.Width);

            fixture.Render(TimeSpan.FromMilliseconds(16));
            Assert.Equal(90, fixture.Border.Width);
            Assert.Equal(70, fixture.Border.Height);
            Assert.Equal(new Rect(10, 10, 90, 70), ((RectangleGeometry)fixture.SelectedImage.Clip).Rect);

            fixture.Move(new DipPoint(110, 85));
            fixture.Render(TimeSpan.FromMilliseconds(16));
            Assert.Equal(90, fixture.Border.Width);
            fixture.Render(TimeSpan.FromMilliseconds(32));
            Assert.Equal(100, fixture.Border.Width);
            // 85 DIPs × 1.5 rounds to physical pixel 128; the anchor is physical pixel 15.
            Assert.Equal(113 / 1.5, fixture.Border.Height, precision: 10);
        });
    }

    [Fact]
    public void MouseUpUsesItsFinalPointEvenWhenANewerMoveHasNotRendered()
    {
        RunOnSta(() =>
        {
            using var fixture = new OverlayFixture();
            fixture.Begin(new DipPoint(10, 10));
            fixture.Move(new DipPoint(100, 80));
            fixture.Complete(new DipPoint(40, 30));

            var png = fixture.Completion.Task.GetAwaiter().GetResult();
            Assert.NotNull(png);
            using var stream = new MemoryStream(png);
            var decoder = new PngBitmapDecoder(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            Assert.Equal(45, decoder.Frames[0].PixelWidth);
            Assert.Equal(30, decoder.Frames[0].PixelHeight);
            Assert.False(fixture.RenderingSubscribed);
            Assert.False(fixture.IsSelecting);
        });
    }

    [Fact]
    public void CancellationStopsRenderingAndDiscardsPendingMoves()
    {
        RunOnSta(() =>
        {
            using var fixture = new OverlayFixture();
            Assert.False(fixture.RenderingSubscribed);
            fixture.Begin(new DipPoint(10, 10));
            fixture.Move(new DipPoint(100, 80));
            Assert.True(fixture.RenderingSubscribed);
            fixture.Cancel();
            Assert.Null(fixture.Completion.Task.GetAwaiter().GetResult());
            Assert.False(fixture.RenderingSubscribed);
            Assert.False(fixture.IsSelecting);
            fixture.Render(TimeSpan.FromMilliseconds(16));
            Assert.Equal(0, fixture.Border.Width);
        });
    }

    [Fact]
    public void DispatcherShutdownCancelsAnActiveDragAndRemovesItsRenderingSubscription()
    {
        RunOnSta(() =>
        {
            using var fixture = new OverlayFixture();
            fixture.Begin(new DipPoint(10, 10));
            fixture.Move(new DipPoint(100, 80));
            Dispatcher.CurrentDispatcher.InvokeShutdown();
            Assert.True(fixture.Completion.Task.IsCompletedSuccessfully);
            Assert.Null(fixture.Completion.Task.Result);
            Assert.False(fixture.RenderingSubscribed);
            Assert.False(fixture.IsSelecting);
        });
    }

    [Fact]
    public void ClosingAnOverlayCancelsAnActiveDrag()
    {
        RunOnSta(() =>
        {
            using var fixture = new OverlayFixture();
            fixture.Begin(new DipPoint(10, 10));
            fixture.Window.Close();
            Assert.True(fixture.Completion.Task.IsCompletedSuccessfully);
            Assert.Null(fixture.Completion.Task.Result);
            Assert.False(fixture.RenderingSubscribed);
        });
    }

    [Fact]
    public void LosingMouseCaptureCancelsTheDragAndStopsRendering()
    {
        RunOnSta(() =>
        {
            using var fixture = new OverlayFixture();
            fixture.Begin(new DipPoint(10, 10));
            fixture.Window.RaiseEvent(new System.Windows.Input.MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount)
            {
                RoutedEvent = Mouse.LostMouseCaptureEvent
            });
            Assert.True(fixture.Completion.Task.IsCompletedSuccessfully);
            Assert.Null(fixture.Completion.Task.Result);
            Assert.False(fixture.RenderingSubscribed);
        });
    }

    private sealed class OverlayFixture : IDisposable
    {
        private readonly Type _controllerType;
        private readonly object _controller;
        private readonly MonitorGeometry _monitor = new(new PixelRect(0, 0, 300, 150), 1.5);
        public TaskCompletionSource<byte[]?> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Window Window { get; }
        public WpfRectangle Border { get; }
        public WpfImage SelectedImage { get; }
        public bool RenderingSubscribed => (bool)_controllerType.GetField("_renderingSubscribed", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(_controller)!;
        public bool IsSelecting => (bool)_controllerType.GetProperty("IsSelecting")!.GetValue(_controller)!;

        public OverlayFixture()
        {
            var frozenType = typeof(RegionCapturer).GetNestedType("FrozenDesktop", BindingFlags.NonPublic)!;
            var frozen = frozenType.GetConstructors(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
                .Single(constructor => constructor.GetParameters().Length == 2)
                .Invoke([_monitor.Bounds, new byte[300 * 150 * 4]]);
            _controllerType = typeof(RegionCapturer).GetNestedType("OverlayController", BindingFlags.NonPublic)!;
            _controller = _controllerType.GetConstructors(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
                .Single().Invoke([frozen, new[] { _monitor }, Completion]);
            // Build the production windows without showing a surface or reading the desktop.
            _controllerType.GetMethod("CreateWindows", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(_controller, null);
            var windows = (IList)_controllerType.GetField("_windows", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(_controller)!;
            Window = (Window)Assert.Single(windows.Cast<object>());
            Border = (WpfRectangle)Window.GetType().GetField("_selectionBorder", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(Window)!;
            SelectedImage = (WpfImage)Window.GetType().GetField("_selectedImage", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(Window)!;
        }

        public void Begin(DipPoint point) => _controllerType.GetMethod("Begin")!.Invoke(_controller, [_monitor, point]);
        public void Move(DipPoint point) => _controllerType.GetMethod("Update", [typeof(MonitorGeometry), typeof(DipPoint)])!.Invoke(_controller, [_monitor, point]);
        public void Complete(DipPoint point) => _controllerType.GetMethod("Complete")!.Invoke(_controller, [_monitor, point]);
        public void Cancel() => _controllerType.GetMethod("Cancel")!.Invoke(_controller, null);
        public void Render(TimeSpan time)
        {
            var args = Activator.CreateInstance(typeof(RenderingEventArgs), BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
                null, [time], null)!;
            _controllerType.GetMethod("OnRendering", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(_controller, [null, args]);
        }
        public void Dispose() => Cancel();
    }

    private static void RunOnSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { action(); }
            catch (Exception error) { failure = error; }
            finally
            {
                if (!Dispatcher.CurrentDispatcher.HasShutdownFinished) { Dispatcher.CurrentDispatcher.InvokeShutdown(); }
            }
        }) { IsBackground = true, Name = "Capture drag regression" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(15)), "The capture drag fixture did not finish.");
        if (failure is not null) { throw new InvalidOperationException("The capture drag fixture failed.", failure); }
    }
}
