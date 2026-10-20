using System.Text;
using Velopack;
using Velopack.Logging;
using Velopack.Sources;

namespace CaptureApp.Updates;

/// <summary>
/// Fetches <c>releases.&lt;channel&gt;.json</c> plus its <c>.sig</c>, refuses anything not signed by a
/// trusted key for this channel, then hands package downloads to a plain Velopack web source
/// (Velopack itself enforces the package hashes listed in the verified index).
/// </summary>
public sealed class VerifiedUpdateSource(
    IIndexLocator locator,
    IIndexFetcher fetcher,
    TrustedKeys trusted,
    Func<Uri, IUpdateSource>? downloads = null) : IUpdateSource
{
    private readonly Func<Uri, IUpdateSource> downloadSource = downloads ?? (baseUri => new SimpleWebSource(baseUri));
    private IUpdateSource? current;

    public async Task<VelopackAssetFeed> GetReleaseFeed(IVelopackLogger logger, string? appId, string channel, Guid? stagingId = null, VelopackAsset? latestLocalRelease = null)
    {
        current = null;
        if (string.IsNullOrEmpty(channel))
        {
            throw new IndexVerificationException(IndexRejection.ChannelMismatch, "The app has no update channel.");
        }

        var location = await locator.LocateAsync(channel, CancellationToken.None).ConfigureAwait(false);
        var indexUri = location.For($"releases.{channel}.json");
        var index = await fetcher.GetBytesAsync(indexUri, CancellationToken.None).ConfigureAwait(false);
        string? signature = null;
        try
        {
            signature = Encoding.UTF8.GetString(await fetcher.GetBytesAsync(location.For($"releases.{channel}.json.sig"), CancellationToken.None).ConfigureAwait(false));
        }
        catch (UpdateHttpException error) when (error.StatusCode == 404)
        {
            // Reported below as a missing signature.
        }

        IndexSignature.Verify(index, signature, channel, trusted);
        VelopackAssetFeed feed;
        try
        {
            feed = VelopackAssetFeed.FromJson(Encoding.UTF8.GetString(index));
        }
        catch (Exception error) when (error is System.Text.Json.JsonException or ArgumentException or InvalidOperationException)
        {
            throw new IndexVerificationException(IndexRejection.MalformedSignature, "The update index is malformed.");
        }

        current = downloadSource(location.BaseUri);
        return feed;
    }

    public Task DownloadReleaseEntry(IVelopackLogger logger, VelopackAsset releaseEntry, string localFile, Action<int> progress, CancellationToken cancelToken) =>
        (current ?? throw new InvalidOperationException("Download requested before the update index was verified."))
            .DownloadReleaseEntry(logger, releaseEntry, localFile, progress, cancelToken);
}
