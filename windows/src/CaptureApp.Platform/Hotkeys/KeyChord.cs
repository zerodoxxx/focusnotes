using System.Collections.ObjectModel;
using System.Globalization;

namespace CaptureApp.Platform.Hotkeys;

public enum HotkeyAction
{
    CaptureSelection,
    CaptureArea,
    SearchNotes,
    ToggleSession,
    WriteNote,
    AddSubheading,
    OpenNotesFolder
}

[Flags]
public enum HotkeyModifiers : uint
{
    None = 0,
    Alt = 0x0001,
    Control = 0x0002,
    Shift = 0x0004,
    Windows = 0x0008,
    NoRepeat = 0x4000
}

/// <summary>A virtual-key chord suitable for RegisterHotKey.</summary>
public readonly record struct KeyChord
{
    private static readonly IReadOnlyDictionary<string, int> NamedKeys = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
    {
        ["Backspace"] = 0x08,
        ["Tab"] = 0x09,
        ["Enter"] = 0x0D,
        ["Escape"] = 0x1B,
        ["Space"] = 0x20,
        ["Delete"] = 0x2E,
        ["Insert"] = 0x2D,
        ["Home"] = 0x24,
        ["End"] = 0x23,
        ["PageUp"] = 0x21,
        ["PageDown"] = 0x22,
        ["Left"] = 0x25,
        ["Up"] = 0x26,
        ["Right"] = 0x27,
        ["Down"] = 0x28
    };

    private static readonly IReadOnlyDictionary<int, string> KeyLabels = NamedKeys.ToDictionary(pair => pair.Value, pair => pair.Key);

    public KeyChord(HotkeyModifiers modifiers, int virtualKey)
    {
        if (virtualKey is < 1 or > 0xFF)
        {
            throw new ArgumentOutOfRangeException(nameof(virtualKey), "Virtual keys must be between 1 and 255.");
        }

        const HotkeyModifiers knownModifiers = HotkeyModifiers.Alt | HotkeyModifiers.Control |
                                               HotkeyModifiers.Shift | HotkeyModifiers.Windows;
        if ((modifiers & ~knownModifiers) != 0)
        {
            throw new ArgumentOutOfRangeException(nameof(modifiers));
        }

        Modifiers = modifiers;
        VirtualKey = virtualKey;
    }

    public HotkeyModifiers Modifiers { get; }

    public int VirtualKey { get; }

    public bool IsLetter => VirtualKey is >= 'A' and <= 'Z';

    public string KeyLabel => VirtualKey switch
    {
        >= 'A' and <= 'Z' => ((char)VirtualKey).ToString(),
        >= '0' and <= '9' => ((char)VirtualKey).ToString(),
        >= 0x70 and <= 0x87 => $"F{VirtualKey - 0x6F}",
        _ when KeyLabels.TryGetValue(VirtualKey, out var label) => label,
        _ => $"VK{VirtualKey:X2}"
    };

    public string DisplayString
    {
        get
        {
            var parts = new List<string>(4);
            if (Modifiers.HasFlag(HotkeyModifiers.Control)) parts.Add("Ctrl");
            if (Modifiers.HasFlag(HotkeyModifiers.Alt)) parts.Add("Alt");
            if (Modifiers.HasFlag(HotkeyModifiers.Shift)) parts.Add("Shift");
            if (Modifiers.HasFlag(HotkeyModifiers.Windows)) parts.Add("Win");
            parts.Add(KeyLabel);
            return string.Join('+', parts);
        }
    }

    public static KeyChord Parse(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        var parts = value.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 1)
        {
            throw new FormatException("A shortcut must contain a key.");
        }

        var modifiers = HotkeyModifiers.None;
        var sawKey = false;
        var key = 0;
        foreach (var part in parts)
        {
            var modifier = part.ToLowerInvariant() switch
            {
                "ctrl" or "control" => HotkeyModifiers.Control,
                "alt" => HotkeyModifiers.Alt,
                "shift" => HotkeyModifiers.Shift,
                "win" or "windows" => HotkeyModifiers.Windows,
                _ => HotkeyModifiers.None
            };

            if (modifier != HotkeyModifiers.None)
            {
                if ((modifiers & modifier) != 0 || sawKey)
                {
                    throw new FormatException($"Invalid or duplicate modifier '{part}'.");
                }

                modifiers |= modifier;
                continue;
            }

            if (sawKey)
            {
                throw new FormatException("A shortcut must contain exactly one non-modifier key.");
            }

            key = ParseKey(part);
            sawKey = true;
        }

        if (!sawKey)
        {
            throw new FormatException("A shortcut must contain exactly one non-modifier key.");
        }

        return new KeyChord(modifiers, key);
    }

    private static int ParseKey(string value)
    {
        if (value.Length == 1)
        {
            var character = char.ToUpperInvariant(value[0]);
            if (character is >= 'A' and <= 'Z' or >= '0' and <= '9')
            {
                return character;
            }
        }

        if (value.Length is >= 2 and <= 3 && value[0] is 'F' or 'f' &&
            int.TryParse(value.AsSpan(1), NumberStyles.None, CultureInfo.InvariantCulture, out var functionKey) &&
            functionKey is >= 1 and <= 24)
        {
            return 0x70 + functionKey - 1;
        }

        if (NamedKeys.TryGetValue(value, out var virtualKey))
        {
            return virtualKey;
        }

        if (string.Equals(value, "Esc", StringComparison.OrdinalIgnoreCase))
        {
            return 0x1B;
        }

        throw new FormatException($"Unknown shortcut key '{value}'.");
    }
}

