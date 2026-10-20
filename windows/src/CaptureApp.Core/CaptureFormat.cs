using System.Globalization;

namespace CaptureApp.Core;

public static class CaptureFormat
{
    public const string MarkerPrefix = "<!-- capture:";
    public const string MarkerSuffix = " -->";
    public static string NoteHeader(string title) => $"# {title}\n";
    public static string Block(Capture capture, string noteRelativeDir, TimeZoneInfo timeZone, bool includeSourceHeading = true, string? assetPathPrefix = null)
    {
        var id = capture.Id.ToString("D");
        if (capture.Content.Kind == CaptureContentKind.Subheading)
        {
            return $"## {CleanSubheading(capture.Content.Value)}\n<!-- subheading:{id} -->\n";
        }

        var stamp = LocalStamp(capture.CreatedAt, "yyyy-MM-dd'T'HH:mm:ss", timeZone);
        if (capture.Content.Kind == CaptureContentKind.Note)
        {
            return $"<!-- note:{id} at={stamp} -->\n\n{NoteBody(capture.Content.Value)}\n";
        }

        var body = capture.Content.Kind == CaptureContentKind.Image ? ImageBody(capture.Content.Value, noteRelativeDir, assetPathPrefix) : TextBody(capture.Content.Value);
        return (includeSourceHeading ? $"### {SourceHeading(capture.Source)}\n" : "") + $"{MarkerPrefix}{id} at={stamp} app=\"{EscapeMetadata(CleanPart(capture.Source.AppName))}\"{MarkerSuffix}\n\n{body}\n";
    }

    public static string SourceHeading(CaptureSource source)
    {
        var window = CleanPart(source.WindowTitle);
        foreach (var browser in new[]
        {
            "Mozilla Firefox",
            "Google Chrome",
            "Brave",
            "Safari",
            "Firefox",
            "Microsoft Edge"
        }

        )
            foreach (var separator in new[]
            {
                " — ",
                " - ",
                " – "
            }

            )
            {
                var suffix = separator + browser;
                if (window.EndsWith(suffix, StringComparison.Ordinal))
                {
                    window = window[..^suffix.Length];
                }
            }

        window = NoteTitle.CleanTitle(window);
        if (NoteTitle.Graphemes(window).Count > 80)
        {
            window = string.Concat(NoteTitle.Graphemes(window).Take(80)) + "…";
        }

        return window.Length > 0 ? window : CleanPart(source.AppName) is { Length: > 0 } app ? app : "Unknown source";
    }

    public static string NoteBody(string text) => text.TrimEnd();
    public static string CleanSubheading(string text) => NoteTitle.CleanTitle(NoteTitle.CleanTitle(text).TrimStart('#', ' ', '\t', '\r', '\n'));
    public static string CleanPart(string? text) => NoteTitle.CleanTitle((text ?? "").Replace('·', '-'));
    public static string EscapeMetadata(string text) => text.Replace("&", "&amp;", StringComparison.Ordinal).Replace("\"", "&quot;", StringComparison.Ordinal).Replace("-", "&#45;", StringComparison.Ordinal).Replace("<", "&lt;", StringComparison.Ordinal).Replace(">", "&gt;", StringComparison.Ordinal);
    public static string UnescapeMetadata(string text) => text.Replace("&quot;", "\"", StringComparison.Ordinal).Replace("&#45;", "-", StringComparison.Ordinal).Replace("&lt;", "<", StringComparison.Ordinal).Replace("&gt;", ">", StringComparison.Ordinal).Replace("&amp;", "&", StringComparison.Ordinal);
    public static string LocalStamp(DateTimeOffset date, string pattern, TimeZoneInfo timeZone)
    {
        var local = TimeZoneInfo.ConvertTime(date, timeZone);
        var result = local.ToString(pattern, CultureInfo.InvariantCulture);
        if (pattern == "yyyy-MM-dd'T'HH:mm:ss")
        {
            result += local.Offset == TimeSpan.Zero ? "Z" : local.ToString("zzz", CultureInfo.InvariantCulture);
        }

        return result;
    }

    public static string RelativePath(string directory, string target) => Path.GetRelativePath(directory, target).Replace(Path.DirectorySeparatorChar, '/');
    private static string ImageBody(string asset, string directory, string? prefix)
    {
        var path = prefix is null ? string.Concat(Enumerable.Repeat("../", directory.Split('/', StringSplitOptions.RemoveEmptyEntries).Length)) + asset : string.Join('/', prefix.Split('/', StringSplitOptions.RemoveEmptyEntries).Concat(asset.Split('/', StringSplitOptions.RemoveEmptyEntries)));
        return "![](" + string.Join('/', path.Split('/').Select(Uri.EscapeDataString)) + ")";
    }

    private static string TextBody(string text)
    {
        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n').ToList();
        while (lines.Count > 0 && string.IsNullOrWhiteSpace(lines[0]))
        {
            lines.RemoveAt(0);
        }

        while (lines.Count > 0 && string.IsNullOrWhiteSpace(lines[^1]))
        {
            lines.RemoveAt(lines.Count - 1);
        }

        var body = string.Join('\n', lines).TrimEnd();
        return body.Length == 0 ? "(empty)" : body;
    }

    public sealed class FenceState
    {
        private char fence;
        private int length;
        public FenceState Copy() => new()
        {
            fence = fence,
            length = length
        };
        public bool IsVisible(string line)
        {
            var indentation = line.TakeWhile(c => c == ' ').Count();
            var text = line[Math.Min(indentation, 3)..];
            if (indentation <= 3 && text.Length > 0 && text[0] is '`' or '~')
            {
                var count = text.TakeWhile(c => c == text[0]).Count();
                var rest = text[count..];
                if (length > 0)
                {
                    if (text[0] == fence && count >= length && string.IsNullOrWhiteSpace(rest))
                    {
                        length = 0;
                    }
                }
                else if (count >= 3 && (text[0] != '`' || !rest.Contains('`')))
                {
                    fence = text[0];
                    length = count;
                }

                if (count >= 3)
                {
                    return false;
                }
            }

            return length == 0;
        }
    }

    public static IReadOnlyList<int> UnfencedLines(IReadOnlyList<string> lines)
    {
        var fence = new FenceState();
        return Enumerable.Range(0, lines.Count).Where(i => fence.IsVisible(lines[i])).ToArray();
    }

    public static (int Level, string Text)? AtxHeading(string line)
    {
        var indent = line.TakeWhile(c => c == ' ').Count();
        if (indent > 3)
        {
            return null;
        }

        var text = line[indent..];
        var level = text.TakeWhile(c => c == '#').Count();
        var rest = text[level..];
        return level is >= 1 and <= 6 && (rest.Length == 0 || char.IsWhiteSpace(rest[0])) ? (level, rest.Trim()) : null;
    }
}
