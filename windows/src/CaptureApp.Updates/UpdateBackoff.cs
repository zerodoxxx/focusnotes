namespace CaptureApp.Updates;

/// <summary>Failure backoff: 1 h, 4 h, 12 h, then 24 h; a server <c>Retry-After</c> can only lengthen the wait, capped at 24 h.</summary>
public static class UpdateBackoff
{
    public static readonly TimeSpan RegularInterval = TimeSpan.FromHours(24);

    private static readonly TimeSpan[] Steps =
    [
        TimeSpan.FromHours(1),
        TimeSpan.FromHours(4),
        TimeSpan.FromHours(12),
        TimeSpan.FromHours(24),
    ];

    public static TimeSpan Delay(int consecutiveFailures, TimeSpan? retryAfter = null)
    {
        var index = Math.Clamp(consecutiveFailures, 1, Steps.Length) - 1;
        var delay = Steps[index];
        // Ignore negative/zero hints; a hostile or buggy server can't stall checks beyond 24 h.
        return retryAfter is { } server && server > delay ? (server > RegularInterval ? RegularInterval : server) : delay;
    }
}
