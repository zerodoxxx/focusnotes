using System.Text.Json;
using CaptureApp.Core;

namespace CaptureApp.Updates;

public interface IUpdateStateStore
{
    UpdateLedgerState Load();

    void Save(UpdateLedgerState state);
}

/// <summary>Reads and writes the <c>updates</c> section of settings.json, leaving other sections untouched.</summary>
public sealed class SettingsFileUpdateStateStore(string settingsPath, Action<string>? log = null) : IUpdateStateStore
{
    private const string Section = "updates";
    private static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public UpdateLedgerState Load()
    {
        try
        {
            return SectionedJsonFile.ReadSection<UpdateLedgerState>(settingsPath, Section, Options) ?? new UpdateLedgerState();
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            // Unreadable settings must not block updates; start from a clean ledger.
            return new UpdateLedgerState();
        }
    }

    /// <summary>Best effort: a failed write is logged, never thrown (updates must not break on a read-only settings file).</summary>
    public void Save(UpdateLedgerState state)
    {
        try
        {
            SectionedJsonFile.WriteSection(settingsPath, Section, state, Options);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            log?.Invoke($"Could not save update state: {error.Message}");
        }
    }
}
