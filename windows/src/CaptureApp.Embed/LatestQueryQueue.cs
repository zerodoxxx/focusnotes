namespace CaptureApp.Embed;

/// One transport operation and one replaceable pending query. An operation already on the wire
/// drains its response before the next one is dispatched.
public sealed class LatestQueryQueue
{
    private sealed class Job(Func<CancellationToken, Task<float[]>> operation, CancellationToken caller)
    {
        public Func<CancellationToken, Task<float[]>> Operation { get; } = operation;
        public CancellationTokenSource Cancellation { get; } = CancellationTokenSource.CreateLinkedTokenSource(caller);
        public TaskCompletionSource<float[]> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Superseded { get; set; }
    }

    private readonly object gate = new();
    private Job? active;
    private Job? pending;

    public async Task<float[]> SubmitAsync(Func<CancellationToken, Task<float[]>> operation, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var job = new Job(operation, cancellationToken);
        using var registration = cancellationToken.Register(() => Cancel(job));
        lock (gate)
        {
            if (active is null)
            {
                Start(job);
            }
            else
            {
                // If the active request is still behind indexing I/O, its cancellation token
                // drops it before it reaches the wire. Its caller is released immediately.
                Supersede(active);
                if (pending is not null)
                {
                    Supersede(pending);
                }

                pending = job;
            }
        }

        return await job.Completion.Task.ConfigureAwait(false);
    }

    private static void Supersede(Job job)
    {
        job.Superseded = true;
        job.Completion.TrySetCanceled();
        job.Cancellation.Cancel();
    }

    private void Start(Job job)
    {
        active = job;
        _ = Task.Run(async () =>
        {
            try
            {
                job.Cancellation.Token.ThrowIfCancellationRequested();
                job.Completion.TrySetResult(await job.Operation(job.Cancellation.Token).ConfigureAwait(false));
            }
            catch (OperationCanceledException)
            {
                job.Completion.TrySetCanceled();
            }
            catch (Exception error)
            {
                job.Completion.TrySetException(error);
            }

            Complete(job);
        });
    }

    private void Complete(Job job)
    {
        lock (gate)
        {
            if (active != job)
            {
                return;
            }

            active = null;
            if (pending is { } next)
            {
                pending = null;
                Start(next);
            }
        }
    }

    private void Cancel(Job job)
    {
        lock (gate)
        {
            if (pending == job)
            {
                pending = null;
            }
        }

        job.Completion.TrySetCanceled();
        job.Cancellation.Cancel();
    }
}
