using System;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using CaptureApp.Platform.Hotkeys;
using Xunit;

namespace CaptureApp.Platform.Tests.Hotkeys;

public sealed class HotkeyDefaultsTests
{
    [Theory]
    [InlineData(HotkeyAction.CaptureSelection, "Alt+Shift+Q")]
    [InlineData(HotkeyAction.CaptureArea, "Alt+Shift+G")]
    [InlineData(HotkeyAction.CaptureSelectionOutsideSession, "Ctrl+Shift+Q")]
    [InlineData(HotkeyAction.CaptureAreaOutsideSession, "Ctrl+Shift+G")]
    [InlineData(HotkeyAction.SearchNotes, "Alt+Shift+F")]
    [InlineData(HotkeyAction.ToggleSession, "Alt+Shift+A")]
    [InlineData(HotkeyAction.WriteNote, "Alt+Shift+W")]
    [InlineData(HotkeyAction.AddSubheading, "Alt+Shift+H")]
    [InlineData(HotkeyAction.OpenNotesFolder, "Alt+Shift+E")]
    public void DefaultsPassRebindingGuards(HotkeyAction action, string expected)
    {
        var chord = HotkeyDefaults.For(action);
        Assert.Equal(expected, chord.DisplayString);
        Assert.True(HotkeyValidator.Validate(chord).IsValid);
        Assert.Empty(AltGrGuard.GetConflictingLayouts(chord));
    }
}

public sealed class KeyChordTests
{
    [Theory]
    [InlineData("Ctrl+Alt+Shift+Q", "Ctrl+Alt+Shift+Q")]
    [InlineData("shift + ctrl + alt + q", "Ctrl+Alt+Shift+Q")]
    [InlineData("shift + alt + q", "Alt+Shift+Q")]
    [InlineData("Win+F12", "Win+F12")]
    [InlineData("Ctrl+Shift+Backspace", "Ctrl+Shift+Backspace")]
    public void ParsesAndDisplaysChordsCanonically(string source, string expected)
    {
        Assert.Equal(expected, KeyChord.Parse(source).DisplayString);
    }

    [Theory]
    [InlineData("Ctrl+Alt+Q", false)]
    [InlineData("Win+Alt+Shift+Q", false)]
    [InlineData("Ctrl+P", false)]
    [InlineData("Ctrl+Shift+Z", false)]
    [InlineData("Ctrl+Shift+N", false)]
    [InlineData("Escape", false)]
    [InlineData("Shift+Enter", false)]
    [InlineData("Ctrl+Alt+Shift+Q", true)]
    [InlineData("Alt+Shift+Q", true)]
    [InlineData("Alt+Shift+F12", true)]
    public void AppliesRebindingGuards(string display, bool expectedValid)
    {
        Assert.Equal(expectedValid, HotkeyValidator.Validate(KeyChord.Parse(display)).IsValid);
    }

    [Fact]
    public void RejectsMoreThanOneKeyAndDuplicateModifiers()
    {
        Assert.Throws<FormatException>(() => KeyChord.Parse("Ctrl+Q+W"));
        Assert.Throws<FormatException>(() => KeyChord.Parse("Ctrl+Ctrl+Q"));
    }
}

public sealed class HotkeyBindingStoreTests
{
    [Fact]
    public void NewlyReservedShortcutMigratesWithoutDiscardingOtherBindingsOrEditingSettings()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = Path.Combine(directory.Path, "settings.json");
        const string original = """
            {"theme":"dark","shortcuts":{"WriteNote":"Ctrl+Shift+N","SearchNotes":"Ctrl+Alt+Shift+J"}}
            """;
        File.WriteAllText(settingsPath, original);
        var store = new HotkeyBindingStore(settingsPath);

        var bindings = store.Load();

