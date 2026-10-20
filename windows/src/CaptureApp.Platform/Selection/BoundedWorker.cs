using System.Collections.Concurrent;

namespace CaptureApp.Platform.Selection;

/// <summary>One MTA thread, one outstanding call. A stuck provider never creates more threads or a growing queue.</summary>
internal sealed class BoundedWorker
{
    private readonly BlockingCollection<Action> work = new(1);
    private int occupied;

    internal BoundedWorker(string name)
    {
        var thread = new Thread(() => { foreach (var action in work.GetConsumingEnumerable()) action(); })
        { IsBackground = true, Name = name };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    internal async Task<T?> RunAsync<T>(Func<T> action, TimeSpan timeout, CancellationToken cancellationToken, Action<T?>? onAbandoned = null) where T : class
    {
        if (Interlocked.CompareExchange(ref occupied, 1, 0) != 0) { onAbandoned?.Invoke(null); return null; }
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        work.Add(() =>
        {
            try
            {
                var result = action();
                Volatile.Write(ref occupied, 0);
                completion.TrySetResult(result);
            }
            catch (Exception ex)
            {
                Volatile.Write(ref occupied, 0);
                completion.TrySetException(ex);
            }
        });
        try { return await completion.Task.WaitAsync(timeout, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            // The OS call cannot be aborted safely. Its eventual result is never used after the deadline.
            _ = completion.Task.ContinueWith(task =>
            {
                if (onAbandoned is not null) onAbandoned(task.Status == TaskStatus.RanToCompletion ? task.Result : null);
                else if (task.Status == TaskStatus.RanToCompletion && task.Result is IDisposable disposable) disposable.Dispose();
                _ = task.Exception;
            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return null;
        }
    }
}
