using System.Diagnostics;
using System.Globalization;

namespace CaptureApp.Embed;

public interface IEmbedService
{
    int Dimensions { get; }

    Task<float[]> EmbedQueryAsync(string text, CancellationToken cancellationToken = default);

    /// For interactive search: superseded callers are cancelled; only the latest pending query
    /// survives while an in-flight response drains.
    Task<float[]> EmbedLatestQueryAsync(string text, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<float[]>> EmbedDocumentsAsync(IReadOnlyList<string> texts, string? title = null, CancellationToken cancellationToken = default);

    Task<float[]> EmbedImageAsync(byte[] imagePng, CancellationToken cancellationToken = default);

    /// Ping starts the helper if needed but does not load any model.
    Task<EmbedResponse> PingAsync(CancellationToken cancellationToken = default);

    Task ShutdownAsync();

    /// Permanently rejects new work and stops this client's helper. Unlike ShutdownAsync, a closed client cannot restart.
    Task CloseAsync();
}

/// Client callable from any thread. A private serial gate owns the helper process and framing state;
/// overlapping calls cannot mix responses. No model or runtime is loaded in the calling process.
public sealed class EmbedClient : IEmbedService, IAsyncDisposable
{
    private readonly HelperTransport transport;
    private readonly LatestQueryQueue latestQueries = new();

    /// helperExecutable is the EmbedHelper exe, or its .dll (launched through the dotnet host).
    public EmbedClient(string helperExecutable, string modelsDirectory, int dimensions = 256, double idleSeconds = 60, double requestTimeout = 120)
    {
        if (!EmbedRequest.SupportedDimensions.Contains(dimensions) || !double.IsFinite(idleSeconds) || idleSeconds <= 0 || idleSeconds > 86_400
            || !double.IsFinite(requestTimeout) || requestTimeout <= 0 || requestTimeout > 86_400)
        {
            throw EmbeddingException.Invalid("Invalid client configuration");
        }

        Dimensions = dimensions;
        transport = new HelperTransport(helperExecutable, modelsDirectory, idleSeconds, requestTimeout);
    }

    public int Dimensions { get; }

    public async Task<float[]> EmbedQueryAsync(string text, CancellationToken cancellationToken = default)
    {
        var vectors = await PerformAsync(new EmbedRequest { Operation = "embedQuery", Text = text, Dimensions = Dimensions }, cancellationToken).ConfigureAwait(false);
        return vectors.Count == 1 ? vectors[0] : throw EmbeddingException.Transport("Expected one query vector");
    }

    public Task<float[]> EmbedLatestQueryAsync(string text, CancellationToken cancellationToken = default) =>
        latestQueries.SubmitAsync(token => EmbedQueryAsync(text, token), cancellationToken);

    public async Task<IReadOnlyList<float[]>> EmbedDocumentsAsync(IReadOnlyList<string> texts, string? title = null, CancellationToken cancellationToken = default)
    {
        if (texts.Count == 0)
        {
            return [];
        }

        var vectors = await PerformAsync(new EmbedRequest { Operation = "embedDocuments", Texts = [.. texts], Title = title, Dimensions = Dimensions }, cancellationToken).ConfigureAwait(false);
        return vectors.Count == texts.Count ? vectors : throw EmbeddingException.Transport("Document count mismatch");
    }

    public async Task<float[]> EmbedImageAsync(byte[] imagePng, CancellationToken cancellationToken = default)
    {
        var vectors = await PerformAsync(new EmbedRequest { Operation = "embedImage", ImagePng = Convert.ToBase64String(imagePng), Dimensions = Dimensions }, cancellationToken).ConfigureAwait(false);
        return vectors.Count == 1 ? vectors[0] : throw EmbeddingException.Transport("Expected one image vector");
    }

    public Task<EmbedResponse> PingAsync(CancellationToken cancellationToken = default) =>
        transport.SendAsync(new EmbedRequest { Operation = "ping", Dimensions = Dimensions }, cancellationToken);

    /// Reports the Windows background-mode flags the helper applied to itself.
    public Task<EmbedResponse> StatusAsync(CancellationToken cancellationToken = default) =>
        transport.SendAsync(new EmbedRequest { Operation = "status", Dimensions = Dimensions }, cancellationToken);

    /// Does not launch the helper. Useful to observe idle exit.
    public int? ProcessId() => transport.ProcessId();

    public Task ShutdownAsync() => transport.ShutdownAsync();

    public Task CloseAsync() => transport.CloseAsync();

