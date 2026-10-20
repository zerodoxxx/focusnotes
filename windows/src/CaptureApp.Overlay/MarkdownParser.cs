using System.Text.RegularExpressions;

namespace CaptureApp.Overlay;

/// <summary>Open code-fence state after a line (character and run length), as MarkdownStyler.FenceState.</summary>
internal readonly record struct FenceState(char Character, int Length)
{
    public static FenceState Outside => default;
    public bool IsOpen => Length > 0;
}

internal enum LineKind { Text, Fence, Code }

/// <summary>A style applied to a character range of one line (relative offsets).</summary>
internal sealed record MarkdownStyle(int Start, int End, string? Color = null, bool Bold = false, bool Italic = false, bool Strike = false,
    bool Mono = false, double? Size = null, bool Display = false);

internal readonly record struct LineRange(int Start, int Length);

/// <summary>Everything the editor needs to draw one logical line; ranges are relative to the line start.</summary>
internal sealed class LineModel
{
    public LineKind Kind { get; init; }
    public List<MarkdownStyle> Styles { get; } = [];
    /// <summary>Syntax characters: hidden unless the line is active, then dimmed.</summary>
    public List<LineRange> Syntax { get; } = [];
    public List<LineRange> InlineCode { get; } = [];
    public LineRange? TaskMarker { get; set; }
    public bool TaskChecked { get; set; }
    public int? BulletIndex { get; set; }
    public LineRange? QuoteMarker { get; set; }
    public bool IsQuote => QuoteMarker is not null;
}

/// <summary>A line-local port of MarkdownStyler.scanCore. Offsets stay UTF-16, like the Swift NSRange contract.</summary>
internal static partial class MarkdownParser
{
    [GeneratedRegex(@"^#+ ")] private static partial Regex HeadingPattern();
    [GeneratedRegex(@"^([ \t]*)([-*+] (?:\[[ xX]\] )?|[0-9]+\. )")] private static partial Regex ListPattern();
    [GeneratedRegex(@"^> ")] private static partial Regex QuotePattern();
    [GeneratedRegex(@"(`+)([^`\r\n]+)\1")] private static partial Regex CodePattern();
    [GeneratedRegex(@"\[([^\]\r\n]+)\]\(([^)\r\n]+)\)|https?://[^\s<>]+")] private static partial Regex LinkPattern();
    [GeneratedRegex(@"(\*\*|__)(?=\S)(.+?\S|\S)\1")] private static partial Regex BoldPattern();
    [GeneratedRegex(@"(?<![\w*_])(\*|_)(?=\S)([^*_\r\n]+?\S|[^\s*_])\1(?![\w*_])")] private static partial Regex ItalicPattern();
    [GeneratedRegex(@"(~~)(?=\S)(.+?\S|\S)\1")] private static partial Regex StrikePattern();
    [GeneratedRegex(@"^([ \t]*)([-*+] (?:\[[ xX]\] )?|([0-9]+)\. )(.*)$")] internal static partial Regex ListLine();
    [GeneratedRegex(@"^([ \t]*)([-*+]) \[\]$")] internal static partial Regex TaskAutocorrect();
    [GeneratedRegex(@"^([ \t]*)([-*+] )\[[ xX]\] ")] internal static partial Regex TaskMarkerLine();

    /// <summary>The fence state after <paramref name="line"/> and whether the line is itself a fence delimiter.</summary>
    internal static FenceState Advance(string line, FenceState fence, out bool fenceLine)
    {
        var indent = 0;
        while (indent < line.Length && line[indent] == ' ') indent++;
        var first = indent < line.Length ? line[indent] : '\0';
        var run = 0;
        if (indent <= 3 && first is '`' or '~') while (indent + run < line.Length && line[indent + run] == first) run++;
        var rest = line[Math.Min(line.Length, indent + run)..];
        fenceLine = false;
        if (fence.IsOpen)
        {
            if (first == fence.Character && run >= fence.Length && rest.Trim(' ', '\t').Length == 0) { fence = FenceState.Outside; fenceLine = true; }
        }
        else if (run >= 3 && (first != '`' || !rest.Contains('`'))) { fence = new FenceState(first, run); fenceLine = true; }
        return fence;
    }

