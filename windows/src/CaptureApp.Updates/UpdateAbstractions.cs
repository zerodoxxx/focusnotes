namespace CaptureApp.Updates;

/// <summary>A downloadable update. <see cref="Handle"/> is the client's own object (Velopack's UpdateInfo).</summary>
public sealed record UpdateOffer(string Version, object Handle);

public interface IUpdateClient
{
    /// <summary>Returns the newest offer, or null when up to date. Throws <see cref="IndexVerificationException"/> on a refused index.</summary>
    Task<UpdateOffer?> CheckAsync(CancellationToken cancellationToken);

    Task DownloadAsync(UpdateOffer offer, Action<int> progress, CancellationToken cancellationToken);

    /// <summary>Deletes the downloaded packages of <paramref name="version"/> (after repeated apply failures).</summary>
    void DiscardDownloads(string version);
}

/// <summary>The App calls its shutdown drain before invoking either method.</summary>
public interface IUpdateApplier
{
    void ApplyAndRestart(UpdateOffer offer);

    void ApplyOnExit(UpdateOffer offer);
}

/// <summary>Carries <c>Retry-After</c> from the server so the backoff can honour it.</summary>
public sealed class UpdateHttpException(int statusCode, TimeSpan? retryAfter, string message) : Exception(message)
{
    public int StatusCode { get; } = statusCode;

    public TimeSpan? RetryAfter { get; } = retryAfter;
}
