using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace CaptureApp.Core;

public enum NotePathScope
{
    Vault,
    Home
}

public enum NotePathNameError
{
    EmptyPath,
    InvalidComponent,
    TooDeep,
    TooLong
}

public sealed class NotePathNameException(NotePathNameError kind) : ArgumentException(kind.ToString())
{
    public NotePathNameError Kind { get; } = kind;
}

public sealed record VaultNamingRules
{
    public bool WindowsRules { get; init; } = OperatingSystem.IsWindows();

    public void ValidateComponent(string component)
    {
        if (!WindowsRules)
        {
            return;
        }

        var device = component.Split('.')[0].TrimEnd(' ');
        if (Regex.IsMatch(device, @"^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant) || component.Any(c => char.IsControl(c) || "<>:\"|?*".Contains(c)) || component.EndsWith(' ') || component.EndsWith('.'))
        {
            throw new NotePathNameException(NotePathNameError.InvalidComponent);
        }
    }
}

public sealed record NotePathName
{
    public const int MaximumPathDepth = 32;
    public const int MaximumRelativePathBytes = 900;
    public NotePathScope Scope { get; }
    public IReadOnlyList<string> Components { get; }
    public string RelativePath => string.Join('/', Components);
    public string LeafName => Components[^1];
    public string DisplayTitle => NoteTitle.BoundedTitle(LeafName);

    private NotePathName(NotePathScope scope, string[] components)
    {
        Scope = scope;
        Components = Array.AsReadOnly(components);
    }

    public static NotePathName Validated(NotePathScope scope, IEnumerable<string> components, VaultNamingRules? rules = null)
    {
        var values = components.ToArray();
        if (values.Length == 0)
        {
            throw new NotePathNameException(NotePathNameError.EmptyPath);
        }

        if (values.Length > MaximumPathDepth)
        {
            throw new NotePathNameException(NotePathNameError.TooDeep);
        }

        if (values.Any(c => c.Length == 0 || c != NoteTitle.FileStem(c)) || values[^1].StartsWith("~$", StringComparison.Ordinal))
        {
            throw new NotePathNameException(NotePathNameError.InvalidComponent);
        }

        if (Encoding.UTF8.GetByteCount(string.Join('/', values)) > MaximumRelativePathBytes)
        {
            throw new NotePathNameException(NotePathNameError.TooLong);
        }

        foreach (var value in values)
        {
            (rules ?? new()).ValidateComponent(value);
        }

        return new(scope, values);
    }
}

public static class NoteTitle
{
    public static bool ContainsControlCharacters(string text) => text.EnumerateRunes().Any(r =>
        Rune.GetUnicodeCategory(r) is UnicodeCategory.Control or UnicodeCategory.Format);

    public static string CleanTitle(string title) => Regex.Replace(title.Trim(), @"\s+", " ");
    public static string MatchKey(string title)
    {
        var widthFolded = string.Concat(CleanTitle(title).EnumerateRunes().Select(r => r.Value is >= 0xFF00 and <= 0xFFEF ? r.ToString().Normalize(NormalizationForm.FormKC) : r.ToString()));
        var text = UnicodeCaseFolding.Fold(widthFolded).Normalize(NormalizationForm.FormD);
        return string.Concat(text.EnumerateRunes().Where(r => Rune.GetUnicodeCategory(r) is not (UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark)).Select(r => r.ToString())).ToLowerInvariant();
    }

    public static NotePathName PathName(string rawName, VaultNamingRules? rules = null)
    {
        rules ??= new();
        var original = rules.WindowsRules ? rawName.Replace('\\', '/') : rawName;
        var cleaned = CleanTitle(original);
        if (original.Contains('\0'))
        {
            throw new NotePathNameException(NotePathNameError.InvalidComponent);
        }

        var scope = cleaned.StartsWith('/') ? NotePathScope.Home : NotePathScope.Vault;
        var unrooted = scope == NotePathScope.Home ? cleaned[1..] : cleaned;
        if (unrooted.Length == 0)
        {
            throw new NotePathNameException(NotePathNameError.EmptyPath);
        }

        var raw = unrooted.Split('/');
        if (raw.Length > NotePathName.MaximumPathDepth)
        {
            throw new NotePathNameException(NotePathNameError.TooDeep);
        }

        // Check Windows-invalid input before whitespace collapsing or filename sanitization can hide it.
        if (rules.WindowsRules)
        {
            foreach (var part in (original.TrimStart('/')).Split('/'))
            {
                rules.ValidateComponent(part);
            }
        }

        var components = raw.Select(part =>
        {
            var value = CleanTitle(part);
            if (value is "" or "." or "..")
            {
                throw new NotePathNameException(NotePathNameError.InvalidComponent);
            }

            return FileStem(value);
        });
        return NotePathName.Validated(scope, components, rules);
    }

    public static bool CanFallBackToFlatName(string rawName, NotePathNameError? error = null)
    {
        if (CleanTitle(rawName).StartsWith('/') || rawName.Contains('\0') || error is not (null or NotePathNameError.InvalidComponent))
        {
            return false;
        }

        var parts = rawName.Split('/').Select(CleanTitle).ToArray();
        if (parts.Any(p => p is "." or "..") || FileStem(parts.LastOrDefault(p => p.Length > 0) ?? "").StartsWith("~$", StringComparison.Ordinal))
        {
            return false;
        }

        var whitespace = Regex.IsMatch(rawName, @"\s/|/\s");
        return error is null ? whitespace : whitespace || rawName.EndsWith('/') || rawName.Contains("//", StringComparison.Ordinal);
    }

    public static string FileStem(string title)
    {
        var replaced = string.Concat(title.EnumerateRunes().Select(r => r.Value is '/' or '\\' or ':' || Rune.GetUnicodeCategory(r) is UnicodeCategory.Control or UnicodeCategory.Format ? "-" : r.ToString())).Trim();
        while (replaced.StartsWith('.'))
        {
            replaced = replaced[1..].Trim();
        }

        var result = new StringBuilder();
        foreach (var grapheme in Graphemes(replaced).Take(120))
        {
            if (grapheme.Normalize(NormalizationForm.FormD).EnumerateRunes().Count() > 32 || Encoding.UTF8.GetByteCount(result.ToString()) + Encoding.UTF8.GetByteCount(grapheme) > 220)
            {
                break;
            }

            result.Append(grapheme);
        }

        var stem = result.ToString().Trim();
        return stem.Length == 0 ? "Untitled" : stem;
    }

    public static IReadOnlyList<string> Graphemes(string text)
    {
        var values = new List<string>();
        var iterator = StringInfo.GetTextElementEnumerator(text);
        while (iterator.MoveNext())
        {
            values.Add(iterator.GetTextElement());
        }

        return values;
    }

    public static string BoundedTitle(string text, int limit = 60)
    {
        var parts = Graphemes(text);
        if (parts.Count <= limit)
        {
            return text;
        }

        var prefix = string.Concat(parts.Take(limit));
        if (!string.IsNullOrWhiteSpace(parts[limit]) && prefix.LastIndexOf(' ') is var boundary && boundary >= 0)
        {
            prefix = prefix[..boundary];
        }

        return prefix.Trim() + "…";
    }
}
