namespace CaptureApp.Updates;

public enum UpdateStatus
{
    /// <summary>No trusted keys, not installed by Setup, or otherwise unavailable.</summary>
    Disabled,
    Idle,
    Checking,
    Downloading,
    UpToDate,
    ReadyToRestart,
    /// <summary>The last check failed (shown for manual checks).</summary>
    CheckFailed,
    /// <summary>Two apply failures: Retry / Download installer.</summary>
    Failed,
}

/// <summary>What the tray renders.</summary>
public sealed record UpdateSnapshot(UpdateStatus Status, string? Version = null, string? Message = null, string? InstallerUrl = null)
{
    public string? RestartLabel => Status == UpdateStatus.ReadyToRestart ? $"Restart to Update (v{Version})" : null;

    public bool CanRetry => Status is UpdateStatus.Failed or UpdateStatus.CheckFailed;
}
