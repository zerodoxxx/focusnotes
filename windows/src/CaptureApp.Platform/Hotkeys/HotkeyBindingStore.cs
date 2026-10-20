using System.Text.Json.Nodes;
using CaptureApp.Core;

namespace CaptureApp.Platform.Hotkeys;

/// <summary>Reads and updates the settings.json "shortcuts" section while preserving the other sections.</summary>
public sealed class HotkeyBindingStore
{
    private const string Section = "shortcuts";

    private readonly string _settingsPath;

    public HotkeyBindingStore(string settingsPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(settingsPath);
        _settingsPath = Path.GetFullPath(settingsPath);
    }

    public IReadOnlyDictionary<HotkeyAction, KeyChord> Load()
    {
        var bindings = new Dictionary<HotkeyAction, KeyChord>(HotkeyDefaults.All);
        var shortcutsNode = SectionedJsonFile.ReadSection(_settingsPath, Section);
        if (shortcutsNode is null)
        {
            return bindings;
        }

        if (shortcutsNode is not JsonObject shortcuts)
        {
            throw new InvalidDataException("The settings shortcuts value must be a JSON object.");
        }

        foreach (var pair in shortcuts)
        {
            if (!Enum.TryParse<HotkeyAction>(pair.Key, ignoreCase: true, out var action))
            {
                continue;
            }

            if (pair.Value is not JsonValue value || !value.TryGetValue<string>(out var displayString))
            {
                throw new InvalidDataException($"The shortcut for {action} must be a string.");
            }

            KeyChord chord;
            try
            {
                chord = KeyChord.Parse(displayString);
            }
            catch (FormatException exception)
            {
                throw new InvalidDataException($"The shortcut for {action} is invalid.", exception);
            }

            var validation = HotkeyValidator.Validate(chord);
            if (!validation.IsValid)
            {
                throw new InvalidDataException($"The shortcut for {action} is not allowed: {validation.Error}");
            }

            bindings[action] = chord;
        }

        return bindings;
    }

    public void Save(IReadOnlyDictionary<HotkeyAction, KeyChord> bindings)
    {
        ArgumentNullException.ThrowIfNull(bindings);
        foreach (var (action, chord) in bindings)
        {
            if (!Enum.IsDefined(action))
            {
                throw new ArgumentOutOfRangeException(nameof(bindings), $"Unknown hotkey action '{action}'.");
            }

            HotkeyValidator.ThrowIfInvalid(chord);
        }

        SectionedJsonFile.Update(_settingsPath, Section, existing =>
        {
            if (existing is not null and not JsonObject)
            {
                throw new InvalidDataException("The settings shortcuts value must be a JSON object.");
            }

            var shortcuts = existing as JsonObject ?? new JsonObject();
            foreach (var (action, chord) in bindings)
            {
                shortcuts[action.ToString()] = chord.DisplayString;
            }

            return shortcuts;
        });
    }

    /// <summary>Validates and test-registers a new binding before atomically persisting it.</summary>
    public HotkeyRegistrationResult SaveIfAvailable(HotkeyAction action, KeyChord chord, HotkeyRegistrar registrar)
    {
        ArgumentNullException.ThrowIfNull(registrar);
        var availability = registrar.TestRegisterTemporarily(chord);
        if (!availability.Succeeded)
        {
            return availability with { Action = action };
        }

        var bindings = Load().ToDictionary(pair => pair.Key, pair => pair.Value);
        bindings[action] = chord;
        Save(bindings);
        return availability with { Action = action };
    }
}
