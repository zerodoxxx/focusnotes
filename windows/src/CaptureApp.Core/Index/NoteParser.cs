using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace CaptureApp.Core.Index;

public enum BlockKind
{
    Text,
    Image,
    Loose,
    Note
}

public sealed record ParsedBlock(Guid? CaptureId, BlockKind Kind, DateTimeOffset? CreatedAt, string? SourceApp, string? WindowTitle, string Body, string? AssetPath);
public sealed record ParsedNote(string Title, IReadOnlyList<ParsedBlock> Blocks);
public static class NoteParser
{
    private sealed record Boundary(int Line, int Marker, Guid? Id, DateTimeOffset? Date, string? App, string? Window, string? Source, bool IsNote = false);
    private sealed record Marker(Guid Id, DateTimeOffset? Date, string? App);
    public static ParsedNote Parse(string contents, string notePath, string titleFallback, TimeZoneInfo timeZone, string? assetRootUrl = null)
    {
        var lines = contents.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        lines[0] = lines[0].TrimStart('\uFEFF');
        var title = titleFallback;
        var start = 0;
        if (lines[0].StartsWith("# ", StringComparison.Ordinal))
        {
            var clean = NoteTitle.CleanTitle(lines[0][2..]);
            if (clean.Length > 0)
            {
                title = clean;
            }

            start = 1;
        }

        var boundaries = Boundaries(lines, start, timeZone);
        var blocks = LooseBlocks(lines.Skip(start).Take((boundaries.FirstOrDefault()?.Line ?? lines.Length) - start));
        for (var i = 0; i < boundaries.Count; i++)
        {
            var b = boundaries[i];
            var from = b.Marker + 1;
            var end = i + 1 < boundaries.Count ? boundaries[i + 1].Line : lines.Length;
            if (from < end && string.IsNullOrWhiteSpace(lines[from]))
            {
                from++;
            }

            while (end > from && string.IsNullOrWhiteSpace(lines[end - 1]))
            {
                end--;
            }

            var body = string.Join('\n', lines[from..end]);
            if (b.Id is null)
            {
                blocks.AddRange(LooseBlocks((lines[b.Line] + (body.Length == 0 ? "" : "\n" + body)).Split('\n')));
                continue;
            }

            var asset = b.IsNote ? null : ImagePath(body, notePath, assetRootUrl);
            blocks.Add(new(b.Id, b.IsNote ? BlockKind.Note : asset is null ? BlockKind.Text : BlockKind.Image, b.Date, b.App, b.Window, body, asset));
        }

        var seen = new HashSet<Guid>();
        var filtered = blocks.AsEnumerable().Reverse().Where(b => b.CaptureId is null || (b.Body.Length > 0 || b.Kind == BlockKind.Note) && seen.Add(b.CaptureId.Value)).Reverse().ToArray();
        return new(title, filtered);
    }

    private static List<Boundary> Boundaries(string[] lines, int start, TimeZoneInfo zone)
    {
        var visible = CaptureFormat.UnfencedLines(lines).ToHashSet();
        string? source = null;
        var result = new List<Boundary>();
        foreach (var i in visible.Order())
        {
            if (i < start)
            {
                continue;
            }

            var line = lines[i];
            if (line.StartsWith("### ", StringComparison.Ordinal))
            {
                source = line[4..];
            }

            if (line.StartsWith("<!-- subheading:", StringComparison.Ordinal) && line.EndsWith(" -->", StringComparison.Ordinal) && Guid.TryParseExact(line[16..^4], "D", out _) && i > start && visible.Contains(i - 1) && CaptureFormat.AtxHeading(lines[i - 1])?.Level == 2)
            {
                result.Add(new(i - 1, i, null, null, null, null, null));
                continue;
            }

            var note = ParseNoteMarker(line);
            if (note is not null)
            {
                result.Add(new(i, i, note.Id, note.Date, null, null, null, true));
                continue;
            }

            var marker = ParseMarker(line);
            if (marker is null)
            {
                continue;
            }

            var preceding = i > start && visible.Contains(i - 1) && lines[i - 1].StartsWith("### ", StringComparison.Ordinal);
            if (marker.Date is null)
            {
                var old = preceding ? ParseHeader(lines[i - 1][4..], zone) : null;
                if (old is null)
                {
                    continue;
                }

                source = CaptureFormat.SourceHeading(new(old.Value.App, old.Value.Window));
                result.Add(new(i - 1, i, marker.Id, old.Value.Date, old.Value.App, old.Value.Window, source));
            }
            else
            {
                result.Add(new(preceding ? i - 1 : i, i, marker.Id, marker.Date, marker.App, source, source));
            }
        }

        return result;
    }

