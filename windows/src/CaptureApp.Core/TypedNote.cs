using System.Text.RegularExpressions;

namespace CaptureApp.Core;

public sealed class TypedNote
{
    public string RawName { get; }
    public NotePathName? PathName { get; }
    public NotePathNameError? PathNameError { get; }
    public string Title { get; }
    public string Body { get; }

    public TypedNote(string markdown, DateTimeOffset createdAt, TimeZoneInfo timeZone, VaultNamingRules? namingRules = null)
    {
        namingRules ??= new();
        var without = Regex.Replace(markdown, @"<!--[\s\S]*?(?:-->|$)", "");
        var first = Regex.Split(without, @"[\r\n\u000B\u000C\u0085\u2028\u2029]").FirstOrDefault(l => !string.IsNullOrWhiteSpace(l)) ?? "";
        var stripped = Strip(first);
        var extracted = stripped.Length == 0 ? "Note " + CaptureFormat.LocalStamp(createdAt, "yyyy-MM-dd HH.mm", timeZone) : stripped;
        NotePathName? parsed = null;
        NotePathNameError? error = null;
        try
        {
            parsed = NoteTitle.PathName(extracted, namingRules);
        }
        catch (NotePathNameException failure)
        {
            error = failure.Kind;
        }

        var fallbackInput = namingRules.WindowsRules ? extracted.Replace('\\', '/') : extracted;
        var fallback = NoteTitle.CanFallBackToFlatName(fallbackInput, error);
        var resolved = parsed;
        if (fallback)
        {
            try
            {
                namingRules.ValidateComponent(extracted);
                resolved = NotePathName.Validated(NotePathScope.Vault, [NoteTitle.FileStem(extracted)], namingRules);
            }
            catch (NotePathNameException)
            {
                resolved = null;
            }
        }

        var qualified = parsed is not null && !fallback && (parsed.Scope == NotePathScope.Home || parsed.Components.Count > 1);
        RawName = extracted;
        PathName = resolved;
        PathNameError = resolved is null ? error : null;
        var normalized = namingRules.WindowsRules ? extracted.Replace('\\', '/') : extracted;
        Title = NoteTitle.BoundedTitle(qualified ? NoteTitle.CleanTitle(normalized.Split('/')[^1]) : extracted);
        var physicalFirst = Regex.Split(markdown, @"[\r\n\u000B\u000C\u0085\u2028\u2029]")[0];
        var structural = @"^(?:[ \t]*(?:[-*+][ \t]+|[0-9]+[.)][ \t]+|>|`|~{3})|\t| {4})";
        if (stripped.Length > 0 && Strip(physicalFirst) == (qualified ? extracted : Title) && !Regex.IsMatch(physicalFirst, structural))
        {
            var newline = Regex.Match(markdown, @"\r\n|[\r\n\u000B\u000C\u0085\u2028\u2029]");
            Body = newline.Success ? CaptureFormat.NoteBody(markdown[(newline.Index + newline.Length)..]) : "";
        }
        else
        {
            Body = CaptureFormat.NoteBody(markdown);
        }
    }

    private static string Strip(string line)
    {
        var text = Regex.Replace(line, @"<!--[\s\S]*?(?:-->|$)", "");
        const string prefix = @"^[ \t]*(?:#+[ \t]+|[-*+][ \t]+(?:\[[ xX]\][ \t]*)?|[0-9]+[.)][ \t]+|>[ \t]*)";
        while (true)
        {
            var next = Regex.Replace(text, prefix, "");
            if (next == text)
            {
                break;
            }

            text = next;
        }

        text = Regex.Replace(text, @"[ \t]+#+[ \t]*$", "");
        text = Regex.Replace(text, @"!?\[([^\]]*)\]\([^)]*\)", "$1");
        for (var i = 0; i < 2; i++)
        {
            text = Regex.Replace(text, @"(\*\*|__|~~)(?=\S)(.+?)\1", "$2");
            text = Regex.Replace(text, @"(?<![\w*_])([*_])(?=\S)(.+?)\1(?![\w*_])", "$2");
        }

        return NoteTitle.CleanTitle(Regex.Replace(text, @"`+", ""));
    }
}