    internal static LineModel Parse(string line, FenceState incoming, out FenceState outgoing)
    {
        outgoing = Advance(line, incoming, out var fenceLine);
        if (outgoing.IsOpen || fenceLine)
        {
            var code = new LineModel { Kind = fenceLine ? LineKind.Fence : LineKind.Code };
            code.Styles.Add(new MarkdownStyle(0, line.Length, fenceLine ? "Tertiary" : null, Mono: true));
            return code;
        }
        var model = new LineModel { Kind = LineKind.Text };
        var styles = model.Styles;
        var size = Tokens.EditorFontSize;
        if (HeadingPattern().Match(line) is { Success: true } heading)
        {
            size = Tokens.EditorHeadingSizes[Math.Min(heading.Length - 1, 4) - 1];
            styles.Add(new MarkdownStyle(0, line.Length, "TextPrimary", Bold: true, Size: size, Display: size > Tokens.EditorHeadingSizes[2]));
            styles.Add(new MarkdownStyle(0, heading.Length, "Tertiary"));
            model.Syntax.Add(new LineRange(0, heading.Length));
        }
        if (ListPattern().Match(line) is { Success: true } list)
        {
            var item = list.Groups[2];
            styles.Add(new MarkdownStyle(0, list.Length, "Secondary"));
            if (item.Value[0] is '-' or '*' or '+') model.BulletIndex = item.Index;
            if (item.Value.Contains('['))
            {
                model.TaskMarker = new LineRange(item.Index, item.Length);
                model.TaskChecked = item.Value.Contains("[x]", StringComparison.OrdinalIgnoreCase);
                model.Syntax.Add(new LineRange(item.Index, item.Length));
                if (model.TaskChecked) styles.Add(new MarkdownStyle(list.Length, line.Length, "Secondary", Strike: true));
            }
        }
        else if (QuotePattern().Match(line) is { Success: true } quote)
        {
            model.QuoteMarker = new LineRange(0, quote.Length);
            styles.Add(new MarkdownStyle(0, line.Length, "Secondary"));
            styles.Add(new MarkdownStyle(0, quote.Length, "Tertiary"));
            model.Syntax.Add(new LineRange(0, quote.Length));
        }

        // Mask inline code and links before emphasis, so punctuation in a URL or a code sample never becomes a delimiter.
        var codes = CodePattern().Matches(line).ToList();
        var links = LinkPattern().Matches(line).ToList();
        var protectedRanges = codes.Concat(links).Select(m => (m.Index, End: m.Index + m.Length)).ToList();
        void Emphasis(Regex pattern, Func<Group, MarkdownStyle> style)
        {
            foreach (Match match in pattern.Matches(line))
            {
                if (protectedRanges.Any(r => Math.Min(r.End, match.Index + match.Length) > Math.Max(r.Index, match.Index))) continue;
                var open = match.Groups[1]; var body = match.Groups[2];
                styles.Add(style(body));
                var closeStart = body.Index + body.Length;
                foreach (var (start, length) in new[] { (open.Index, open.Length), (closeStart, match.Index + match.Length - closeStart) })
                {
                    styles.Add(new MarkdownStyle(start, start + length, "Tertiary"));
                    model.Syntax.Add(new LineRange(start, length));
                }
            }
        }
        Emphasis(BoldPattern(), body => new MarkdownStyle(body.Index, body.Index + body.Length, Bold: true));
        Emphasis(ItalicPattern(), body => new MarkdownStyle(body.Index, body.Index + body.Length, Italic: true));
        Emphasis(StrikePattern(), body => new MarkdownStyle(body.Index, body.Index + body.Length, Strike: true));
        foreach (var code in codes)
        {
            styles.Add(new MarkdownStyle(code.Index, code.Index + code.Length, Mono: true));
            model.InlineCode.Add(new LineRange(code.Index, code.Length));
            var open = code.Groups[1]; var body = code.Groups[2];
            foreach (var (start, length) in new[] { (open.Index, open.Length), (body.Index + body.Length, open.Length) })
            {
                styles.Add(new MarkdownStyle(start, start + length, "Tertiary"));
                model.Syntax.Add(new LineRange(start, length));
            }
        }
        foreach (var link in links)
        {
            if (codes.Any(c => Math.Min(c.Index + c.Length, link.Index + link.Length) > Math.Max(c.Index, link.Index))) continue;
            var label = link.Groups[1];
            if (!label.Success) { styles.Add(new MarkdownStyle(link.Index, link.Index + link.Length, "EditorLink")); continue; }
            styles.Add(new MarkdownStyle(link.Index, link.Index + link.Length, "Tertiary"));
            model.Syntax.Add(new LineRange(link.Index, label.Index - link.Index));
            var labelEnd = label.Index + label.Length;
            model.Syntax.Add(new LineRange(labelEnd, link.Index + link.Length - labelEnd));
            styles.Add(new MarkdownStyle(label.Index, labelEnd, "EditorLink"));
        }
        return model;
    }
}
