namespace CaptureApp.AppCore;

/// Races shutdown work against an absolute deadline, returning whether the work drained in time.
public static class ShutdownWait
{
    public static Task<bool> WaitAsync(Task task, DateTimeOffset deadline, TimeProvider? timeProvider = null,
        CancellationToken cancellationToken = default)
    {
        var clock = timeProvider ?? TimeProvider.System;
        return WaitAsync(task, deadline - clock.GetUtcNow(), cancellationToken);
    }

    public static async Task<bool> WaitAsync(Task task, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(task);
        if (task.IsCompleted)
        {
            await task.ConfigureAwait(false);
            return true;
        }

        if (timeout <= TimeSpan.Zero) { return false; }
        var deadline = Task.Delay(timeout, cancellationToken);
        var completed = await Task.WhenAny(task, deadline).ConfigureAwait(false);
        if (!ReferenceEquals(completed, task))
        {
            cancellationToken.ThrowIfCancellationRequested();
            return false;
        }

        await task.ConfigureAwait(false);
        return true;
    }
}
