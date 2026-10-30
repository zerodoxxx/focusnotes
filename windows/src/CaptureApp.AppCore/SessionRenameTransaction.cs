using System.Text.Json;
using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.AppCore;

/// Owns the crash-safe session rename transaction: the intent file, recovery, abandonment,
/// staging cleanup, and moving journaled/prepared captures, pins, and the index to the new note.
/// Callers serialize access (the pipeline holds its capture gate).
internal sealed class SessionRenameTransaction
{
    private sealed record RenameIntent(SessionRenamePlan Plan, Guid[] CaptureIds);
    private readonly Vault vault;
    private readonly SessionStore sessions;
    private readonly CaptureService service;
    private readonly CaptureJournal journal;
    private readonly NotePinStore pins;
    private readonly SearchIndex index;
    private readonly UnsavedCaptures unsaved;
    private readonly string intentPath;
    private readonly AppLog logger;

    public SessionRenameTransaction(Vault vault, SessionStore sessions, CaptureService service, CaptureJournal journal,
        NotePinStore pins, SearchIndex index, string stateDirectory, AppLog logger,
        UnsavedCaptures unsaved)
    {
        this.vault = vault;
        this.sessions = sessions;
        this.service = service;
        this.journal = journal;
        this.pins = pins;
        this.index = index;
        this.unsaved = unsaved;
        intentPath = Path.Combine(stateDirectory, "session-rename.json");
        this.logger = logger;
    }

