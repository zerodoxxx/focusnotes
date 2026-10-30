using System.Text.Json.Nodes;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class SectionedJsonFileTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "captureapp-sectioned-" + Guid.NewGuid().ToString("N"));

    private string SettingsPath => Path.Combine(directory, "settings.json");

    public SectionedJsonFileTests() => Directory.CreateDirectory(directory);

    public void Dispose() => Directory.Delete(directory, true);

    [Fact]
    public void WritingOneSectionKeepsTheOthers()
    {
        File.WriteAllText(SettingsPath, "{\"theme\":\"dark\",\"shortcuts\":{\"CaptureArea\":\"Ctrl+Alt+Shift+G\"}}");
        SectionedJsonFile.WriteSection(SettingsPath, "setup", new JsonObject { ["version"] = 1 });

        Assert.Equal("dark", (string?)SectionedJsonFile.ReadSection(SettingsPath, "theme"));
        Assert.Equal("Ctrl+Alt+Shift+G", (string?)SectionedJsonFile.ReadSection(SettingsPath, "shortcuts")!["CaptureArea"]);
        Assert.Equal(1, (int?)SectionedJsonFile.ReadSection(SettingsPath, "setup")!["version"]);
        Assert.Empty(Directory.GetFiles(directory, "*.tmp"));
    }

    [Fact]
    public async Task WritersOfDifferentSectionsNeverLoseEachOthersData()
    {
        const int count = 60;
        var first = Task.Run(() =>
        {
            for (var i = 0; i < count; i++) { SectionedJsonFile.WriteSection(SettingsPath, "a", new JsonObject { ["n"] = i }); }
        }, TestContext.Current.CancellationToken);
        var second = Task.Run(() =>
        {
            for (var i = 0; i < count; i++)
            {
                SectionedJsonFile.Update(SettingsPath, "b", existing =>
                {
                    var section = existing as JsonObject ?? [];
                    section["n"] = i;
                    return section;
                });
            }
        }, TestContext.Current.CancellationToken);
        await Task.WhenAll(first, second);

        Assert.Equal(count - 1, (int?)SectionedJsonFile.ReadSection(SettingsPath, "a")!["n"]);
        Assert.Equal(count - 1, (int?)SectionedJsonFile.ReadSection(SettingsPath, "b")!["n"]);
        Assert.Empty(Directory.GetFiles(directory, "*.tmp"));
    }

    [Fact]
    public void CorruptFileIsQuarantinedAndStartsEmpty()
    {
        File.WriteAllText(SettingsPath, "{ not json");

        Assert.Null(SectionedJsonFile.ReadSection(SettingsPath, "setup"));
        Assert.False(File.Exists(SettingsPath));
        Assert.Equal("{ not json", File.ReadAllText(Assert.Single(Directory.GetFiles(Path.Combine(directory, "corrupt")))));

        SectionedJsonFile.WriteSection(SettingsPath, "setup", new JsonObject { ["version"] = 2 });
        Assert.Equal(2, (int?)SectionedJsonFile.ReadSection(SettingsPath, "setup")!["version"]);
    }

    [Fact]
    public void NonObjectRootIsTreatedAsCorrupt()
    {
        File.WriteAllText(SettingsPath, "[1,2]");

        SectionedJsonFile.Update(SettingsPath, "x", _ => JsonValue.Create(true));

        Assert.True((bool?)SectionedJsonFile.ReadSection(SettingsPath, "x"));
        Assert.Single(Directory.GetFiles(Path.Combine(directory, "corrupt")));
    }

    [Fact]
    public void ReturningNullRemovesTheSection()
    {
        SectionedJsonFile.WriteSection(SettingsPath, "x", JsonValue.Create(1));
        SectionedJsonFile.Update(SettingsPath, "x", _ => null);

        Assert.Null(SectionedJsonFile.ReadSection(SettingsPath, "x"));
        Assert.True(SectionedJsonFile.Exists(SettingsPath));
    }

    [Fact]
    public void FailedChangeLeavesTheFileUntouched()
    {
        SectionedJsonFile.WriteSection(SettingsPath, "x", JsonValue.Create(1));
        var before = File.ReadAllText(SettingsPath);

        Assert.Throws<InvalidOperationException>(() =>
            SectionedJsonFile.Update(SettingsPath, "x", _ => throw new InvalidOperationException()));

        Assert.Equal(before, File.ReadAllText(SettingsPath));
    }

    [Fact]
    public async Task WriteSectionWaitsForAScannerHoldingSettings()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Requires Windows sharing semantics.");
        SectionedJsonFile.WriteSection(SettingsPath, "theme", JsonValue.Create("dark"));
        var scanner = new FileStream(SettingsPath, FileMode.Open, FileAccess.Read, FileShare.Read);
        var release = Task.Run(async () =>
        {
            await Task.Delay(300, TestContext.Current.CancellationToken);
            await scanner.DisposeAsync();
        }, TestContext.Current.CancellationToken);
        try { SectionedJsonFile.WriteSection(SettingsPath, "setup", new JsonObject { ["version"] = 1 }); }
        finally { await release; }

        Assert.Equal("dark", (string?)SectionedJsonFile.ReadSection(SettingsPath, "theme"));
        Assert.Equal(1, (int?)SectionedJsonFile.ReadSection(SettingsPath, "setup")!["version"]);
    }
}