    public static bool NeedsSourceHeading(string source, string contents, TimeZoneInfo timeZone)
    {
        var lines = contents.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        var last = Boundaries(lines, 0, timeZone).LastOrDefault(b => b.Id is not null && !b.IsNote);
        return last is null || last.Source != source || CaptureFormat.UnfencedLines(lines).Any(i => i > last.Marker && CaptureFormat.AtxHeading(lines[i]) is not null);
    }

    /// Streaming state used by the append cache; retained text is bounded by the caller.
    public sealed class SourceHeadingState
    {
        private readonly CaptureFormat.FenceState fence = new();
        private string pending = "";
        private string? previous, source, lastSource;
        private bool hasCapture, headingAfter;
        public int RetainedByteCount => Encoding.UTF8.GetByteCount(pending + previous + source + lastSource);

        public void Consume(string text, TimeZoneInfo zone)
        {
            var lines = (pending + text).Split('\n');
            pending = lines[^1];
            foreach (var raw in lines[..^1])
            {
                ConsumeLine(raw.EndsWith('\r') ? raw[..^1] : raw, zone);
            }
        }

        public bool NeedsHeading(string requested, TimeZoneInfo zone)
        {
            // pending is normally empty (writer blocks end in LF). For an external tail,
            // preserve the state by replaying the pending line into a shallow logical copy.
            if (pending.Length == 0)
            {
                return !hasCapture || lastSource != requested || headingAfter;
            }

            return NeedsWithPending(requested, zone);
        }

        private bool NeedsWithPending(string requested, TimeZoneInfo zone)
        {
            // A pending non-marker cannot complete a capture, but an unfenced heading
            // can break source grouping. Clone fence visibility to avoid consuming it.
            var marker = ParseMarker(pending);
            if (marker is not null && fence.Copy().IsVisible(pending))
            {
                var effective = source;
                if (marker.Date is null)
                {
                    var old = previous?.StartsWith("### ", StringComparison.Ordinal) == true ? ParseHeader(previous[4..], zone) : null;
                    if (old is null)
                    {
                        return !hasCapture || lastSource != requested || headingAfter;
                    }

                    effective = CaptureFormat.SourceHeading(new(old.Value.App, old.Value.Window));
                }

                return effective != requested;
            }

            return !hasCapture || lastSource != requested || headingAfter || fence.Copy().IsVisible(pending) && CaptureFormat.AtxHeading(pending) is not null;
        }

        private void ConsumeLine(string line, TimeZoneInfo zone)
        {
            if (!fence.IsVisible(line))
            {
                previous = null;
                return;
            }

            if (line.StartsWith("### ", StringComparison.Ordinal))
            {
                source = line[4..];
            }

            if (CaptureFormat.AtxHeading(line) is not null)
            {
                headingAfter = true;
            }

            var marker = ParseMarker(line);
            if (marker is not null)
            {
                var recognized = true;
                if (marker.Date is null)
                {
                    var old = previous?.StartsWith("### ", StringComparison.Ordinal) == true ? ParseHeader(previous[4..], zone) : null;
                    if (old is null)
                    {
                        recognized = false;
                    }
                    else
                    {
                        source = CaptureFormat.SourceHeading(new(old.Value.App, old.Value.Window));
                    }
                }

                if (recognized)
                {
                    lastSource = source;
                    hasCapture = true;
                    headingAfter = false;
                }
            }

            previous = line.StartsWith("### ", StringComparison.Ordinal) ? line : null;
        }
    }

    private static Marker? ParseNoteMarker(string line)
    {
        var match = Regex.Match(line, @"^<!-- note:([0-9a-fA-F-]{36}) at=(.+) -->$");
        return match.Success && Guid.TryParseExact(match.Groups[1].Value, "D", out var id) && TryStamp(match.Groups[2].Value, out var date) ? new(id, date, null) : null;
    }

