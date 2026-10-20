using Velopack;
using Velopack.Locators;

namespace CaptureApp.Updates;

/// <summary>Velopack-backed client and applier over one <see cref="UpdateManager"/>.</summary>
public sealed class VelopackUpdateClient(UpdateManager manager) : IUpdateClient, IUpdateApplier
{
    private string? downloadedVersion;

    public async Task<UpdateOffer?> CheckAsync(CancellationToken cancellationToken)
    {
        var info = await manager.CheckForUpdatesAsync().ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return info is null ? null : new UpdateOffer(info.TargetFullRelease.Version.ToString(), info);
    }

    public async Task DownloadAsync(UpdateOffer offer, Action<int> progress, CancellationToken cancellationToken)
    {
        await manager.DownloadUpdatesAsync((UpdateInfo)offer.Handle, progress, cancellationToken).ConfigureAwait(false);
        downloadedVersion = offer.Version;
    }

    public void DiscardDownloads()
    {
        if (downloadedVersion is null || !VelopackLocator.IsCurrentSet || VelopackLocator.Current.PackagesDir is not { } directory || !Directory.Exists(directory))
        {
            return;
        }

        foreach (var file in Directory.EnumerateFiles(directory, "*.nupkg"))
        {
            if (Path.GetFileName(file).Contains(downloadedVersion, StringComparison.Ordinal))
            {
                File.Delete(file);
            }
        }
    }

    public void ApplyAndRestart(UpdateOffer offer) =>
        manager.ApplyUpdatesAndRestart(((UpdateInfo)offer.Handle).TargetFullRelease);

    public void ApplyOnExit(UpdateOffer offer) =>
        manager.WaitExitThenApplyUpdates(((UpdateInfo)offer.Handle).TargetFullRelease, silent: true, restart: false);
}
