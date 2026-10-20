using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class VaultNamingWindowsTests
{
    private static readonly VaultNamingRules Windows = new()
    {
        WindowsRules = true
    };
    [Theory]
    [InlineData("CON")]
    [InlineData("con.txt")]
    [InlineData("PrN.any.extension")]
    [InlineData("AUX")]
    [InlineData("NUL")]
    [InlineData("COM1")]
    [InlineData("COM9.md")]
    [InlineData("LPT1")]
    [InlineData("lpt9.txt")]
    [InlineData("COM¹")]
    [InlineData("a<b")]
    [InlineData("a>b")]
    [InlineData("a:b")]
    [InlineData("a\"b")]
    [InlineData("a|b")]
    [InlineData("a?b")]
    [InlineData("a*b")]
    [InlineData("a\a")]
    [InlineData("trailing ")]
    [InlineData("trailing.")]
    [InlineData("folder/NUL.md")]
    [InlineData("folder./note")]
    public void ReservedNamesFailWithMacReservedNameKind(string name)
    {
        Assert.Equal(NotePathNameError.InvalidComponent, Assert.Throws<NotePathNameException>(() => NoteTitle.PathName(name, Windows)).Kind);
    }

    [Theory]
    [InlineData("COM0")]
    [InlineData("COM10")]
    [InlineData("LPT0")]
    [InlineData("LPT10")]
    [InlineData("Console")]
    [InlineData("auxiliary")]
    public void NonDeviceNamesRemainAvailable(string name) => Assert.Equal(name, NoteTitle.PathName(name, Windows).LeafName);
    [Fact]
    public void BothSeparatorsAndLeadingHomeScope()
    {
        var nested = NoteTitle.PathName("Science\\Math/Note", Windows);
        Assert.Equal("Science/Math/Note", nested.RelativePath);
        Assert.Equal(NotePathScope.Home, NoteTitle.PathName("/Desktop\\Note", Windows).Scope);
        Assert.Equal("a-b", NoteTitle.PathName("a:b", new() { WindowsRules = false }).LeafName);
    }

    [Fact]
    public void LegacyFlatFallbackStillAppliesToLegalWindowsNames()
    {
        foreach (var (name, stem) in new[] { ("TODO/", "TODO-"), ("a//b", "a--b"), ("pros / cons", "pros - cons"), ("TODO\\", "TODO-") })
        {
            var note = new TypedNote("# " + name + "\nBody", CheckVault.Now, CheckVault.Zone, Windows);
            Assert.Equal(stem, note.PathName!.LeafName);
        }
        Assert.Null(new TypedNote("# Read https://x.com\nBody", CheckVault.Now, CheckVault.Zone, Windows).PathName);
    }

    [WindowsFact]
    [Trait("Needs", "Windows")]
    public void LongManagedPathAndProfileRelativeRegistry()
    {
        using var e = new CheckVault(registry: true, windowsRules: true);
        e.Vault.Prepare();
        var name = string.Join('/', Enumerable.Repeat("A sufficiently long directory component", 8)) + "/Note";
        var location = e.Vault.ResolveNoteName(name);
        Assert.True(location.Url.Length > 260);
        e.Writer.Append(CheckVault.Capture(), location.Url, "Note");
        Assert.NotNull(e.Vault.NoteLocation(location.Id));
        var external = e.Service.PrepareNote(CheckVault.Capture("# /Desktop/External\nBody", CaptureContentKind.Note), CheckVault.Zone);
        e.Service.Save(external);
        Assert.Contains("Desktop/External.md", e.Vault.ExternalNoteRegistry!.Paths());
        Assert.All(e.Vault.ExternalNoteRegistry.Paths(), p => Assert.DoesNotContain("\\", p, StringComparison.Ordinal));
    }

    [WindowsFact]
    [Trait("Needs", "Windows")]
    public void ExclusiveWriterBlocksConcurrentEditorHandles()
    {
        using var e = new CheckVault(windowsRules: true);
        e.Vault.Prepare();
        Exception? blocked = null;
        var writer = new NoteWriter(e.Vault, CheckVault.Zone, beforeAppend: path =>
        {
            blocked = Record.Exception(() => File.WriteAllText(path, "external editor"));
        });
        writer.Append(CheckVault.Capture(), e.Vault.InboxUrl, "Inbox");
        Assert.IsAssignableFrom<IOException>(blocked);
        Assert.DoesNotContain("external editor", CheckVault.Read(e.Vault.InboxUrl), StringComparison.Ordinal);
    }
}
