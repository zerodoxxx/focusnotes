using System.Diagnostics;
using System.Text.Json.Nodes;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class CoreHardeningTests
{
    private static readonly VaultNamingRules Windows = new() { WindowsRules = true };

    [Fact]
    public void UpdateThrowsWhileTheSettingsFileIsLockedAndKeepsOtherSections()
    {
        var directory = Path.Combine(Path.GetTempPath(), "captureapp-locked-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "settings.json");
            const string original = "{\"theme\":\"dark\",\"shortcuts\":{\"CaptureArea\":\"Ctrl+Alt+Shift+G\"}}";
            File.WriteAllText(path, original);
            using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                Assert.ThrowsAny<IOException>(() => SectionedJsonFile.WriteSection(path, "setup", new JsonObject { ["version"] = 1 }));
            }

            Assert.Equal(original, File.ReadAllText(path));
            Assert.Equal("dark", (string?)SectionedJsonFile.ReadSection(path, "theme"));
            Assert.Null(SectionedJsonFile.ReadSection(path, "setup"));
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public void InvalidUtf8NoteIsIndexedAndLaterNotesStillIndex()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        File.WriteAllBytes(Path.Combine(e.Vault.Root, "A bad.md"), [.. "# Bad bytes\n\nbadbyteneedle "u8, 0xFF, 0xFE, .. "\n"u8]);
        e.Write("Z later.md", "# Later\n\nlaterneedle\n");
        using var index = new SearchIndex(e.Vault, Path.Combine(e.Base, "Cache", "search.sqlite"), CheckVault.Zone);
        index.Sync();
        Assert.NotEmpty(index.Search("badbyteneedle"));
        Assert.NotEmpty(index.Search("laterneedle"));
    }

    [Theory]
    [InlineData("CON.md")]
    [InlineData("nul.txt")]
    [InlineData("CONIN$")]
    [InlineData("conout$.md")]
    public void ReservedNamesAreRejected(string name) =>
        Assert.Equal(NotePathNameError.InvalidComponent, Assert.Throws<NotePathNameException>(() => NoteTitle.PathName(name, Windows)).Kind);

    // ':' is sanitized before validation, so alternate-data-stream syntax never reaches a file name.
    [Theory]
    [InlineData("note:stream", "note-stream")]
    [InlineData("note.md:stream", "note.md-stream")]
    [InlineData("folder:stream/note", "folder-stream/note")]
    public void StreamSyntaxNeverReachesAFileName(string name, string relativePath) =>
        Assert.Equal(relativePath, NoteTitle.PathName(name, Windows).RelativePath);

    [Fact]
    public void StalePendingTemporariesAreSweptOnlyWhenOldAndExactlyNamed()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var folder = Path.Combine(e.Vault.Root, "sub");
        Directory.CreateDirectory(folder);
        string Make(string directory, string name, TimeSpan age)
        {
            var path = Path.Combine(directory, name);
            File.WriteAllText(path, "x");
            File.SetLastWriteTimeUtc(path, DateTime.UtcNow - age);
            return path;
        }

        var stale = Make(folder, ".pending-" + Guid.NewGuid().ToString("N"), TimeSpan.FromHours(2));
        var fresh = Make(e.Vault.Root, ".pending-" + Guid.NewGuid().ToString("N"), TimeSpan.FromMinutes(1));
        var other = Make(e.Vault.Root, ".pending-notes.md", TimeSpan.FromHours(2));
        NoteFile.SweepStaleTemporaries(e.Vault.Root, TimeSpan.FromHours(1));
        Assert.False(File.Exists(stale));
        Assert.True(File.Exists(fresh));
        Assert.True(File.Exists(other));
    }

    [WindowsFact]
    [Trait("Needs", "Windows")]
    public void JunctionEscapingTheVaultIsRejected()
    {
        using var e = new CheckVault(windowsRules: true);
        e.Vault.Prepare();
        var outside = Path.Combine(e.Base, "outside");
        Directory.CreateDirectory(outside);
        var junction = Path.Combine(e.Vault.Root, "escape");
        using var process = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{junction}\" \"{outside}\"") { CreateNoWindow = true })!;
        process.WaitForExit();
        Assert.Equal(0, process.ExitCode);
        try
        {
            Assert.Throws<VaultFileException>(() => NoteFile.SafePath(e.Vault.Root, "escape/note.md"));
            Assert.True(FileMetadata.At(junction)!.IsLink);
        }
        finally
        {
            Directory.Delete(junction); // Remove the junction itself so cleanup never recurses through it.
        }
    }

    [WindowsFact]
    [Trait("Needs", "Windows")]
    public void LongPathsGoThroughTheExtendedPrefix()
    {
        using var e = new CheckVault(windowsRules: true);
        e.Vault.Prepare();
        var directory = e.Vault.Root;
        while (directory.Length < 250) { directory = Path.Combine(directory, "long-directory-component"); }
        Directory.CreateDirectory(@"\\?\" + directory);
        var file = Path.Combine(directory, "note.md");
        File.WriteAllText(@"\\?\" + file, "x");
        Assert.StartsWith(@"\\?\", FileMetadata.ExtendedPath(file), StringComparison.Ordinal);
        Assert.NotNull(FileMetadata.At(file));
    }
}
