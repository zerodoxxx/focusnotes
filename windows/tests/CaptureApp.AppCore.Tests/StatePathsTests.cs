using CaptureApp.Core;
using System.Text.Json;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class StatePathsTests
{
    [Fact]
    public void FirstFolderRetainsLegacyStateAndOtherFoldersHaveStableIndependentState()
    {
        using var temp = new TempDirectory();
        var state = Path.Combine(temp.Path, "state");
        Directory.CreateDirectory(state);
        var legacy = Path.Combine(state, "draft-note.md");
        File.WriteAllText(legacy, "keep this draft");
        var original = Path.Combine(temp.Path, "original");
        var other = Path.Combine(temp.Path, "other");

        Assert.Equal(state, StatePaths.ForNotesFolder(state, original));
        var otherState = StatePaths.ForNotesFolder(state, other);
        Assert.StartsWith(Path.Combine(state, "vaults") + Path.DirectorySeparatorChar, otherState);
        Assert.Equal(otherState, StatePaths.ForNotesFolder(state, Path.Combine(other, "child", "..")));
        Assert.NotEqual(otherState, StatePaths.ForNotesFolder(state, Path.Combine(temp.Path, "third")));
        Assert.Equal(state, StatePaths.ForNotesFolder(state, original + Path.DirectorySeparatorChar));
        if (OperatingSystem.IsWindows())
        {
            Assert.Equal(state, StatePaths.ForNotesFolder(state, original.ToUpperInvariant()));
            Assert.Equal(otherState, StatePaths.ForNotesFolder(state, other.ToUpperInvariant()));
        }
        Assert.Equal("keep this draft", File.ReadAllText(legacy));
    }

    [Theory]
    [InlineData("{ invalid")]
    [InlineData("null")]
    [InlineData("\"\"")]
    [InlineData("{}")]
    [InlineData("{\"ConfiguredRoot\":\"relative\"}")]
    public void InvalidMappingIsPreservedWithoutClaimingLegacyState(string contents)
    {
        using var temp = new TempDirectory();
        var marker = Path.Combine(temp.Path, "legacy-vault-root.json");
        File.WriteAllText(marker, contents);
        Assert.Throws<InvalidDataException>(() => StatePaths.ForNotesFolder(temp.Path, Path.Combine(temp.Path, "vault")));
        Assert.Equal(contents, File.ReadAllText(marker));
        Assert.False(Directory.Exists(Path.Combine(temp.Path, "vaults")));
    }

    [Fact]
    public void UnavailableLegacyFolderKeepsItsStateWhenItsCanonicalIdentityBecomesAvailable()
    {
        using var temp = new TempDirectory();
        var original = Path.Combine(temp.Path, "original");
        var configured = OperatingSystem.IsWindows() ? original.ToUpperInvariant() : original;
        var marker = Path.Combine(temp.Path, "legacy-vault-root.json");
        File.WriteAllBytes(marker, JsonSerializer.SerializeToUtf8Bytes(new { ConfiguredRoot = configured, CanonicalRoot = (string?)null }));
        var other = StatePaths.ForNotesFolder(temp.Path, Path.Combine(temp.Path, "other"));
        Assert.NotEqual(temp.Path, other);
        Directory.CreateDirectory(original);
        Assert.Equal(temp.Path, StatePaths.ForNotesFolder(temp.Path, original));
        using var mapping = JsonDocument.Parse(File.ReadAllBytes(marker));
        Assert.Equal(configured, mapping.RootElement.GetProperty("CanonicalRoot").GetString());
        Assert.Equal(other, StatePaths.ForNotesFolder(temp.Path, Path.Combine(temp.Path, "other")));
    }

    [Fact]
    public void FolderSwitchKeepsSessionsDraftsPinsJournalsAndSearchWithTheirOriginalFolder()
    {
        using var temp = new TempDirectory();
        var state = Path.Combine(temp.Path, "state");
        var originalRoot = Path.Combine(temp.Path, "original");
        var otherRoot = Path.Combine(temp.Path, "other");
        string sessionPath;
        using (var original = CapturePipeline.Open(originalRoot, StatePaths.ForNotesFolder(state, originalRoot), TimeZoneInfo.Utc))
        {
            sessionPath = original.Sessions.Start("Original session").NotePath;
            original.Commit(original.PrepareText("oldfoldersearchneedle", new CaptureSource("check")));
            original.Stage(original.PrepareText("pending capture", new CaptureSource("check")));
            original.Drafts.Store("original draft", true);
            original.Pins.Set(sessionPath, true);
        }

        using (var other = CapturePipeline.Open(otherRoot, StatePaths.ForNotesFolder(state, otherRoot), TimeZoneInfo.Utc))
        {
            Assert.Null(other.Sessions.Current());
            Assert.Equal("", other.Drafts.Load());
            Assert.Empty(other.Pins.Paths());
            Assert.Empty(other.Journal.RecordPaths());
            Assert.Empty(other.Index.Search("oldfoldersearchneedle"));
            var saved = other.Commit(other.PrepareText("new folder capture", new CaptureSource("check")));
            Assert.Equal(other.Vault.InboxUrl, saved.Destination.Url);
            Assert.False(File.Exists(Path.Combine(otherRoot, sessionPath)));
        }

        using var restored = CapturePipeline.Open(originalRoot, StatePaths.ForNotesFolder(state, originalRoot), TimeZoneInfo.Utc);
        Assert.Equal(sessionPath, restored.Sessions.Current()?.NotePath);
        Assert.Equal(new NoteDraftSnapshot("original draft", true), restored.Drafts.LoadSnapshot());
        Assert.True(restored.Pins.IsPinned(sessionPath));
        Assert.Single(restored.Journal.RecordPaths());
        Assert.Single(restored.Index.Search("oldfoldersearchneedle"));
    }
}
