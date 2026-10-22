using CaptureApp.Core;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CaptureApp.AppCore;

public static class StatePaths
{
    private static readonly object NotesFolderGate = new();
    private sealed record NotesFolderMapping(string ConfiguredRoot, string? CanonicalRoot);

    public static string DefaultDirectory()
    {
        var parent = OperatingSystem.IsWindows()
            ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support");
        if (string.IsNullOrWhiteSpace(parent))
        {
            throw new InvalidOperationException("The current user's application data directory could not be resolved.");
        }

        return Path.GetFullPath(Path.Combine(parent, AppInfo.BundleId));
    }

    /// The first folder keeps the existing state layout. Other folders get independent sessions,
    /// recovery journals, drafts, pins, and search caches, without moving or deleting legacy state.
    /// Settings, models, and update state continue to use the global directory.
    public static string ForNotesFolder(string stateDirectory, string notesFolder)
    {
        var state = Path.GetFullPath(stateDirectory);
        var configured = NormalizeFolder(notesFolder);
        string? canonical;
        try { canonical = NormalizeFolder(NoteFile.ResolveSelectedRoot(notesFolder)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { canonical = null; }
        var marker = Path.Combine(state, "legacy-vault-root.json");
        lock (NotesFolderGate)
        {
            Directory.CreateDirectory(state);
            NotesFolderMapping? legacy;
            try { legacy = JsonSerializer.Deserialize<NotesFolderMapping>(File.ReadAllBytes(marker)); }
            catch (FileNotFoundException)
            {
                legacy = new(configured, canonical);
                AtomicJsonFile.Write(marker, JsonSerializer.SerializeToUtf8Bytes(legacy));
            }
            catch (JsonException error)
            {
                throw new InvalidDataException("The notes-folder state mapping could not be read. Its contents were left unchanged.", error);
            }

            if (legacy is null || string.IsNullOrWhiteSpace(legacy.ConfiguredRoot) || !Path.IsPathFullyQualified(legacy.ConfiguredRoot)
                || legacy.CanonicalRoot is { } savedCanonical && (string.IsNullOrWhiteSpace(savedCanonical) || !Path.IsPathFullyQualified(savedCanonical)))
            {
                throw new InvalidDataException("The notes-folder state mapping is invalid. Its contents were left unchanged.");
            }

            if (configured == legacy.ConfiguredRoot && (legacy.CanonicalRoot is null || canonical is null))
            {
                // A detached drive or unavailable link must not assign the old state to the replacement folder.
                // Remember its canonical identity once the original location becomes accessible again.
                if (legacy.CanonicalRoot is null && canonical is not null)
                {
                    AtomicJsonFile.Write(marker, JsonSerializer.SerializeToUtf8Bytes(legacy with { CanonicalRoot = canonical }));
                }
                return state;
            }
            if (canonical is not null && canonical == legacy.CanonicalRoot) { return state; }
            var key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical ?? configured))).ToLowerInvariant();
            return Path.Combine(state, "vaults", key);
        }
    }

    private static string NormalizeFolder(string folder)
    {
        var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        return OperatingSystem.IsWindows() ? path.ToUpperInvariant() : path;
    }
}