public static class HotkeyDefaults
{
    private static readonly IReadOnlyDictionary<HotkeyAction, KeyChord> Defaults = new ReadOnlyDictionary<HotkeyAction, KeyChord>(
        new Dictionary<HotkeyAction, KeyChord>
        {
            [HotkeyAction.CaptureSelection] = new(HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift, 'Q'),
            [HotkeyAction.CaptureArea] = new(HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift, 'G'),
            [HotkeyAction.SearchNotes] = new(HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift, 'F'),
            [HotkeyAction.ToggleSession] = new(HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift, 'A'),
            [HotkeyAction.WriteNote] = new(HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift, 'W'),
            [HotkeyAction.AddSubheading] = new(HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift, 'H'),
            [HotkeyAction.OpenNotesFolder] = new(HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift, 'E')
        });

    public static IReadOnlyDictionary<HotkeyAction, KeyChord> All => Defaults;

    public static KeyChord For(HotkeyAction action) => Defaults[action];
}

public sealed record HotkeyValidationResult(bool IsValid, string? Error)
{
    public static HotkeyValidationResult Valid { get; } = new(true, null);
}

public static class HotkeyValidator
{
    private static readonly HashSet<KeyChord> InPanelShortcuts =
    [
        new(HotkeyModifiers.Control, 0x0D), // Ctrl+Enter
        new(HotkeyModifiers.Control, 'K'),
        new(HotkeyModifiers.Control, 'P'),
        new(HotkeyModifiers.Control, 'N'),
        new(HotkeyModifiers.Control, 'O'),
        new(HotkeyModifiers.Control | HotkeyModifiers.Shift, 'P'),
        new(HotkeyModifiers.Control | HotkeyModifiers.Shift, 'C'),
        new(HotkeyModifiers.Control | HotkeyModifiers.Shift, 0x08), // Ctrl+Shift+Backspace
        new(HotkeyModifiers.None, 0x1B), // Escape
        new(HotkeyModifiers.Shift, 0x0D), // Shift+Enter
        new(HotkeyModifiers.None, 0x09), // Tab
        new(HotkeyModifiers.Shift, 0x09), // Shift+Tab
        new(HotkeyModifiers.Control, 'Z'),
        new(HotkeyModifiers.Control, 'Y'),
        new(HotkeyModifiers.Control | HotkeyModifiers.Shift, 'Z')
    ];

    public static HotkeyValidationResult Validate(KeyChord chord)
    {
        if (chord.Modifiers.HasFlag(HotkeyModifiers.Windows))
        {
            return new(false, "Shortcuts cannot use the Windows key.");
        }

        var hasControlAndAlt = chord.Modifiers.HasFlag(HotkeyModifiers.Control) && chord.Modifiers.HasFlag(HotkeyModifiers.Alt);
        if (hasControlAndAlt && !chord.Modifiers.HasFlag(HotkeyModifiers.Shift))
        {
            return new(false, "Ctrl+Alt without Shift is reserved for AltGr input.");
        }

        if (InPanelShortcuts.Contains(chord))
        {
            return new(false, "This shortcut is already used inside the note panels.");
        }

        return HotkeyValidationResult.Valid;
    }

    public static void ThrowIfInvalid(KeyChord chord)
    {
        var result = Validate(chord);
        if (!result.IsValid)
        {
            throw new ArgumentException(result.Error, nameof(chord));
        }
    }
}