    public SessionRenameOutcome Rename(SessionCandidate candidate, string newName, Action? beforeReplace,
        Action<SessionRenamePlan>? afterIntent)
    {
        Recover();
        RenameIntent? intent = null;
        Session session;
        try { session = service.RenameSession(candidate, newName, plan =>
        {
            var oldUrl = vault.ManagedUrl(plan.OldPath);
            var ids = journal.CaptureIdsTargeting(oldUrl)
                .Concat(unsaved.PreparedTargeting(prepared => SameUrl(prepared.Url, oldUrl)))
                .Distinct().ToArray();
            intent = new(plan, ids);
            DurableFile.Write(intentPath, JsonSerializer.SerializeToUtf8Bytes(intent));
            afterIntent?.Invoke(plan);
        }, beforeReplace); }
        catch (Exception error)
        {
            if (error is SessionRenamePendingException pending)
                logger.Error($"Session rename rollback failed: {pending.RollbackError}; original error: {pending.InnerException}");
            if (intent is null) throw;
            try
            {
                var source = vault.FileSnapshot(intent.Plan.OldPath, false);
                if (intent.Plan.OldPath != intent.Plan.Target.NotePath && source is not null && intent.Plan.Source.Matches(source))
                {
                    AbandonRename(intent, "Rename failed before moving the source, or rollback restored it.");
                    throw;
                }
                var target = vault.FileSnapshot(intent.Plan.Target.NotePath, false);
                if (target is null || !KnownTarget(intent.Plan, target)) throw;
            }
            catch (Exception cleanup) when (!ReferenceEquals(cleanup, error))
            {
                logger.Error($"Rename failure cleanup also failed: {cleanup}");
                System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error).Throw();
                throw;
            }
            // The move committed. Surface an explicit pending outcome instead of a failed-rename toast.
            logger.Error($"Session rename committed with follow-up pending: {error}");
            return new(intent.Plan.Target, true);
        }
        try
        {
            if (intent is not null) FinishRename(intent);
            return new(session, false);
        }
        catch (Exception error)
        {
            logger.Error($"Session renamed; identity migration will retry: {error}");
            return new(session, true);
        }
    }

    public void Recover()
    {
        if (!File.Exists(intentPath) || ReadRenameIntent() is not { } intent) return;
        var targetSnapshot = vault.FileSnapshot(intent.Plan.Target.NotePath, false);
        if (intent.Plan.OldPath != intent.Plan.Target.NotePath && vault.FileSnapshot(intent.Plan.OldPath) is { } original &&
            (intent.Plan.Source.Matches(original) || targetSnapshot is null || !KnownTarget(intent.Plan, targetSnapshot)))
        {
            AbandonRename(intent, intent.Plan.Source.Matches(original)
                ? "Source remains at the old name; abandon the uncommitted rename, preserving any user edits."
                : "Source was replaced; abandon the stale rename without modifying either note.");
            return;
        }

        // Core verifies the target's source identity or the exact rewritten content digest.
        try
        {
            sessions.CompleteRename(intent.Plan, repaired =>
            {
                CleanupRenameTemporary(intent.Plan);
                intent = intent with { Plan = repaired };
                DurableFile.Write(intentPath, JsonSerializer.SerializeToUtf8Bytes(intent));
            });
        }
        catch (Exception error) when (error is VaultFileException { Kind: VaultFileError.Changed } or FileNotFoundException)
        {
            AbandonRename(intent, $"Renamed target no longer has a known identity: {error.Message}");
            return;
        }
        FinishRename(intent);
    }

    /// An undecodable intent is quarantined so it cannot block startup or captures.
    private RenameIntent? ReadRenameIntent()
    {
        var data = File.ReadAllBytes(intentPath);
        try
        {
            var intent = JsonSerializer.Deserialize<RenameIntent>(data);
            if (intent?.Plan is { OldPath: not null, Target: { Name: not null, NotePath: not null }, Source: not null, Hashes: not null,
                    Installation: null or { Identity: not null, TemporaryPath: not null } }
                && intent.CaptureIds is not null) return intent;
            throw new JsonException("The pending session rename state is incomplete.");
        }
        catch (Exception error) when (error is JsonException or NotSupportedException)
        {
            var corrupt = Path.Combine(journal.DirectoryPath, "corrupt");
            Directory.CreateDirectory(corrupt);
            var stem = Path.GetFileNameWithoutExtension(intentPath);
            var target = File.Exists(Path.Combine(corrupt, stem + ".json")) ? stem + "-" + Guid.NewGuid().ToString("N") : stem;
            File.Move(intentPath, Path.Combine(corrupt, target + ".json"));
            logger.Error($"Corrupt session rename intent quarantined: {error.Message}");
            return null;
        }
    }

    private static bool KnownTarget(SessionRenamePlan plan, VaultFileSnapshot snapshot) =>
        plan.Source.Matches(snapshot) || plan.Installation?.Identity.Matches(snapshot) == true;

    private void AbandonRename(RenameIntent intent, string reason)
    {
        logger.Notice(reason);
        CleanupRenameTemporary(intent.Plan);
        File.Delete(intentPath);
    }

    private void CleanupRenameTemporary(SessionRenamePlan plan)
    {
        try { sessions.CleanupRename(plan); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Orphan cleanup must not turn an otherwise completed/abandoned rename into a startup blocker.
            logger.Error($"Session staging cleanup will be left to the vault sweep: {error}");
        }
    }

    private void FinishRename(RenameIntent intent)
    {
        var target = intent.Plan.Target;
        var destination = new Destination(vault.ManagedUrl(target.NotePath), target.Name, NoteKind.Session);
        journal.Relocate(intent.CaptureIds, destination);
        unsaved.Relocate(intent.CaptureIds, destination);
        pins.Move(intent.Plan.OldPath, target.NotePath);
        CleanupRenameTemporary(intent.Plan);
        try { index.Sync(); }
        catch (Exception error)
        {
            // Search is a cache. Watcher/startup sync repairs it without holding future captures.
            logger.Error($"Session renamed but its index update failed: {error}");
        }
        File.Delete(intentPath);
    }

    private static bool SameUrl(string left, string right) => string.Equals(Path.GetFullPath(left).Normalize(),
        Path.GetFullPath(right).Normalize(), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
}
