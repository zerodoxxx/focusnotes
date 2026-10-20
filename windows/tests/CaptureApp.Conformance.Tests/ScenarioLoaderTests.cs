using System.Globalization;
using Xunit;

namespace CaptureApp.Conformance.Tests;

public sealed class ScenarioLoaderTests
{
    [Fact]
    public void EveryScenarioParsesAndHasKnownAreaAndExpectedOutput()
    {
        var scenarios = ScenarioLoader.LoadAll();
        Assert.True(scenarios.Count >= 60, "The shared suite must contain at least 60 scenarios.");
        var identities = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (path, scenario) in scenarios)
        {
            Assert.Contains(scenario.Area, ScenarioLoader.KnownAreas);
            Assert.False(string.IsNullOrWhiteSpace(scenario.Id));
            Assert.False(string.IsNullOrWhiteSpace(scenario.Description));
            Assert.Equal(scenario.Area, new DirectoryInfo(Path.GetDirectoryName(path)!).Name);
            Assert.Equal(scenario.Id, Path.GetFileNameWithoutExtension(path));
            Assert.True(identities.Add($"{scenario.Area}/{scenario.Id}"));
            if (scenario.SkipOn is not null)
            {
                Assert.NotEmpty(scenario.SkipOn);
                Assert.All(scenario.SkipOn, platform => Assert.Equal("windows", platform));
                Assert.False(string.IsNullOrWhiteSpace(scenario.SkipReason));
            }
            else
            {
                Assert.Null(scenario.SkipReason);
            }

            Assert.NotNull(scenario.Input);
            Assert.Equal(TimeSpan.Zero, scenario.Input.Clock.Offset);
            Assert.False(string.IsNullOrWhiteSpace(scenario.Input.TimeZone));
            Assert.NotNull(scenario.Input.Files);
            Assert.NotEmpty(scenario.Input.Ops);
            foreach (var op in scenario.Input.Ops)
            {
                Assert.True(op.TryGetValue("op", out var name));
                Assert.False(string.IsNullOrWhiteSpace(name.GetString()));
            }

            Assert.NotNull(scenario.Expected);
            Assert.NotNull(scenario.Expected.Files);
            Assert.Equal(scenario.Input.Ops.Count, scenario.Expected.Results.Count);
            foreach (var file in scenario.Input.Files.Concat(scenario.Expected.Files))
            {
                Assert.False(file.Key.StartsWith('/'));
                Assert.DoesNotContain("\\", file.Key, StringComparison.Ordinal);
                Assert.All(file.Key.Split('/'), part => Assert.False(part is "" or "." or ".."));
            }
        }

        foreach (var area in ScenarioLoader.KnownAreas)
        {
            Assert.True(scenarios.Count(item => item.Scenario.Area == area) >= 5, string.Create(CultureInfo.InvariantCulture, $"Area {area} needs at least five scenarios."));
        }
    }
}
