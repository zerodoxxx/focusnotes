using System.IO.Pipes;
using System.Text;
using CaptureApp.Core;

namespace CaptureApp.AppCore;

/// Owns the per-user lock and show-handoff pipe for the lifetime of the primary process.
public sealed class SingleInstance : IAsyncDisposable
{
    private readonly FileStream lockFile;
    private readonly CancellationTokenSource stopping = new();
    private readonly Action? onShow;
    private readonly AppLog logger;
    private readonly Task pipeServer;

    public string StateDirectory { get; }
    public string PipeName { get; }

    private SingleInstance(string stateDirectory, FileStream lockFile, Action? onShow, string pipeName)
    {
        StateDirectory = stateDirectory;
        this.lockFile = lockFile;
        this.onShow = onShow;
        PipeName = pipeName;
        logger = new(stateDirectory, "single-instance");
        pipeServer = Task.Run(ListenAsync);
    }

    /// Returns a handle for the primary process, or null after sending "show" to the existing process.
    public static Task<SingleInstance?> StartAsync(string stateDirectory, Action? onShow = null,
        CancellationToken cancellationToken = default)
        => StartAsync(stateDirectory, CurrentPipeName(), onShow, cancellationToken);

    // Tests supply an isolated handoff pipe without contacting a running desktop instance.
    internal static async Task<SingleInstance?> StartAsync(string stateDirectory, string pipeName, Action? onShow = null,
        CancellationToken cancellationToken = default)
    {
        var fullPath = Path.GetFullPath(stateDirectory);
        Directory.CreateDirectory(fullPath);
        FileStream lockFile;
        try
        {
            lockFile = new FileStream(Path.Combine(fullPath, "instance.lock"), FileMode.OpenOrCreate,
                FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException lockError)
        {
            if (cancellationToken.IsCancellationRequested) { throw new OperationCanceledException(cancellationToken); }
            try
            {
                await SendShowAsync(pipeName, cancellationToken).ConfigureAwait(false);
                return null;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception pipeError) when (pipeError is IOException or TimeoutException or OperationCanceledException)
            {
                throw new IOException("Another process owns the instance lock but did not accept the show request.",
                    new AggregateException(lockError, pipeError));
            }
        }

        try
        {
            return new(fullPath, lockFile, onShow, pipeName);
        }
        catch
        {
            lockFile.Dispose();
            throw;
        }
    }

    public static string CurrentPipeName()
    {
        var user = new string(Environment.UserName.Select(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' ? c : '_').ToArray());
        if (user.Length == 0) { user = "user"; }
        return AppInfo.BundleId + "." + user + ".show";
    }

    private async Task ListenAsync()
    {
        while (!stopping.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await server.WaitForConnectionAsync(stopping.Token).ConfigureAwait(false);
                using var reader = new StreamReader(server, Encoding.UTF8, false, 1024, true);
                var command = await reader.ReadLineAsync(stopping.Token).ConfigureAwait(false);
                if (string.Equals(command, "show", StringComparison.Ordinal))
                {
                    try { onShow?.Invoke(); }
                    catch (Exception error) { logger.Error($"Show handoff handler failed: {error}"); }
                }
            }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested)
            {
                return;
            }
            catch (ObjectDisposedException) when (stopping.IsCancellationRequested)
            {
                return;
            }
            catch (IOException error) when (!stopping.IsCancellationRequested)
            {
                logger.Error($"Show handoff pipe failed: {error}");
                try { await Task.Delay(TimeSpan.FromMilliseconds(100), stopping.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) when (stopping.IsCancellationRequested) { return; }
            }
        }
    }

    private static async Task SendShowAsync(string pipeName, CancellationToken cancellationToken)
    {
        await using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out, PipeOptions.Asynchronous);
        await client.ConnectAsync(3000, cancellationToken).ConfigureAwait(false);
        var command = Encoding.UTF8.GetBytes("show\n");
        await client.WriteAsync(command, cancellationToken).ConfigureAwait(false);
        await client.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        stopping.Cancel();
        try { await pipeServer.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        lockFile.Dispose();
        stopping.Dispose();
    }
}
