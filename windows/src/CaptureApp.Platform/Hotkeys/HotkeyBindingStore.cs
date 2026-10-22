using System.Text.Json.Nodes;
using CaptureApp.Core;

namespace CaptureApp.Platform.Hotkeys;

public sealed record HotkeyBindingAdjustment(HotkeyAction Action, KeyChord PreviousChord, KeyChord Replacement, string Reason);

/// <summary>Reads and updates the settings.json "shortcuts" section while preserving the other sections.</summary>
public sealed class HotkeyBindingStore
{
    private const string Section = "shortcuts";

    private readonly string _settingsPath;

    /// <summary>Upgrade adjustments in the most recently loaded bindings, for display in shortcut settings.</summary>
    public IReadOnlyList<HotkeyBindingAdjustment> Adjustments { get; private set; } = [];

    public HotkeyBindingStore(string settingsPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(settingsPath);
        _settingsPath = Path.GetFullPath(settingsPath);
    }

    public IReadOnlyDictionary<HotkeyAction, KeyChord> Load()
    {
        Adjustments = [];
        var bindings = new Dictionary<HotkeyAction, KeyChord>();
        var retiredBindings = new Dictionary<HotkeyAction, KeyChord>();
        var shortcutsNode = SectionedJsonFile.ReadSection(_settingsPath, Section);
        if (shortcutsNode is null)
        {
            return new Dictionary<HotkeyAction, KeyChord>(HotkeyDefaults.All);
        }

        if (shortcutsNode is not JsonObject shortcuts)
        {
            throw new InvalidDataException("The settings shortcuts value must be a JSON object.");
        }

        foreach (var pair in shortcuts)
        {
            if (!Enum.TryParse<HotkeyAction>(pair.Key, ignoreCase: true, out var action) || !Enum.IsDefined(action))
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
                // This chord was valid before the editor gained its outside-session command.
                // Isolate that upgrade instead of discarding every saved customization.
                if (chord == new KeyChord(HotkeyModifiers.Control | HotkeyModifiers.Shift, 'N'))
                {
                    retiredBindings[action] = chord;
                    continue;
                }

                throw new InvalidDataException($"The shortcut for {action} is not allowed: {validation.Error}");
            }

            bindings[action] = chord;
        }

        var occupied = bindings.Values.ToHashSet();
        var pending = new List<HotkeyAction>();
        var adjustments = new List<HotkeyBindingAdjustment>();
        // Every explicit valid binding wins, even when it uses a newly introduced default.
        // Reserve the remaining defaults before choosing fallback letters for conflicts.
        foreach (var action in HotkeyDefaults.All.Keys.Order())
        {
            if (bindings.ContainsKey(action)) { continue; }
            var desired = HotkeyDefaults.For(action);
            if (occupied.Add(desired))
            {
                bindings[action] = desired;
                if (retiredBindings.TryGetValue(action, out var previous))
                {
                    adjustments.Add(new(action, previous, desired, "The previous combination is now used inside note panels."));
                }
            }
            else
            {
                pending.Add(action);
            }
        }

        foreach (var action in pending)
        {
            // Alt+Shift does not invoke AltGr. There are more fallback letters than actions.
            var replacement = AltGrGuard.FallbackOrder.Select(letter => new KeyChord(HotkeyDefaults.Modifiers, letter))
                .First(chord => !occupied.Contains(chord));
            occupied.Add(replacement);
            bindings[action] = replacement;
            var retired = retiredBindings.TryGetValue(action, out var previous);
            adjustments.Add(new(action, retired ? previous : HotkeyDefaults.For(action), replacement,
                retired ? "The previous combination is now used inside note panels; the default is already assigned."
                        : "The default combination is already assigned to a saved shortcut."));
        }

        Adjustments = adjustments.AsReadOnly();
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
