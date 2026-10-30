using System.Text;
using CaptureApp.Platform.Hotkeys;
using Xunit;

namespace CaptureApp.Platform.Tests.Hotkeys;

public sealed class FolderShortcutStoreTests
{
    private static FolderShortcutBinding Binding(string folder = "Projects/Research", string chord = "Alt+Shift+F10",
        FolderShortcutAction action = FolderShortcutAction.QuickNote) => new(Guid.NewGuid(), KeyChord.Parse(chord), action, folder);

    [Fact]
    public void RoundTripsBindingsInIndependentVaultFiles()
    {
        using var directory = new TemporaryDirectory();
        var store = new FolderShortcutStore(Path.Combine(directory.Path, "vault-a", "folder-shortcuts.json"));
        var other = new FolderShortcutStore(Path.Combine(directory.Path, "vault-b", "folder-shortcuts.json"));
        Assert.Empty(store.Load());
        FolderShortcutBinding[] bindings = [Binding(), Binding("Meetings", "Alt+Shift+F11", FolderShortcutAction.StartSession)];
        store.Save(bindings);
        Assert.Equal(bindings, store.Load());
        Assert.Empty(other.Load());
        store.Save([bindings[1]]);
        Assert.Equal([bindings[1]], store.Load());
    }

    [Theory]
    [InlineData("")]
    [InlineData("/Work")]
    [InlineData("~/Work")]
    [InlineData("../Work")]
    [InlineData("Work/../Other")]
    [InlineData("Work//Other")]
    [InlineData("Work/")]
    [InlineData("Work\\Other")]
    [InlineData("C:/Work")]
    [InlineData(".hidden/Work")]
    [InlineData("Work/CON")]
    [InlineData("Work/Bad.")]
    [InlineData("assets")]
    [InlineData("ASSETS/Other")]
    public void RejectsUnsafeAndReservedQuickNoteFolders(string folder)
        => Assert.Throws<InvalidDataException>(() => FolderShortcutStore.Validate([Binding(folder)]));

    [Fact]
    public void SessionAssetsFolderIsNotTheVaultAssetsDirectory()
        => FolderShortcutStore.Validate([Binding("assets/sub", action: FolderShortcutAction.StartSession)]);

    [Fact]
    public void ChecksDuplicatesCapAndEnabledBuiltInConflicts()
    {
        var first = Binding();
        Assert.Throws<InvalidDataException>(() => FolderShortcutStore.Validate([first, first]));
        Assert.Throws<InvalidDataException>(() => FolderShortcutStore.Validate([first, first with { Id = Guid.NewGuid() }]));
        Assert.Throws<InvalidDataException>(() => FolderShortcutStore.Validate([first with { Id = Guid.Empty }]));
        Assert.Throws<InvalidDataException>(() => FolderShortcutStore.Validate([first with { Action = (FolderShortcutAction)99 }]));
        Assert.Throws<InvalidDataException>(() => FolderShortcutStore.Validate(Enumerable.Range(0, 21).Select(_ => Binding()).ToArray()));
        var builtinChord = HotkeyDefaults.For(HotkeyAction.WriteNote);
        var collision = first with { Shortcut = builtinChord };
        Assert.Throws<InvalidDataException>(() => FolderShortcutStore.Validate([collision], HotkeyDefaults.All));
        FolderShortcutStore.Validate([collision], HotkeyDefaults.All, new HashSet<string> { nameof(HotkeyAction.WriteNote) });
    }

    [Theory]
    [InlineData("Q")]
    [InlineData("Shift+Q")]
    [InlineData("Ctrl+Escape")]
    [InlineData("Ctrl+K")]
    [InlineData("Win+F10")]
    [InlineData("Ctrl+Alt+Q")]
    public void RejectsUnsafeOrPanelReservedChords(string chord)
        => Assert.Throws<InvalidDataException>(() => FolderShortcutStore.Validate([Binding(chord: chord)]));

