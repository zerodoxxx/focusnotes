namespace CaptureApp.Updates;

/// <summary>Names in the published Windows update feed. The values are part of the release contract.</summary>
public static class FeedNames
{
    public const string SignatureSuffix = ".sig";

    public static string IndexFile(string channel) => $"releases.{channel}.json";

    public static string SignatureFile(string channel) => IndexFile(channel) + SignatureSuffix;

    public static string LatestReleaseUrl(string githubRepo) => $"https://github.com/{githubRepo}/releases/latest";
}
