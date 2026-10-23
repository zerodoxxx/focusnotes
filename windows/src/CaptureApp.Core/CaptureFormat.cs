using System.Globalization;
using System.Text;

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
        var sourceLink = SourceLink(capture.Source);
        return (includeSourceHeading ? $"### {SourceHeading(capture.Source)}\n" : "") + $"{MarkerPrefix}{id} at={stamp} app=\"{EscapeMetadata(CleanPart(capture.Source.AppName))}\"{MarkerSuffix}\n\n" +
               (sourceLink is null ? "" : sourceLink + "\n\n") + body + "\n";
    }

    /// <summary>
    /// Formats only absolute HTTP(S) source URLs. Angle brackets isolate Markdown syntax,
    /// and encoded parentheses keep the editor's link recognizer from ending the URL early.
    /// </summary>
    internal static string? SourceLink(CaptureSource source)
    {
        var value = source.Url;
        if (string.IsNullOrEmpty(value)) return null;

        static bool IsUnreservedOrSubDelimiter(Rune rune)
        {
            if (rune.Value is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9') return true;
            return "-._~!$&'()*+,;=".Contains((char)rune.Value);
        }

        static bool IsValidComponent(string component, bool allowColon, bool allowAt,
            bool allowSlash, bool allowQuestion, bool allowMarkdownEscapes)
        {
            foreach (var rune in component.EnumerateRunes())
            {
                if (IsUnreservedOrSubDelimiter(rune) || rune.Value > 0x7F || rune.Value == '%') continue;
                if (allowColon && rune.Value == ':') continue;
                if (allowAt && rune.Value == '@') continue;
                if (allowSlash && rune.Value == '/') continue;
                if (allowQuestion && rune.Value == '?') continue;
                if (allowMarkdownEscapes && rune.Value is '<' or '>' or '\\') continue;
                return false;
            }

            return true;
        }

        foreach (var rune in value.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (Rune.IsWhiteSpace(rune) || category is UnicodeCategory.Control or UnicodeCategory.Format or
                UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator) return null;
        }

        for (var index = 0; index < value.Length; index++)
        {
            if (value[index] != '%') continue;
            if (index + 2 >= value.Length || !char.IsAsciiHexDigit(value[index + 1]) || !char.IsAsciiHexDigit(value[index + 2])) return null;
            index += 2;
        }

        var schemeEnd = value.IndexOf(':');
        if (schemeEnd <= 0) return null;
        var scheme = value[..schemeEnd].ToLowerInvariant();
        if (scheme is not ("http" or "https") || !value.AsSpan(schemeEnd + 1).StartsWith("//")) return null;

        var authorityStart = schemeEnd + 3;
        var authorityEnd = value.IndexOfAny(['/','?','#'], authorityStart);
        if (authorityEnd < 0) authorityEnd = value.Length;
        var authority = value[authorityStart..authorityEnd];
        if (authority.Length == 0) return null;
        var at = authority.IndexOf('@');
        if (at >= 0)
        {
            if (at != authority.LastIndexOf('@') || !IsValidComponent(authority[..at], true, false, false, false, true)) return null;
        }

        var hostPort = at >= 0 ? authority[(at + 1)..] : authority;
        if (hostPort.Length == 0) return null;
        string? port = null;
        if (hostPort[0] == '[')
        {
            var close = hostPort.IndexOf(']');
            if (close <= 1) return null;
            var literal = hostPort[1..close];
            if (!literal.Contains(':') || literal.Any(c => !(char.IsAsciiHexDigit(c) || c is ':' or '.' or '%'))) return null;
            var suffix = hostPort[(close + 1)..];
            if (suffix.Length > 0)
            {
                if (suffix[0] != ':') return null;
                port = suffix[1..];
            }
        }
        else
        {
            var colon = hostPort.IndexOf(':');
            if (colon >= 0)
            {
                if (colon != hostPort.LastIndexOf(':')) return null;
                port = hostPort[(colon + 1)..];
                if (colon == 0 || !IsValidComponent(hostPort[..colon], false, false, false, false, false)) return null;
            }
            else if (!IsValidComponent(hostPort, false, false, false, false, false)) return null;
        }
        if (port is not null && (port.Length == 0 || !int.TryParse(port, NumberStyles.None, CultureInfo.InvariantCulture, out var portNumber) || portNumber > 65_535)) return null;

        var remainder = value[authorityEnd..];
        var fragmentStart = remainder.IndexOf('#');
        var beforeFragment = fragmentStart >= 0 ? remainder[..fragmentStart] : remainder;
        var fragment = fragmentStart >= 0 ? remainder[(fragmentStart + 1)..] : null;
        var queryStart = beforeFragment.IndexOf('?');
        var path = queryStart >= 0 ? beforeFragment[..queryStart] : beforeFragment;
        var query = queryStart >= 0 ? beforeFragment[(queryStart + 1)..] : null;
        if ((path.Length > 0 && path[0] != '/') ||
            !IsValidComponent(path, true, true, true, false, true) ||
            (query is not null && !IsValidComponent(query, true, true, true, true, true)) ||
            (fragment is not null && !IsValidComponent(fragment, true, true, true, true, true))) return null;

        var normalized = scheme + value[schemeEnd..]
            .Replace("<", "%3C", StringComparison.Ordinal)
            .Replace(">", "%3E", StringComparison.Ordinal)
            .Replace("\\", "%5C", StringComparison.Ordinal)
            .Replace("(", "%28", StringComparison.Ordinal)
            .Replace(")", "%29", StringComparison.Ordinal);
        if (!Uri.TryCreate(normalized, UriKind.Absolute, out var parsed) || parsed.Scheme != scheme || string.IsNullOrEmpty(parsed.Host)) return null;
        return $"[Source](<{normalized}>)";
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
