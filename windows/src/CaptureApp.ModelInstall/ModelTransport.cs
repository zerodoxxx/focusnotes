using System.Net;
using System.Net.Http.Headers;

namespace CaptureApp.ModelInstall;

/// Fetches one URL into a file. The installer resumes partial files through the offset.
public interface IModelTransport
{
    /// Downloads <paramref name="url"/> into <paramref name="file"/>.
    /// With an offset above zero it sends "Range: bytes=offset-". A 206 appends to the file, a 200
    /// truncates it and writes the full body, a 416 writes nothing (the caller verifies the hash), and
    /// any other non-2xx status throws <see cref="ModelInstallException"/>. <paramref name="progress"/>
    /// receives the file's total length on disk after each chunk is written.
    Task DownloadAsync(Uri url, string file, long offset, Action<long> progress, CancellationToken cancellationToken);
}

/// Production transport: HTTPS only, no cookies or cache, resumes with Range requests. Redirects are
/// followed by hand so every hop is checked for HTTPS.
public sealed class HttpModelTransport : IModelTransport, IDisposable
{
    private const int MaxRedirects = 10;
    private static readonly TimeSpan Stall = TimeSpan.FromSeconds(60);

    private readonly HttpClient client;
    private readonly bool requireHttps;
    private readonly string userAgent;

    /// <param name="requireHttps">Tests serving from a loopback HttpListener turn this off.</param>
    public HttpModelTransport(HttpMessageHandler? handler = null, bool requireHttps = true, string? userAgent = null)
    {
        client = new HttpClient(handler ?? new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false }, disposeHandler: true)
        {
            Timeout = Timeout.InfiniteTimeSpan
        };
        this.requireHttps = requireHttps;
        this.userAgent = userAgent ?? $"{CaptureApp.Core.AppInfo.Name}/{CaptureApp.Core.AppInfo.Version}";
    }

    public async Task DownloadAsync(Uri url, string file, long offset, Action<long> progress, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await SendAsync(url, offset, cancellationToken).ConfigureAwait(false);
            await WriteAsync(response, file, offset, progress, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException error)
        {
            throw ModelInstallException.Network(error.Message);
        }
    }

    private async Task<HttpResponseMessage> SendAsync(Uri url, long offset, CancellationToken cancellationToken)
    {
        for (var hop = 0; ; hop++)
        {
            if (requireHttps && !string.Equals(url.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            {
                throw ModelInstallException.InsecureRedirect();
            }

            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.UserAgent.ParseAdd(userAgent);
            if (offset > 0)
            {
                request.Headers.Range = new RangeHeaderValue(offset, null);
            }

            using var headerTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            headerTimeout.CancelAfter(Stall);
            HttpResponseMessage response;
            try
            {
                response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, headerTimeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw ModelInstallException.Network("the server did not respond in time");
            }

            if (response.StatusCode is HttpStatusCode.MovedPermanently or HttpStatusCode.Found or HttpStatusCode.SeeOther
                or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect && response.Headers.Location is { } location)
            {
                response.Dispose();
                if (hop >= MaxRedirects)
                {
                    throw ModelInstallException.Network("too many redirects");
                }

                url = new Uri(url, location);
                continue;
            }

            return response;
        }
    }

    private static async Task WriteAsync(HttpResponseMessage response, string file, long offset, Action<long> progress, CancellationToken cancellationToken)
    {
        var status = (int)response.StatusCode;
        FileStream? target;
        switch (status)
        {
            case 206:
                target = new FileStream(file, FileMode.OpenOrCreate, FileAccess.Write, FileShare.None);
                if (target.Seek(0, SeekOrigin.End) != offset)
                {
                    await target.DisposeAsync().ConfigureAwait(false);
                    // Retryable: the installer re-reads the partial's real size and resumes from there, or starts over.
                    throw ModelInstallException.Network("the partial download changed while it was being resumed");
                }

                break;
            case 416:
                return;
            case >= 200 and < 300:
                target = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.None);
                break;
            default:
                throw ModelInstallException.HttpStatus(status, response.RequestMessage?.RequestUri?.Host ?? "the server");
        }

        await using (target.ConfigureAwait(false))
        {
            await using var body = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            var buffer = new byte[81_920];
            while (true)
            {
                using var stall = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                stall.CancelAfter(Stall);
                int count;
                try
                {
                    count = await body.ReadAsync(buffer, stall.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    throw ModelInstallException.Network("the connection stalled");
                }
                catch (IOException error)
                {
                    throw ModelInstallException.Network(error.Message);
                }

                if (count == 0)
                {
                    return;
                }

                await target.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                progress(target.Length);
            }
        }
    }

    public void Dispose() => client.Dispose();
}