    public int PendingRequestCountForTesting => transport.PendingRequestCount;

    public async ValueTask DisposeAsync() => await CloseAsync().ConfigureAwait(false);

    private async Task<List<float[]>> PerformAsync(EmbedRequest request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var response = await transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (response.Vectors is null)
        {
            throw EmbeddingException.Transport("Missing vectors");
        }

        var vectors = new List<float[]>(response.Vectors.Count);
        foreach (var encoded in response.Vectors)
        {
            byte[] data;
            try
            {
                data = Convert.FromBase64String(encoded);
            }
            catch (FormatException)
            {
                throw EmbeddingException.Transport("Invalid vector base64");
            }

            // Float16 wire quantization loses a little norm; restore unit length.
            vectors.Add(VectorMath.Normalized(Float16Vectors.Decode(data, Dimensions)));
        }

        return vectors;
    }
}

internal sealed class HelperTransport(string executable, string directory, double idle, double timeout)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly object lifecycle = new();
    private readonly CancellationTokenSource aborted = new();
    private int requests;
    private bool permanentlyClosed;
    private Process? process;
    private Stream? input;
    private Stream? output;
    private WindowsJob? job;
    private byte[] pending = [];
    private readonly List<long> failures = [];
    private long retryAfter;

    public int PendingRequestCount => Volatile.Read(ref requests);

