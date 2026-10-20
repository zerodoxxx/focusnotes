namespace CaptureApp.Updates;

/// <summary>Persisted in the <c>updates</c> section of settings.json.</summary>
public sealed class UpdateLedgerState
{
    public DateTimeOffset? LastCheckUtc { get; set; }
    public DateTimeOffset? NextAttemptUtc { get; set; }
    public int ConsecutiveFailures { get; set; }
    public string? PendingApplyVersion { get; set; }
    public string? ApplyFailureVersion { get; set; }
    public int ApplyFailures { get; set; }

    /// <summary>Automatic attempts are paused for this version and anything older (O5).</summary>
    public string? PausedVersion { get; set; }

    public bool IncludePrereleases { get; set; }
}

public enum StartupOutcome
{
    None,
    Applied,
    RetryAtQuit,
    Discard,
}

/// <summary>Check scheduling (backoff) and apply-failure bookkeeping (O5: no update loops).</summary>
public sealed class UpdateLedger(UpdateLedgerState state, Action save)
{
    public UpdateLedgerState State { get; } = state;

    public bool IsPaused(string version) =>
        State.PausedVersion is { } paused && VersionOrder.Compare(version, paused) <= 0;

    /// <summary>A stored time more than 24 h ahead (clock moved back, bad value) counts as due now, so checks can't stall.</summary>
    public DateTimeOffset NextAutomaticCheck(DateTimeOffset now)
    {
        var due = State.NextAttemptUtc ?? (State.LastCheckUtc is { } last ? last + UpdateBackoff.RegularInterval : now);
        var latest = now + UpdateBackoff.RegularInterval;
        return due > latest ? now : due;
    }

    public bool ShouldCheckAutomatically(DateTimeOffset now) => NextAutomaticCheck(now) <= now;

    public void CheckSucceeded(DateTimeOffset now)
    {
        State.LastCheckUtc = now;
        State.ConsecutiveFailures = 0;
        State.NextAttemptUtc = now + UpdateBackoff.RegularInterval;
        save();
    }

    public void CheckFailed(DateTimeOffset now, TimeSpan? retryAfter)
    {
        State.ConsecutiveFailures++;
        State.NextAttemptUtc = now + UpdateBackoff.Delay(Math.Min(State.ConsecutiveFailures, 1000), retryAfter);
        save();
    }

    public void ApplyStarted(string version)
    {
        State.PendingApplyVersion = version;
        save();
    }

    /// <summary>
    /// Run at launch. A pending apply whose version is not running means it failed: the first failure
    /// is retried once at the next quit, the second discards the package and pauses automatic attempts.
    /// </summary>
    public StartupOutcome ReconcileStartup(string runningVersion)
    {
        if (State.PendingApplyVersion is not { } pending)
        {
            return StartupOutcome.None;
        }

        State.PendingApplyVersion = null;
        if (VersionOrder.Compare(runningVersion, pending) >= 0)
        {
            State.ApplyFailures = 0;
            State.ApplyFailureVersion = null;
            save();
            return StartupOutcome.Applied;
        }

        State.ApplyFailures = string.Equals(State.ApplyFailureVersion, pending, StringComparison.Ordinal) ? State.ApplyFailures + 1 : 1;
        State.ApplyFailureVersion = pending;
        var outcome = StartupOutcome.RetryAtQuit;
        if (State.ApplyFailures >= 2)
        {
            State.PausedVersion = pending;
            State.ApplyFailures = 0;
            State.ApplyFailureVersion = null;
            outcome = StartupOutcome.Discard;
        }

        save();
        return outcome;
    }

    /// <summary>A manual Retry lifts the pause.</summary>
    public void ClearPause()
    {
        State.PausedVersion = null;
        save();
    }
}