        Assert.Equal(HotkeyDefaults.For(HotkeyAction.WriteNote), bindings[HotkeyAction.WriteNote]);
        Assert.Equal(KeyChord.Parse("Ctrl+Alt+Shift+J"), bindings[HotkeyAction.SearchNotes]);
        Assert.Equal(HotkeyDefaults.All.Count, bindings.Count);
        Assert.All(bindings.Values, chord => Assert.True(HotkeyValidator.Validate(chord).IsValid));
        var adjustment = Assert.Single(store.Adjustments);
        Assert.Equal(HotkeyAction.WriteNote, adjustment.Action);
        Assert.Equal(KeyChord.Parse("Ctrl+Shift+N"), adjustment.PreviousChord);
        Assert.Equal(bindings[HotkeyAction.WriteNote], adjustment.Replacement);
        Assert.Equal(original, File.ReadAllText(settingsPath));
    }

    [Fact]
    public void ReservedShortcutMigrationDoesNotStealExplicitBindingsOrOtherDefaults()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = Path.Combine(directory.Path, "settings.json");
        File.WriteAllText(settingsPath, """
            {"shortcuts":{"WriteNote":"Ctrl+Shift+N","ToggleSession":"Alt+Shift+W","SearchNotes":"Alt+Shift+D"}}
            """);
        var store = new HotkeyBindingStore(settingsPath);

        var bindings = store.Load();

        Assert.Equal(KeyChord.Parse("Alt+Shift+W"), bindings[HotkeyAction.ToggleSession]);
        Assert.Equal(KeyChord.Parse("Alt+Shift+D"), bindings[HotkeyAction.SearchNotes]);
        Assert.Equal(KeyChord.Parse("Alt+Shift+J"), bindings[HotkeyAction.WriteNote]);
        Assert.Equal(HotkeyDefaults.For(HotkeyAction.CaptureSelection), bindings[HotkeyAction.CaptureSelection]);
        Assert.Equal(bindings.Count, bindings.Values.Distinct().Count());
        Assert.Single(store.Adjustments);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void SavedBindingsTakePriorityOverNewDefaultsRegardlessOfJsonOrder(bool reverse)
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = Path.Combine(directory.Path, "settings.json");
        var entries = new[]
        {
            "\"SearchNotes\":\"Ctrl+Shift+Q\"",
            "\"ToggleSession\":\"Ctrl+Shift+G\"",
            "\"CaptureSelection\":\"Alt+Shift+Q\"",
            "\"OpenNotesFolder\":\"Alt+Shift+D\""
        };
        File.WriteAllText(settingsPath, "{\"shortcuts\":{" + string.Join(",", reverse ? entries.Reverse() : entries) + "}}");
        var store = new HotkeyBindingStore(settingsPath);

        var bindings = store.Load();

        Assert.Equal(KeyChord.Parse("Ctrl+Shift+Q"), bindings[HotkeyAction.SearchNotes]);
        Assert.Equal(KeyChord.Parse("Ctrl+Shift+G"), bindings[HotkeyAction.ToggleSession]);
        Assert.Equal(KeyChord.Parse("Alt+Shift+Q"), bindings[HotkeyAction.CaptureSelection]);
        Assert.Equal(KeyChord.Parse("Alt+Shift+D"), bindings[HotkeyAction.OpenNotesFolder]);
        Assert.Equal(KeyChord.Parse("Alt+Shift+J"), bindings[HotkeyAction.CaptureSelectionOutsideSession]);
        Assert.Equal(KeyChord.Parse("Alt+Shift+K"), bindings[HotkeyAction.CaptureAreaOutsideSession]);
        Assert.Equal(bindings.Count, bindings.Values.Distinct().Count());
        Assert.Equal(2, store.Adjustments.Count);
        Assert.Equal(bindings.OrderBy(pair => pair.Key), store.Load().OrderBy(pair => pair.Key));
    }

    [Fact]
    public void ExplicitNewActionBindingIsPreservedWhileItsOriginalDefaultIsUsedElsewhere()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = Path.Combine(directory.Path, "settings.json");
        File.WriteAllText(settingsPath, """
            {"shortcuts":{"SearchNotes":"Ctrl+Shift+Q","CaptureSelectionOutsideSession":"Ctrl+Shift+F22"}}
            """);
        var store = new HotkeyBindingStore(settingsPath);

        var bindings = store.Load();

        Assert.Equal(KeyChord.Parse("Ctrl+Shift+Q"), bindings[HotkeyAction.SearchNotes]);
        Assert.Equal(KeyChord.Parse("Ctrl+Shift+F22"), bindings[HotkeyAction.CaptureSelectionOutsideSession]);
        Assert.Empty(store.Adjustments);
    }

    [Theory]
    [InlineData(HotkeyAction.WriteNote)]
    [InlineData(HotkeyAction.CaptureArea)]
    public void EditingOneShortcutRepairsUpgradeAndPreservesOtherSettings(HotkeyAction editedAction)
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = Path.Combine(directory.Path, "settings.json");
        const string original = """
            {"theme":"dark","future":{"nested":[1,true,"kept"]},"disabledShortcuts":["ToggleSession"],
             "shortcuts":{"WriteNote":"Ctrl+Shift+N","SearchNotes":"Ctrl+Shift+Q","ToggleSession":"Ctrl+Shift+G","futureAction":"kept"}}
            """;
        File.WriteAllText(settingsPath, original);
        var store = new HotkeyBindingStore(settingsPath);
        using var registrar = new HotkeyRegistrar();
        var replacement = KeyChord.Parse("Alt+Shift+F22");

        var result = store.SaveIfAvailable(editedAction, replacement, registrar);

        Assert.True(result.Succeeded, $"Test chord unavailable: {result.Win32Error}");
        var loaded = store.Load();
        Assert.Equal(replacement, loaded[editedAction]);
        Assert.Equal(KeyChord.Parse("Ctrl+Shift+Q"), loaded[HotkeyAction.SearchNotes]);
        Assert.Equal(KeyChord.Parse("Ctrl+Shift+G"), loaded[HotkeyAction.ToggleSession]);
        Assert.Equal(loaded.Count, loaded.Values.Distinct().Count());
        Assert.Empty(store.Adjustments);
        var before = JsonNode.Parse(original)!;
        var after = JsonNode.Parse(File.ReadAllText(settingsPath))!;
        Assert.True(JsonNode.DeepEquals(before["theme"], after["theme"]));
        Assert.True(JsonNode.DeepEquals(before["future"], after["future"]));
        Assert.True(JsonNode.DeepEquals(before["disabledShortcuts"], after["disabledShortcuts"]));
        Assert.Equal("kept", after["shortcuts"]!["futureAction"]!.GetValue<string>());
    }

    [Fact]
    public void RoundTripsShortcutsAndPreservesOtherSettings()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = Path.Combine(directory.Path, "settings.json");
        File.WriteAllText(settingsPath, "{\"theme\":\"dark\",\"shortcuts\":{\"CaptureArea\":\"Ctrl+Alt+Shift+G\"}}");
        var store = new HotkeyBindingStore(settingsPath);
        var bindings = store.Load().ToDictionary(pair => pair.Key, pair => pair.Value);
        bindings[HotkeyAction.SearchNotes] = KeyChord.Parse("Ctrl+Alt+Shift+J");
        store.Save(bindings);

        var loaded = store.Load();
        Assert.Equal("Ctrl+Alt+Shift+J", loaded[HotkeyAction.SearchNotes].DisplayString);
        Assert.Equal("Ctrl+Alt+Shift+G", loaded[HotkeyAction.CaptureArea].DisplayString);
        Assert.Equal("Alt+Shift+Q", loaded[HotkeyAction.CaptureSelection].DisplayString);
        Assert.Contains("\"theme\": \"dark\"", File.ReadAllText(settingsPath));
    }

    [Fact]
    public void CorruptSettingsAreQuarantinedAndShortcutsFallBackToDefaults()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = Path.Combine(directory.Path, "settings.json");
        const string corrupt = "{ this is not json";
        File.WriteAllText(settingsPath, corrupt);
        var store = new HotkeyBindingStore(settingsPath);

        Assert.Equal(HotkeyDefaults.All.Count, store.Load().Count);
        Assert.False(File.Exists(settingsPath));
        var quarantined = Assert.Single(Directory.GetFiles(Path.Combine(directory.Path, "corrupt")));
        Assert.Equal(corrupt, File.ReadAllText(quarantined));
        store.Save(HotkeyDefaults.All);
        Assert.Contains("\"shortcuts\"", File.ReadAllText(settingsPath));
    }
}

