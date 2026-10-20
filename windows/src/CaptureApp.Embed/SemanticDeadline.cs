namespace CaptureApp.Embed;

/// Bounds the entire operation, including waiting for other work. The losing task is cancelled
/// without awaiting non-cancellable helper I/O.
public static class SemanticDeadline
{
    public static async Task<T> RunAsync<T>(TimeSpan timeout, T fallback, Func<CancellationToken, Task<T>> operation,
        CancellationToken cancellationToken = default, TimeProvider? timeProvider = null)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return fallback;
        }

        using var source = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        // The operation and the timer both run on the thread pool, so synchronous work that
        // saturates the caller cannot delay the fallback.
        var work = Task.Run(() => operation(source.Token), CancellationToken.None);
        using var timerSource = new CancellationTokenSource();
        var timer = Task.Delay(timeout, timeProvider ?? TimeProvider.System, timerSource.Token);
        var cancelled = new TaskCompletionSource();
        using var registration = cancellationToken.Register(() => cancelled.TrySetResult());
        var winner = await Task.WhenAny(work, timer, cancelled.Task).ConfigureAwait(false);
        if (winner == work)
        {
            timerSource.Cancel();
            try
            {
                return await work.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return fallback;
            }
        }

        source.Cancel();
        _ = work.ContinueWith(static task => _ = task.Exception, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
        return fallback;
    }
}
