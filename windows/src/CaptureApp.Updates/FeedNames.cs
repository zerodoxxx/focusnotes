namespace CaptureApp.Updates;

/// <summary>Names in the published Windows update feed. The values are part of the release contract.</summary>
public static class FeedNames
{
    public const string SignatureSuffix = ".sig";
    public const string ChannelPrefix = "win-";

    /// <summary>The update channel for a lower-case process architecture, e.g. "win-x64".</summary>
    public static string Channel(string architecture) => ChannelPrefix + architecture;

    public static string IndexFile(string channel) => $"releases.{channel}.json";

    public static string SignatureFile(string channel) => IndexFile(channel) + SignatureSuffix;

    public static string LatestReleaseUrl(string githubRepo) => $"https://github.com/{githubRepo}/releases/latest";
}
