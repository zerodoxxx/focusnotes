using System.Text.Json;
using System.Text.Json.Serialization;

namespace CaptureApp.Conformance.Tests;

public sealed record Scenario
{
    public required string Id { get; init; }
    public required string Area { get; init; }
    public required string Description { get; init; }
    public required ScenarioInput Input { get; init; }
    public required ScenarioExpected Expected { get; init; }
    public string[]? SkipOn { get; init; }
    public string? SkipReason { get; init; }
}

public sealed record ScenarioInput
{
    public required DateTimeOffset Clock { get; init; }
    public required string TimeZone { get; init; }
    public required Dictionary<string, string> Files { get; init; }
    public required List<Dictionary<string, JsonElement>> Ops { get; init; }
}

public sealed record ScenarioExpected
{
    public required Dictionary<string, string> Files { get; init; }
    public required List<JsonElement> Results { get; init; }
}

public static class ScenarioLoader
{
    public static IReadOnlySet<string> KnownAreas { get; } = new HashSet<string>(StringComparer.Ordinal)
    {
        "notetitle",
        "router",
        "captureformat",
        "notewriter",
        "vault-naming",
        "sessionstore",
        "noteparser",
        "searchindex",
        "capturedestination"
    };

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
    public static IReadOnlyList<(string Path, Scenario Scenario)> LoadAll()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "Package.swift")))
        {
            directory = directory.Parent;
        }

        if (directory is null)
        {
            throw new DirectoryNotFoundException("Could not locate the package root.");
        }

        var scenarios = Path.Combine(directory.FullName, "conformance", "scenarios");
        return Directory.EnumerateFiles(scenarios, "*.json", SearchOption.AllDirectories).Order(StringComparer.Ordinal).Select(path => (path, JsonSerializer.Deserialize<Scenario>(File.ReadAllText(path), Options) ?? throw new JsonException($"Null scenario: {path}"))).ToArray();
    }
}

// Step 3 implements this single dispatch seam, one executor for each Area.
public interface IAreaExecutor
{
    string Area { get; }

    Task<ScenarioExpected> ExecuteAsync(ScenarioInput input, CancellationToken cancellationToken = default);
}
