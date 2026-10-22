using System;
using System.IO;
using System.Linq;
using CaptureApp.Platform.Hotkeys;
using Xunit;

namespace CaptureApp.Platform.Tests.Hotkeys;

public sealed class HotkeyDefaultsTests
{
    [Theory]
    [InlineData(HotkeyAction.CaptureSelection, "Alt+Shift+Q")]
    [InlineData(HotkeyAction.CaptureArea, "Alt+Shift+G")]
    [InlineData(HotkeyAction.SearchNotes, "Alt+Shift+F")]
    [InlineData(HotkeyAction.ToggleSession, "Alt+Shift+A")]
    [InlineData(HotkeyAction.WriteNote, "Alt+Shift+W")]
    [InlineData(HotkeyAction.AddSubheading, "Alt+Shift+H")]
    [InlineData(HotkeyAction.OpenNotesFolder, "Alt+Shift+E")]
    public void DefaultsUseAltShiftAndPassRebindingGuards(HotkeyAction action, string expected)
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
