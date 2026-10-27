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
    [InlineData("CON ")]
    [InlineData("trailing.")]
    [InlineData("folder/NUL.md")]
    [InlineData("folder./note")]
    [InlineData("C:\\Notes\\a")]
    [InlineData("c:/a")]
    [InlineData(" D: /a")]
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

    // The Mac replaces ':' when it sanitizes a name; Windows also replaces the other characters it cannot store.
    [Theory]
    [InlineData("Re: budget", "Re- budget")]
    [InlineData("Why?", "Why-")]
    [InlineData("a<b>c", "a-b-c")]
    [InlineData("say \"hi\"", "say -hi-")]
    [InlineData("a|b*c", "a-b-c")]
    [InlineData("a\ab", "a-b")]
    [InlineData("trailing ", "trailing")]
    [InlineData("C:", "C-")]
    [InlineData("Standup: Q3\\Notes?", "Standup- Q3/Notes-")]
    [InlineData("Plan A: v2/notes", "Plan A- v2/notes")]
    public void CharactersWindowsCannotStoreAreSanitizedBeforeValidation(string name, string relativePath) =>
        Assert.Equal(relativePath, NoteTitle.PathName(name, Windows).RelativePath);

    [Fact]
    public void BothSeparatorsAndLeadingHomeScope()
    {
        var nested = NoteTitle.PathName("Science\\Math/Note", Windows);
        Assert.Equal("Science/Math/Note", nested.RelativePath);
        Assert.Equal(NotePathScope.Home, NoteTitle.PathName("/Desktop\\Note", Windows).Scope);
        Assert.Equal("a-b", NoteTitle.PathName("a:b", new() { WindowsRules = false }).LeafName);
        Assert.Equal("a?b", NoteTitle.PathName("a?b", new() { WindowsRules = false }).LeafName);
    }

    [Fact]
    public void LegacyFlatFallbackStillAppliesToLegalWindowsNames()
    {
        foreach (var (name, stem) in new[] { ("TODO/", "TODO-"), ("a//b", "a--b"), ("pros / cons", "pros - cons"), ("TODO\\", "TODO-") })
        {
            var note = new TypedNote("# " + name + "\nBody", CheckVault.Now, CheckVault.Zone, Windows);
            Assert.Equal(stem, note.PathName!.LeafName);
        }
        Assert.Equal("Read https---x.com", new TypedNote("# Read https://x.com\nBody", CheckVault.Now, CheckVault.Zone, Windows).PathName!.LeafName);
        var drive = new TypedNote("# C:\\Users\\me\\Note\nBody", CheckVault.Now, CheckVault.Zone, Windows);
        Assert.Null(drive.PathName);
        Assert.Equal(NotePathNameError.InvalidComponent, drive.PathNameError);
    }

    [Theory]
    [InlineData("TODO: call Bob", "TODO- call Bob")]
    [InlineData("Read https://x.com", "Read https---x.com")]
    [InlineData("Why does it fail?", "Why does it fail-")]
    public void QuickNoteTitlesWithReservedCharactersSaveOutsideASession(string title, string stem)
    {
        using var e = new CheckVault(windowsRules: true);
        e.Vault.Prepare();
        var prepared = e.Service.PrepareNote(CheckVault.Capture(title + "\nquicknoteneedle", CaptureContentKind.Note), CheckVault.Zone);
        e.Service.Save(prepared);
        Assert.Equal(e.Vault.UrlForRelativePath(stem + ".md"), prepared.Destination.Url);
        Assert.Equal(title, prepared.Destination.Title);
        Assert.StartsWith("# " + title + "\n", CheckVault.Read(prepared.Destination.Url), StringComparison.Ordinal);
    }

    [Fact]
    public void ChosenNoteTitleWithAColonMatchesItsHeadingOrCreatesTheMacFileName()
    {
        using var e = new CheckVault(windowsRules: true);
        e.Vault.Prepare();
        e.Write("Budget.md", "# Re: budget\n");
        var matched = Router.Destination("re: Budget", null, e.Vault.ListNotes(), e.Vault);
        Assert.Equal(e.Vault.UrlForRelativePath("Budget.md"), matched.Url);
        Assert.Equal("Re: budget", matched.Title);
        var created = Router.Destination("Standup: Q3?", null, e.Vault.ListNotes(), e.Vault);
        Assert.Equal(e.Vault.UrlForRelativePath("Standup- Q3-.md"), created.Url);
        Assert.Equal("Standup: Q3?", created.Title);
    }

    [Fact]
    public void SessionNamesWithAColonUseTheMacFileName()
    {
        using var mac = new CheckVault();
        using var e = new CheckVault(windowsRules: true);
        var expected = mac.Sessions.Start("Standup: Q3");
        var started = e.Sessions.Start("Standup: Q3");
        Assert.Equal("Standup: Q3", started.Name);
        Assert.Equal(expected.NotePath, started.NotePath);
        Assert.Equal("Sessions/Standup- Q3.md", started.NotePath);
        Assert.Equal(started.NotePath, e.Sessions.Start("Standup:  q3").NotePath);
        Assert.Equal("Sessions/Projects/Plan- v2.md", e.Sessions.Start("Projects\\Plan: v2").NotePath);
        Assert.Equal("Sessions/Projects/Retro- why-.md", e.Sessions.StartInFolder(new("Projects"), "Retro: why?").NotePath);
        Assert.Throws<NotePathNameException>(() => e.Sessions.Start("C:\\Sessions\\x"));
    }

    [Fact]
    public void SessionRenameToAColonNameUsesTheSanitizedFileNameAndRecovers()
    {
        using var e = new CheckVault(windowsRules: true);
        e.Vault.Prepare();
        var old = e.Write("Sessions/Standup.md", "# Standup\nbody\n");
        SessionRenamePlan? intent = null;
        var renamed = e.Service.RenameSession(new("Standup", "Sessions/Standup.md", CheckVault.Now), "Standup: Q3?", plan => intent = plan);
        Assert.Equal("Standup: Q3?", renamed.Name);
        Assert.Equal("Sessions/Standup- Q3-.md", renamed.NotePath);
        Assert.False(File.Exists(old));
        Assert.Equal("# Standup: Q3?\nbody\n", CheckVault.Read(e.Vault.UrlForRelativePath(renamed.NotePath)));
        Assert.Equal(renamed, e.Sessions.CompleteRename(intent!));
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
