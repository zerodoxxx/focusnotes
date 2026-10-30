using System.Text.Json;
using Xunit;

namespace CaptureApp.Conformance.Tests;

public sealed class ConformanceTests
{
    private static readonly IReadOnlyDictionary<string, IAreaExecutor> Executors = new IAreaExecutor[]
    {
        new NoteTitleExecutor(),
        new RouterExecutor(),
        new CaptureFormatExecutor(),
        new NoteWriterExecutor(),
        new VaultNamingExecutor(),
        new SessionStoreExecutor(),
        new NoteParserExecutor(),
        new SearchIndexExecutor(),
        new CaptureDestinationExecutor()
    }.ToDictionary(e => e.Area, StringComparer.Ordinal);
    public static IEnumerable<TheoryDataRow<string>> Scenarios() => ScenarioLoader.LoadAll().Select(item =>
    {
        var scenario = item.Scenario;
        return new TheoryDataRow<string>(scenario.Area + "/" + scenario.Id)
        {
            Skip = OperatingSystem.IsWindows() && scenario.SkipOn?.Contains("windows", StringComparer.Ordinal) == true ? scenario.SkipReason ?? throw new InvalidDataException("Platform skips require a reason.") : null
        };
    });
    [Theory]
    [MemberData(nameof(Scenarios))]
    public async Task SwiftExpectedOutputMatchesCore(string identity)
    {
        var scenario = ScenarioLoader.LoadAll().Single(item => item.Scenario.Area + "/" + item.Scenario.Id == identity).Scenario;
        Assert.True(Executors.TryGetValue(scenario.Area, out var executor), $"Missing executor for {scenario.Area}");
        var actual = await executor.ExecuteAsync(scenario.Input, TestContext.Current.CancellationToken);
        Assert.Equal(scenario.Expected.Files.OrderBy(x => x.Key, StringComparer.Ordinal), actual.Files.OrderBy(x => x.Key, StringComparer.Ordinal));
        Assert.Equal(scenario.Expected.Results.Count, actual.Results.Count);
        for (var i = 0; i < actual.Results.Count; i++)
        {
            Assert.True(JsonElement.DeepEquals(scenario.Expected.Results[i], actual.Results[i]), $"{identity} op {i}: expected {scenario.Expected.Results[i].GetRawText()}, actual {actual.Results[i].GetRawText()}");
        }
    }
}
