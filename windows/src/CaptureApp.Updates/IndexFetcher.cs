using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace CaptureApp.Updates;

public interface IIndexFetcher
{
    Task<byte[]> GetBytesAsync(Uri uri, CancellationToken cancellationToken);

    /// <summary>Returns the target of the first redirect (without following it).</summary>
    Task<Uri> ResolveRedirectAsync(Uri uri, CancellationToken cancellationToken);
}

/// <summary>HttpClient fetcher that surfaces <c>Retry-After</c> through <see cref="UpdateHttpException"/>.</summary>
public sealed class HttpIndexFetcher(HttpClient? client = null, HttpClient? noRedirectClient = null) : IIndexFetcher
{
    private readonly HttpClient http = client ?? CreateClient();
    private readonly HttpClient noRedirect = noRedirectClient ?? CreateClient(followRedirects: false);

    public async Task<Uri> ResolveRedirectAsync(Uri uri, CancellationToken cancellationToken)
    {
        using var response = await noRedirect.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } location)
        {
            return location.IsAbsoluteUri ? location : new Uri(uri, location);
        }

        throw new UpdateHttpException((int)response.StatusCode, RetryAfter(response), $"Expected a redirect from {uri.AbsolutePath}, got {(int)response.StatusCode}.");
    }

    public async Task<byte[]> GetBytesAsync(Uri uri, CancellationToken cancellationToken)
    {
        using var response = await http.GetAsync(uri, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new UpdateHttpException((int)response.StatusCode, RetryAfter(response), $"Update server returned {(int)response.StatusCode} for {uri.AbsolutePath}.");
        }

        return await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
    }

    public static TimeSpan? RetryAfter(HttpResponseMessage response)
    {
        var header = response.Headers.RetryAfter;
        if (header?.Delta is { } delta)
        {
            return delta > TimeSpan.Zero ? delta : null;
        }

        if (header?.Date is { } date)
        {
            var wait = date - DateTimeOffset.UtcNow;
            return wait > TimeSpan.Zero ? wait : null;
        }

        // GitHub signals primary rate limits with a reset epoch instead of Retry-After.
        if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests
            && response.Headers.TryGetValues("X-RateLimit-Remaining", out var remaining) && remaining.FirstOrDefault() == "0"
            && response.Headers.TryGetValues("X-RateLimit-Reset", out var reset)
            && long.TryParse(reset.FirstOrDefault(), NumberStyles.None, CultureInfo.InvariantCulture, out var epoch))
        {
            var wait = DateTimeOffset.FromUnixTimeSeconds(epoch) - DateTimeOffset.UtcNow;
            return wait > TimeSpan.Zero ? wait : null;
        }

        return null;
    }

    private static HttpClient CreateClient(bool followRedirects = true)
    {
        var created = new HttpClient(new HttpClientHandler { AllowAutoRedirect = followRedirects }) { Timeout = TimeSpan.FromSeconds(30) };
        created.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("CaptureApp-Updater", "1"));
        created.DefaultRequestHeaders.Accept.ParseAdd("application/json, application/octet-stream, */*");
        return created;
    }
}

/// <summary>Where the index, signature and packages of a channel live: all siblings under <see cref="BaseUri"/>.</summary>
public sealed record IndexLocation(Uri BaseUri)
{
    public Uri For(string fileName) => new(BaseUri, fileName);
}

public interface IIndexLocator
{
    Task<IndexLocation> LocateAsync(string channel, CancellationToken cancellationToken);
}

/// <summary>
/// Stable channel: <c>releases/latest</c> is resolved once per check to its concrete tag, so the
/// index and the package downloads come from the same release (still no API rate limit).
/// </summary>
public sealed class StableIndexLocator(string githubRepo, IIndexFetcher fetcher) : IIndexLocator
{
    public async Task<IndexLocation> LocateAsync(string channel, CancellationToken cancellationToken)
    {
        var target = await fetcher.ResolveRedirectAsync(new Uri($"https://github.com/{githubRepo}/releases/latest"), cancellationToken).ConfigureAwait(false);
        const string Marker = "/releases/tag/";
        var path = target.AbsolutePath;
        var at = path.IndexOf(Marker, StringComparison.Ordinal);
        if (at < 0 || at + Marker.Length >= path.Length)
        {
            throw new InvalidOperationException("The latest release could not be resolved.");
        }

        var tag = path[(at + Marker.Length)..].Trim('/');
        return new IndexLocation(new Uri($"https://github.com/{githubRepo}/releases/download/{tag}/"));
    }
}

/// <summary>Beta channel: the newest non-draft release (prereleases included) that carries the signed index.</summary>
public sealed class PrereleaseIndexLocator(string githubRepo, IIndexFetcher fetcher) : IIndexLocator
{
    public async Task<IndexLocation> LocateAsync(string channel, CancellationToken cancellationToken)
    {
        var bytes = await fetcher.GetBytesAsync(new Uri($"https://api.github.com/repos/{githubRepo}/releases?per_page=15"), cancellationToken).ConfigureAwait(false);
        using var document = JsonDocument.Parse(bytes);
        var index = $"releases.{channel}.json";
        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (release.TryGetProperty("draft", out var draft) && draft.GetBoolean())
            {
                continue;
            }

            if (!release.TryGetProperty("assets", out var assets) || !release.TryGetProperty("tag_name", out var tag))
            {
                continue;
            }

            var names = assets.EnumerateArray().Select(asset => asset.GetProperty("name").GetString()).ToHashSet(StringComparer.Ordinal);
            if (names.Contains(index) && names.Contains(index + ".sig"))
            {
                return new IndexLocation(new Uri($"https://github.com/{githubRepo}/releases/download/{Uri.EscapeDataString(tag.GetString()!)}/"));
            }
        }

        throw new InvalidOperationException($"No release publishes {index}.");
    }
}
