using System.Text.Json.Nodes;
using CaptureApp.Core;

namespace CaptureApp.AppCore.Shell;

public enum UpdatesChoice { Auto, Manual }

/// Typed access to the app-owned sections of settings.json. The shortcuts and updates sections belong to
/// HotkeyBindingStore and the update state store; every section goes through <see cref="SectionedJsonFile"/>.
public sealed class SettingsStore(string settingsPath)
{
    public const string SetupSection = "setup";
    public const string PanelsSection = "panels";
    public const string CaptureSection = "capture";
    public const string NotesSection = "notes";
    public const string StartAtLoginSection = "startAtLogin";
    public const string UpdatesChoiceSection = "updatesChoice";
    public const string DisabledShortcutsSection = "disabledShortcuts";

    public string Path { get; } = System.IO.Path.GetFullPath(settingsPath);

    /// True when a settings file exists (a corrupt file is quarantined first, so it reads as absent).
    public bool Exists => SectionedJsonFile.Exists(Path);

    /// The setup state as stored, or null when Setup has never run.
    public JsonObject? ReadSetup() => SectionedJsonFile.ReadSection(Path, SetupSection) as JsonObject;

    public void UpdateSetup(Func<JsonObject?, JsonObject> change) =>
        SectionedJsonFile.Update(Path, SetupSection, existing => change(existing as JsonObject));

    /// null: not answered yet (Setup step 0). true: use the clipboard fallback. false: declined.
    public bool? ClipboardFallback
    {
        get => SectionedJsonFile.ReadSection(Path, CaptureSection) is JsonObject section
               && section["clipboardFallback"] is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;
        set => SectionedJsonFile.Update(Path, CaptureSection, existing =>
        {
            var section = existing as JsonObject ?? [];
            section["clipboardFallback"] = value is { } flag ? JsonValue.Create(flag) : null;
            return section;
        });
    }

    /// The configured notes folder, or null for the default.
    public string? NotesFolder
    {
        get => SectionedJsonFile.ReadSection(Path, NotesSection) is JsonObject section
               && section["vaultPath"] is JsonValue value && value.TryGetValue<string>(out var path)
               && !string.IsNullOrWhiteSpace(path) ? path : null;
        set => SectionedJsonFile.Update(Path, NotesSection, existing =>
        {
            var section = existing as JsonObject ?? [];
            section["vaultPath"] = string.IsNullOrWhiteSpace(value) ? null : JsonValue.Create(value);
            return section;
        });
    }

    /// null: not answered yet. The Run key itself is the live state; this records the user's choice.
    public bool? StartAtLogin
    {
        get => SectionedJsonFile.ReadSection(Path, StartAtLoginSection) is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;
        set => SectionedJsonFile.WriteSection(Path, StartAtLoginSection, value is { } flag ? JsonValue.Create(flag) : null);
    }

    public UpdatesChoice? UpdatesChoice
    {
        get => SectionedJsonFile.ReadSection(Path, UpdatesChoiceSection) is JsonValue value && value.TryGetValue<string>(out var text)
            ? text switch { "auto" => Shell.UpdatesChoice.Auto, "manual" => Shell.UpdatesChoice.Manual, _ => null }
            : null;
        set => SectionedJsonFile.WriteSection(Path, UpdatesChoiceSection, value switch
        {
            Shell.UpdatesChoice.Auto => JsonValue.Create("auto"),
            Shell.UpdatesChoice.Manual => JsonValue.Create("manual"),
            _ => null
        });
    }

    /// Hotkey action names the user explicitly turned off (Setup step 2 accepts "disabled by you").
    public IReadOnlySet<string> DisabledShortcuts
    {
        get => SectionedJsonFile.ReadSection(Path, DisabledShortcutsSection) is JsonArray array
            ? array.Select(node => node is JsonValue value && value.TryGetValue<string>(out var name) ? name : "")
                .Where(name => name.Length != 0).ToHashSet(StringComparer.Ordinal)
            : new HashSet<string>(StringComparer.Ordinal);
        set => SectionedJsonFile.WriteSection(Path, DisabledShortcutsSection,
            new JsonArray(value.Order(StringComparer.Ordinal).Select(name => (JsonNode)JsonValue.Create(name)!).ToArray()));
    }

    /// Panel positions as screen fractions, keyed by the Overlay position key.
    public (double X, double Y)? ReadPanel(string key) =>
        SectionedJsonFile.ReadSection(Path, PanelsSection) is JsonObject panels && panels[key] is JsonObject entry
        && entry["x"] is JsonValue x && x.TryGetValue<double>(out var px)
        && entry["y"] is JsonValue y && y.TryGetValue<double>(out var py) && double.IsFinite(px) && double.IsFinite(py)
            ? (px, py) : null;

    public void WritePanel(string key, double x, double y) =>
        SectionedJsonFile.Update(Path, PanelsSection, existing =>
        {
            var panels = existing as JsonObject ?? [];
            panels[key] = new JsonObject { ["x"] = x, ["y"] = y };
            return panels;
        });
}
