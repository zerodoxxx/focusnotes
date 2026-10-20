using System.Windows.Threading;
using CaptureApp.Platform.Capture;
using Xunit;

namespace CaptureApp.Platform.Tests.Capture;

public sealed class CaptureInteractiveTests
{
    [Fact]
    [Trait("Needs", "InteractiveDesktop")]
    public async Task EscapeOrCancellationClosesTheOverlayWithoutASelection()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows()
                          && Environment.UserInteractive
                          && Environment.GetEnvironmentVariable("CAPTUREAPP_RUN_INTERACTIVE_TESTS") == "1",
            "Requires CAPTUREAPP_RUN_INTERACTIVE_TESTS=1 on an interactive Windows desktop.");

        var completion = new TaskCompletionSource<byte[]?>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var cancellation = new CancellationTokenSource();
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            dispatcher.BeginInvoke(new Action(async () =>
            {
                try
                {
                    cancellation.CancelAfter(TimeSpan.FromMilliseconds(500));
                    var image = await new RegionCapturer().CaptureAsync(cancellation.Token);
                    completion.TrySetResult(image);
                }
                catch (Exception exception)
                {
                    completion.TrySetException(exception);
                }
                finally
                {
                    dispatcher.BeginInvokeShutdown(DispatcherPriority.Background);
                }
            }));
            Dispatcher.Run();
        })
        {
            IsBackground = true,
            Name = "CaptureApp interactive overlay test"
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        Assert.Null(await completion.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
    }
}
