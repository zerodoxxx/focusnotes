using System.Globalization;

namespace CaptureApp.Updates;

/// <summary>Semantic-version ordering for update bookkeeping (prerelease sorts before the release).</summary>
public static class VersionOrder
{
    public static int Compare(string? left, string? right)
    {
        var (leftCore, leftPre) = Split(left);
        var (rightCore, rightPre) = Split(right);
        for (var i = 0; i < 3; i++)
        {
            var order = leftCore[i].CompareTo(rightCore[i]);
            if (order != 0)
            {
                return order;
            }
        }

        if (leftPre.Length == 0 || rightPre.Length == 0)
        {
            return rightPre.Length.CompareTo(leftPre.Length);
        }

        for (var i = 0; i < Math.Min(leftPre.Length, rightPre.Length); i++)
        {
            var leftNumeric = long.TryParse(leftPre[i], NumberStyles.None, CultureInfo.InvariantCulture, out var a);
            var rightNumeric = long.TryParse(rightPre[i], NumberStyles.None, CultureInfo.InvariantCulture, out var b);
            var order = leftNumeric && rightNumeric
                ? a.CompareTo(b)
                : leftNumeric ? -1 : rightNumeric ? 1 : string.CompareOrdinal(leftPre[i], rightPre[i]);
            if (order != 0)
            {
                return Math.Sign(order);
            }
        }

        return leftPre.Length.CompareTo(rightPre.Length);
    }

    private static (long[] Core, string[] Pre) Split(string? version)
    {
        var text = (version ?? "").Trim().TrimStart('v');
        var plus = text.IndexOf('+');
        if (plus >= 0)
        {
            text = text[..plus];
        }

        var dash = text.IndexOf('-');
        var pre = dash >= 0 ? text[(dash + 1)..].Split('.') : [];
        var parts = (dash >= 0 ? text[..dash] : text).Split('.');
        var core = new long[3];
        for (var i = 0; i < 3 && i < parts.Length; i++)
        {
            long.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out core[i]);
        }

        return (core, pre);
    }
}
