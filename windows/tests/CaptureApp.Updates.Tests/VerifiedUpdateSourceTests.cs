using System.Text;
using CaptureApp.Updates;
using Velopack.Logging;
using Xunit;

namespace CaptureApp.Updates.Tests;

public sealed class VerifiedUpdateSourceTests
{
    private const string Channel = "win-x64";
    private static readonly Uri BaseUri = new("https://updates.example.test/win-x64/");
    private static readonly byte[] Feed = Encoding.UTF8.GetBytes("{\"Assets\":[]}");

    private static (TrustedKeys Trusted, byte[] Signature) SignFeed()
    {
        var (seed, publicKey) = IndexSignature.GenerateKeyPair();
        var keyId = IndexSignature.KeyIdFor(publicKey);
        var trusted = TrustedKeys.Parse($"{keyId}:{Convert.ToBase64String(publicKey)}");
        return (trusted, Encoding.UTF8.GetBytes(IndexSignature.Sign(Feed, Channel, keyId, seed)));
    }

    private static bool IsSignatureRequest(Uri uri) => uri.AbsolutePath.EndsWith(".sig", StringComparison.Ordinal);

    private static VerifiedUpdateSource NewSource(IIndexFetcher fetcher, TrustedKeys trusted) =>
        new(new FixedLocator(), fetcher, trusted);

    private sealed class FixedLocator : IIndexLocator
    {
        public Task<IndexLocation> LocateAsync(string channel, CancellationToken cancellationToken) =>
            Task.FromResult(new IndexLocation(BaseUri));
    }

    private sealed class FakeIndexFetcher(Func<Uri, Task<byte[]>> respond) : IIndexFetcher
    {
        public Task<byte[]> GetBytesAsync(Uri uri, CancellationToken cancellationToken) => respond(uri);

        public Task<Uri> ResolveRedirectAsync(Uri uri, CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    [Fact]
    public async Task IndexAndSignatureAreRequestedConcurrently()
    {
        var (trusted, signature) = SignFeed();
        var signatureRequested = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var fetcher = new FakeIndexFetcher(async uri =>
        {
            if (IsSignatureRequest(uri))
            {
                signatureRequested.TrySetResult();
                return signature;
            }

            // Completes only after the signature is requested, so a sequential fetch never returns.
            await signatureRequested.Task;
            return Feed;
        });

        var feed = await NewSource(fetcher, trusted)
            .GetReleaseFeed(new NullVelopackLogger(), null, Channel)
            .WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Empty(feed.Assets);
    }

    [Fact]
    public async Task MissingSignatureIsRefused()
    {
        var (trusted, _) = SignFeed();
        var fetcher = new FakeIndexFetcher(uri => IsSignatureRequest(uri)
            ? Task.FromException<byte[]>(new UpdateHttpException(404, null, "Update server returned 404 for releases.win-x64.json.sig."))
            : Task.FromResult(Feed));

        var error = await Assert.ThrowsAsync<IndexVerificationException>(() =>
            NewSource(fetcher, trusted).GetReleaseFeed(new NullVelopackLogger(), null, Channel));

        Assert.Equal(IndexRejection.MissingSignature, error.Reason);
    }

    [Fact]
    public async Task IndexErrorTakesPrecedenceOverSignatureError()
    {
        var (trusted, _) = SignFeed();
        var fetcher = new FakeIndexFetcher(uri => IsSignatureRequest(uri)
            ? Task.FromException<byte[]>(new UpdateHttpException(503, null, "Update server returned 503 for releases.win-x64.json.sig."))
            : Task.FromException<byte[]>(new UpdateHttpException(500, null, "Update server returned 500 for releases.win-x64.json.")));

        var error = await Assert.ThrowsAsync<UpdateHttpException>(() =>
            NewSource(fetcher, trusted).GetReleaseFeed(new NullVelopackLogger(), null, Channel));

        Assert.Equal(500, error.StatusCode);
    }
}