    [Fact]
    public void InvalidSaveAndMalformedLoadPreserveSavedBytes()
    {
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "folder-shortcuts.json");
        var store = new FolderShortcutStore(path);
        store.Save([Binding()]);
        var original = File.ReadAllBytes(path);
        Assert.Throws<InvalidDataException>(() => store.Save([Binding("../escape")]));
        Assert.Equal(original, File.ReadAllBytes(path));
        foreach (var content in new[] { "{broken", "{\"Version\":99,\"Bindings\":[]}", "{\"Version\":1,\"Bindings\":[{}]}" })
        {
            var bytes = Encoding.UTF8.GetBytes(content);
            File.WriteAllBytes(path, bytes);
            Assert.Throws<InvalidDataException>(() => store.Load());
            Assert.Equal(bytes, File.ReadAllBytes(path));
        }
    }

    [Fact]
    public async Task SaveWaitsForAScannerHoldingTheFile()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Requires Windows sharing semantics.");
        using var directory = new TemporaryDirectory();
        var path = Path.Combine(directory.Path, "folder-shortcuts.json");
        var store = new FolderShortcutStore(path);
        store.Save([Binding()]);
        FolderShortcutBinding[] bindings = [Binding("Meetings", "Alt+Shift+F11")];
        var scanner = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var release = Task.Run(async () =>
        {
            await Task.Delay(300, TestContext.Current.CancellationToken);
            await scanner.DisposeAsync();
        }, TestContext.Current.CancellationToken);
        try { store.Save(bindings); }
        finally { await release; }

        Assert.Equal(bindings, store.Load());
    }
}

// Global OS registrations must share xUnit's class-level serialization with the existing registrar checks.
public sealed partial class HotkeyRegistrarTests
{
    [Fact]
    public void CustomIdsCoexistWithBuiltInsAndUnregisterIndependently()
    {
        using var registrar = new HotkeyRegistrar();
        var id = Guid.NewGuid();
        var builtIn = KeyChord.Parse("Alt+Shift+F12");
        var custom = KeyChord.Parse("Alt+Shift+F11");
        Assert.True(registrar.Register(HotkeyAction.WriteNote, builtIn, static () => { }).Succeeded);
        Assert.True(registrar.Register(id, custom, static () => { }).Succeeded);
        Assert.True(registrar.IsRegistered(id));
        Assert.False(registrar.TestRegisterTemporarily(builtIn).Succeeded);
        registrar.Unregister(id);
        Assert.False(registrar.IsRegistered(id));
        Assert.True(registrar.TestRegisterTemporarily(custom).Succeeded);
        Assert.False(registrar.TestRegisterTemporarily(builtIn).Succeeded);
        Assert.True(registrar.Register(id, custom, static () => { }).Succeeded);
        registrar.UnregisterAll();
        Assert.False(registrar.IsRegistered(id));
        Assert.True(registrar.TestRegisterTemporarily(custom).Succeeded);
        Assert.True(registrar.TestRegisterTemporarily(builtIn).Succeeded);
    }

    [Fact]
    public void CustomConflictDoesNotReplaceBuiltInOrAnotherCustomIdentity()
    {
        using var registrar = new HotkeyRegistrar();
        var chord = KeyChord.Parse("Alt+Shift+F12");
        Assert.True(registrar.Register(HotkeyAction.WriteNote, chord, static () => { }).Succeeded);
        var customId = Guid.NewGuid();
        Assert.False(registrar.Register(customId, chord, static () => { }).Succeeded);
        Assert.False(registrar.IsRegistered(customId));
        registrar.Unregister(HotkeyAction.WriteNote);
        Assert.True(registrar.Register(customId, chord, static () => { }).Succeeded);
        Assert.False(registrar.Register(Guid.NewGuid(), chord, static () => { }).Succeeded);
        Assert.True(registrar.IsRegistered(customId));
    }
}