    private static Marker? ParseMarker(string line)
    {
        var match = Regex.Match(line, "^<!-- capture:([0-9a-fA-F-]{36})(?: at=(.+) app=\"(.*)\")? -->$");
        if (!match.Success || !Guid.TryParseExact(match.Groups[1].Value, "D", out var id))
        {
            return null;
        }

        if (!match.Groups[2].Success)
        {
            return new(id, null, null);
        }

        if (!TryStamp(match.Groups[2].Value, out var date))
        {
            return null;
        }

        var app = CaptureFormat.UnescapeMetadata(match.Groups[3].Value);
        return new(id, date, app.Length == 0 ? null : app);
    }

    private static bool TryStamp(string text, out DateTimeOffset date) => DateTimeOffset.TryParseExact(text, ["yyyy-MM-dd'T'HH:mm:sszzz", "yyyy-MM-dd'T'HH:mm:ss'Z'"], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out date);
    private static (DateTimeOffset Date, string? App, string? Window)? ParseHeader(string text, TimeZoneInfo zone)
    {
        var parts = text.Split(" · ", StringSplitOptions.None);
        if (!DateTime.TryParseExact(parts[0], "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var local) || zone.IsInvalidTime(local))
        {
            return null;
        }

        var date = new DateTimeOffset(local, zone.IsAmbiguousTime(local) ? zone.GetAmbiguousTimeOffsets(local).Max() : zone.GetUtcOffset(local));
        static string? Clean(string text) => NoteTitle.CleanTitle(text) is { Length: > 0 } clean ? clean : null;
        return (date, parts.Length > 1 ? Clean(parts[1]) : null, parts.Length > 2 ? Clean(string.Join(" · ", parts.Skip(2))) : null);
    }

    private static string? ImagePath(string body, string notePath, string? assetRoot)
    {
        if (body.Contains('\n') || !body.StartsWith("![](", StringComparison.Ordinal) || !body.EndsWith(')'))
        {
            return null;
        }

        var encoded = body[4..^1];
        if (encoded.Length == 0 || encoded.StartsWith('/') || encoded.IndexOfAny([':', '\\', '?', '#', '\n']) >= 0 || Regex.IsMatch(encoded, @"%(?![0-9a-fA-F]{2})"))
        {
            return null;
        }

        var link = Uri.UnescapeDataString(encoded);
        if (notePath.StartsWith("file://", StringComparison.Ordinal) || Path.IsPathFullyQualified(notePath))
        {
            if (assetRoot is null)
            {
                return null;
            }

            try
            {
                var resolved = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(Vault.DecodeFilePath(notePath))!, link.Replace('/', Path.DirectorySeparatorChar)));
                var relative = Vault.RelativeUnder(resolved, Vault.DecodeFilePath(assetRoot));
                return relative is null ? null : Vault.AssetsDirectoryName + "/" + relative;
            }
            catch (ArgumentException)
            {
                return null;
            }
        }

        var components = notePath.Split('/', StringSplitOptions.RemoveEmptyEntries).SkipLast(1).ToList();
        foreach (var part in link.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == ".")
            {
                continue;
            }

            if (part == "..")
            {
                if (components.Count == 0)
                {
                    return null;
                }

                components.RemoveAt(components.Count - 1);
            }
            else
            {
                components.Add(part);
            }
        }

        return components.Count > 1 && components[0] == Vault.AssetsDirectoryName ? string.Join('/', components) : null;
    }

    private static List<ParsedBlock> LooseBlocks(IEnumerable<string> lines)
    {
        var blocks = new List<ParsedBlock>();
        var region = new List<string>();
        void Flush()
        {
            var graphemes = NoteTitle.Graphemes(string.Join('\n', region));
            for (var i = 0; i < graphemes.Count; i += 2000)
            {
                blocks.Add(new(null, BlockKind.Loose, null, null, null, string.Concat(graphemes.Skip(i).Take(2000)), null));
            }

            region.Clear();
        }

        foreach (var line in lines)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                Flush();
            }
            else
            {
                region.Add(line);
            }
        }

        Flush();
        return blocks;
    }
}