public sealed class AltGrGuardTests
{
    // The guard checks the chord as configured (Ctrl+Alt+Shift+letter). Polish (Programmers) AltGr+Shift+A types
    // 'Ą', so that chord is refused. German AltGr+Q types '@' only without Shift, and Shift+AltGr produces no
    // letter on that layout, so no Ctrl+Alt+Shift+letter chord conflicts there.
    [Theory]
    [InlineData("00000415", 'A', true)] // Polish (Programmers)
    [InlineData("00000407", 'Q', false)] // German
    public void LoadedLayoutIsConsideredWhenCheckingAndProposing(string klid, char probeLetter, bool probeConflicts)
    {
        var layout = AltGrGuard.LoadLayoutForTesting(klid);
        Assert.SkipUnless(layout != IntPtr.Zero, $"Keyboard layout {klid} is not installed on this Windows runner.");
        try
        {
            const HotkeyModifiers modifiers = HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift;
            var probe = new KeyChord(modifiers, probeLetter);
            Assert.Equal(probeConflicts, AltGrGuard.GetConflictingLayouts(probe).Contains(layout));

            // Chords that are not Ctrl+Alt+Shift+letter never reach the layout check.
            Assert.Empty(AltGrGuard.GetConflictingLayouts(new KeyChord(HotkeyModifiers.Control | HotkeyModifiers.Alt, probeLetter)));

            var alternative = AltGrGuard.FindNextFreeLetter();
            Assert.NotNull(alternative);
            Assert.Equal(HotkeyModifiers.Alt | HotkeyModifiers.Shift, alternative!.Value.Modifiers);
            Assert.DoesNotContain(layout, AltGrGuard.GetConflictingLayouts(alternative!.Value));
        }
        finally
        {
            AltGrGuard.UnloadLayoutForTesting(layout);
        }
    }
}

public sealed class HotkeyRegistrarTests
{
    [Fact]
    public void ASecondRegistrationReportsAlreadyRegisteredError()
    {
        var chord = KeyChord.Parse("Alt+Shift+F12");
        using var first = new HotkeyRegistrar();
        using var second = new HotkeyRegistrar();

        var firstResult = first.Register(HotkeyAction.CaptureSelection, chord, static () => { });
        Assert.True(firstResult.Succeeded);
        var secondResult = second.Register(HotkeyAction.CaptureArea, chord, static () => { });

        Assert.False(secondResult.Succeeded);
        Assert.Equal(1409, secondResult.Win32Error);
    }
}

internal sealed class TemporaryDirectory : IDisposable
{
    public TemporaryDirectory()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"platform-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public void Dispose() => Directory.Delete(Path, recursive: true);
}