    public async Task<EmbedResponse> SendAsync(EmbedRequest request, CancellationToken cancellationToken)
    {
        lock (lifecycle)
        {
            if (permanentlyClosed)
            {
                throw EmbeddingException.Transport("Embed client is closed");
            }

            requests++;
        }

        // The work continues if the caller cancels once the request is on the wire, so the
        // response is drained and request/response framing stays intact.
        var work = Task.Run(async () =>
        {
            try
            {
                return await ExecuteAsync(request, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                lock (lifecycle)
                {
                    requests--;
                }
            }
        }, CancellationToken.None);
        try
        {
            return await work.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested && !work.IsCompleted)
        {
            _ = work.ContinueWith(static task => _ = task.Exception, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
            throw;
        }
    }

    private async Task<EmbedResponse> ExecuteAsync(EmbedRequest request, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureOpen(cancellationToken);
            // Embedding requests are pure, so retry once if the idle deadline races a write
            // or the helper dies unexpectedly.
            EmbedResponse? response = null;
            for (var attempt = 0; attempt < 2; attempt++)
            {
                EnsureOpen(cancellationToken);
                CheckBackoff();
                try
                {
                    response = await ExchangeAsync(request, cancellationToken).ConfigureAwait(false);
                    break;
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch
                {
                    RecordFailure();
                    Stop();
                    EnsureOpen(cancellationToken);
                    if (attempt == 1)
                    {
                        throw;
                    }
                }
            }

            if (response is null)
            {
                throw EmbeddingException.Transport("No response");
            }

            if (response.Error is { } error)
            {
                // Runtime/model failures also need a cooldown. A bad install can fail every request without exiting.
                RecordFailure();
                throw EmbeddingException.Runtime(error);
            }

            // A ping never loads models, so it cannot prove recovery from model errors.
            if (request.Operation != "ping")
            {
                failures.Clear();
                retryAfter = 0;
            }

            EnsureOpen(cancellationToken);
            return response;
        }
        finally
        {
            gate.Release();
        }
    }

    private void EnsureOpen(CancellationToken cancellationToken)
    {
        lock (lifecycle)
        {
            if (permanentlyClosed)
            {
                throw new OperationCanceledException();
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
    }

    private void CheckBackoff()
    {
        if (Environment.TickCount64 < retryAfter)
        {
            throw EmbeddingException.Transport("Helper failures: retry paused for 30 seconds");
        }

        if (retryAfter != 0)
        {
            retryAfter = 0;
            failures.Clear();
        }
    }

    private void RecordFailure()
    {
        var now = Environment.TickCount64;
        failures.RemoveAll(time => now - time > 60_000);
        failures.Add(now);
        if (failures.Count >= 3)
        {
            retryAfter = now + 30_000;
        }
    }

    public int? ProcessId()
    {
        lock (lifecycle)
        {
            try
            {
                return process is { HasExited: false } running ? running.Id : null;
            }
            catch (InvalidOperationException)
            {
                return null;
            }
        }
    }

    public async Task ShutdownAsync()
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            Stop();
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task CloseAsync()
    {
        lock (lifecycle)
        {
            permanentlyClosed = true;
        }

        // Interrupts any on-wire wait so the stop below can terminate the helper promptly.
        await aborted.CancelAsync().ConfigureAwait(false);
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            Stop();
            job?.Dispose();
            job = null;
        }
        finally
        {
            gate.Release();
        }
    }

    private void Start()
    {
        if (process is { HasExited: false })
        {
            return;
        }

        Stop();
        var info = new ProcessStartInfo
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        if (executable.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
        {
            info.FileName = Environment.ProcessPath is { } host && Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase) ? host : "dotnet";
            info.ArgumentList.Add(executable);
        }
        else
        {
            info.FileName = executable;
        }

        info.ArgumentList.Add("--models");
        info.ArgumentList.Add(directory);
        info.ArgumentList.Add("--idle-seconds");
        info.ArgumentList.Add(idle.ToString("R", CultureInfo.InvariantCulture));
        info.ArgumentList.Add("--parent-pid");
        info.ArgumentList.Add(Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
        Process started;
        lock (lifecycle)
        {
            if (permanentlyClosed)
            {
                throw new OperationCanceledException();
            }

            try
            {
                started = Process.Start(info) ?? throw EmbeddingException.Transport("Could not start the embedding helper");
            }
            catch (System.ComponentModel.Win32Exception error)
            {
                throw EmbeddingException.Transport($"Could not start the embedding helper: {error.Message}");
            }

            process = started;
        }

        if (OperatingSystem.IsWindows())
        {
            try
            {
                job ??= new WindowsJob();
                job.Assign(started);
            }
            catch
            {
                Stop();
                throw;
            }
        }

        input = started.StandardInput.BaseStream;
        output = started.StandardOutput.BaseStream;
        pending = [];
    }

    private void Stop()
    {
        try
        {
            input?.Dispose();
            output?.Dispose();
        }
        catch (IOException)
        {
        }

        Process? stopping;
        lock (lifecycle)
        {
            stopping = process;
            process = null;
        }

        if (stopping is not null)
        {
            try
            {
                if (!stopping.HasExited)
                {
                    stopping.Kill();
                    stopping.WaitForExit(500);
                }
            }
            catch (InvalidOperationException)
            {
            }
            finally
            {
                stopping.Dispose();
            }
        }

        input = null;
        output = null;
        pending = [];
    }

    private async Task<EmbedResponse> ExchangeAsync(EmbedRequest request, CancellationToken cancellationToken)
    {
        var wire = EmbedProtocol.EncodeLine(request);
        if (wire.Length > EmbedProtocol.MaxLineBytes)
        {
            throw EmbeddingException.Invalid("Request exceeds 64 MiB");
        }

        Start();
        cancellationToken.ThrowIfCancellationRequested();
        using var timeoutSource = new CancellationTokenSource(TimeSpan.FromSeconds(timeout));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(timeoutSource.Token, aborted.Token);
        try
        {
            await input!.WriteAsync(wire, linked.Token).ConfigureAwait(false);
            await input.FlushAsync(linked.Token).ConfigureAwait(false);
            int newline;
            var buffer = new byte[16_384];
            while ((newline = Array.IndexOf(pending, (byte)10)) < 0)
            {
                var count = await output!.ReadAsync(buffer, linked.Token).ConfigureAwait(false);
                if (count <= 0)
                {
                    throw EmbeddingException.Transport("Helper stdout closed");
                }

                var combined = new byte[pending.Length + count];
                pending.CopyTo(combined, 0);
                buffer.AsSpan(0, count).CopyTo(combined.AsSpan(pending.Length));
                pending = combined;
                if (pending.Length > EmbedProtocol.MaxLineBytes)
                {
                    throw EmbeddingException.Transport("Helper response exceeds 64 MiB");
                }
            }

            var response = EmbedProtocol.DecodeLine<EmbedResponse>(pending.AsSpan(0, newline));
            pending = pending[(newline + 1)..];
            if (response.Id != request.Id || response.ModelId != Embedder.ModelID || response.Dimensions != request.Dimensions)
            {
                throw EmbeddingException.Transport("Helper response ID, model or dimensions mismatch");
            }

            return response;
        }
        catch (OperationCanceledException) when (timeoutSource.IsCancellationRequested && !aborted.IsCancellationRequested)
        {
            throw EmbeddingException.Transport("Helper request timed out");
        }
        catch (IOException error)
        {
            throw EmbeddingException.Transport($"Helper pipe failed: {error.Message}");
        }
        catch (ObjectDisposedException)
        {
            throw EmbeddingException.Transport("Helper pipe closed");
        }
    }
}
