namespace CaptureApp.Core;

internal static class TempNames
{
    internal const string PendingPrefix = ".pending-";
    internal const string RecoveredPrefix = ".recovered-";
    internal const int MaxRestorableNameBytes = 100;
    private static readonly System.Text.RegularExpressions.Regex PendingName =
        new("^" + System.Text.RegularExpressions.Regex.Escape(PendingPrefix) + "[0-9a-f]{32}$");
    internal static readonly System.Text.RegularExpressions.Regex RecoveredPattern =
        new("^" + System.Text.RegularExpressions.Regex.Escape(RecoveredPrefix) + "(?<id>[0-9a-f]{32})-(?<target>[0-9a-f]{2," + 2 * MaxRestorableNameBytes + "})\\z");

    internal static bool IsPending(string name) => PendingName.IsMatch(name);
}
