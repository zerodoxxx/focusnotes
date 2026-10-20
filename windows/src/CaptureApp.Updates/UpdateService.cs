namespace CaptureApp.Updates;

public sealed class UpdateServiceOptions
{
    public required string CurrentVersion { get; init; }

    /// <summary>"Download installer" fallback shown after two failed applies.</summary>
    public string? InstallerUrl { get; init; }
}

/// <summary>
/// Check, download and apply orchestration. Automatic checks run at launch and every 24 h with
/// backoff; a manual check bypasses backoff. Failed applies follow O5 (retry once, then pause).
/// </summary>
public sealed class UpdateService
{
    private readonly IUpdateClient? client;
    private readonly IUpdateApplier applier;
    private readonly UpdateServiceOptions options;
    private readonly TimeProvider time;
    private readonly UpdateLedger ledger;
    private readonly SemaphoreSlim gate = new(1, 1);
    private UpdateOffer? ready;
    private UpdateSnapshot snapshot;

    public UpdateService(IUpdateClient? client, IUpdateApplier applier, IUpdateStateStore store, UpdateServiceOptions options, TimeProvider? time = null)
    {
        this.client = client;
        this.applier = applier;
        this.options = options;
        this.time = time ?? TimeProvider.System;
        var loaded = store.Load();
        ledger = new UpdateLedger(loaded, () =>
        {
            try
            {
                store.Save(loaded);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // Persistence is best effort; checks and applies must carry on.
            }
        });
        snapshot = new UpdateSnapshot(client is null ? UpdateStatus.Disabled : UpdateStatus.Idle);
    }

    /// <summary>A service that reports updates unavailable (no key, or not installed by Setup).</summary>
    public static UpdateService CreateDisabled(IUpdateStateStore store, UpdateServiceOptions options) =>
        new(null, new NoopUpdateApplier(), store, options);

    public event Action<UpdateSnapshot>? StateChanged;

    public bool IsEnabled => client is not null;

    public UpdateSnapshot Snapshot => snapshot;

    public UpdateLedger Ledger => ledger;

    /// <summary>Call once at launch: settles the previous apply and arranges the single retry.</summary>
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var outcome = ledger.ReconcileStartup(options.CurrentVersion);
        if (client is null)
        {
            return;
        }

        switch (outcome)
        {
            case StartupOutcome.RetryAtQuit:
                await CheckAsync(manual: true, cancellationToken).ConfigureAwait(false);
                break;
            case StartupOutcome.Discard:
                client.DiscardDownloads();
                ready = null;
                Publish(new UpdateSnapshot(UpdateStatus.Failed, ledger.State.PausedVersion, "Update failed", options.InstallerUrl));
                break;
        }
    }

    /// <summary>Time until the next automatic check is due (zero when due now).</summary>
    public TimeSpan NextAutomaticDelay()
    {
        var now = time.GetUtcNow();
        var due = ledger.NextAutomaticCheck(now) - now;
        return due > TimeSpan.Zero ? due : TimeSpan.Zero;
    }

    /// <summary>Launch check, then every 24 h (or the backoff delay). Runs until cancelled.</summary>
    public async Task RunAutomaticChecksAsync(CancellationToken cancellationToken)
    {
        if (client is null)
        {
            return;
        }

        while (!cancellationToken.IsCancellationRequested)
        {
            var delay = NextAutomaticDelay();
            if (delay > TimeSpan.Zero)
            {
                await Task.Delay(delay, time, cancellationToken).ConfigureAwait(false);
            }

            await CheckAsync(manual: false, cancellationToken).ConfigureAwait(false);
            if (NextAutomaticDelay() == TimeSpan.Zero)
            {
                await Task.Delay(UpdateBackoff.RegularInterval, time, cancellationToken).ConfigureAwait(false);
            }
        }
    }

    /// <summary>Returns true when an update is downloaded and ready.</summary>
    public async Task<bool> CheckAsync(bool manual, CancellationToken cancellationToken)
    {
        if (client is null)
        {
            Publish(new UpdateSnapshot(UpdateStatus.Disabled, Message: "Updates are unavailable."));
            return false;
        }

        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var now = time.GetUtcNow();
            if (!manual && !ledger.ShouldCheckAutomatically(now))
            {
                return ready is not null;
            }

            if (manual)
            {
                ledger.ClearPause();
            }

            Publish(new UpdateSnapshot(UpdateStatus.Checking));
            try
            {
                var offer = await client.CheckAsync(cancellationToken).ConfigureAwait(false);
                ledger.CheckSucceeded(time.GetUtcNow());
                if (offer is null)
                {
                    Publish(new UpdateSnapshot(manual ? UpdateStatus.UpToDate : UpdateStatus.Idle, options.CurrentVersion));
                    return false;
                }

                if (!manual && ledger.IsPaused(offer.Version))
                {
                    Publish(new UpdateSnapshot(UpdateStatus.Failed, offer.Version, "Update failed", options.InstallerUrl));
                    return false;
                }

                Publish(new UpdateSnapshot(UpdateStatus.Downloading, offer.Version));
                await client.DownloadAsync(offer, _ => { }, cancellationToken).ConfigureAwait(false);
                ready = offer;
                Publish(new UpdateSnapshot(UpdateStatus.ReadyToRestart, offer.Version));
                return true;
            }
            catch (OperationCanceledException)
            {
                Publish(snapshot with { Status = ready is null ? UpdateStatus.Idle : UpdateStatus.ReadyToRestart });
                throw;
            }
            catch (Exception error)
            {
                ledger.CheckFailed(time.GetUtcNow(), (error as UpdateHttpException)?.RetryAfter);
                Publish(manual
                    ? new UpdateSnapshot(UpdateStatus.CheckFailed, Message: error.Message, InstallerUrl: options.InstallerUrl)
                    : new UpdateSnapshot(UpdateStatus.Idle, Message: error.Message));
                return false;
            }
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Tray "Restart to Update": records the attempt, then restarts into the new version.</summary>
    public void ApplyAndRestart()
    {
        if (ready is { } offer)
        {
            ledger.ApplyStarted(offer.Version);
            applier.ApplyAndRestart(offer);
        }
    }

    /// <summary>On quit with a downloaded update: applies it as the app exits.</summary>
    public void ApplyOnExit()
    {
        if (ready is { } offer)
        {
            ledger.ApplyStarted(offer.Version);
            applier.ApplyOnExit(offer);
        }
    }

    private void Publish(UpdateSnapshot next)
    {
        snapshot = next;
        StateChanged?.Invoke(next);
    }

    private sealed class NoopUpdateApplier : IUpdateApplier
    {
        public void ApplyAndRestart(UpdateOffer offer)
        {
        }

        public void ApplyOnExit(UpdateOffer offer)
        {
        }
    }
}
