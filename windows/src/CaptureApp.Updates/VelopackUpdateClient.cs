using Velopack;
using Velopack.Locators;

namespace CaptureApp.Updates;

/// <summary>Velopack-backed client and applier over one <see cref="UpdateManager"/>.</summary>
public sealed class VelopackUpdateClient(UpdateManager manager) : IUpdateClient, IUpdateApplier
{
    public async Task<UpdateOffer?> CheckAsync(CancellationToken cancellationToken)
    {
        var info = await manager.CheckForUpdatesAsync().ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return info is null ? null : new UpdateOffer(info.TargetFullRelease.Version.ToString(), info);
    }

    public Task DownloadAsync(UpdateOffer offer, Action<int> progress, CancellationToken cancellationToken) =>
        manager.DownloadUpdatesAsync((UpdateInfo)offer.Handle, progress, cancellationToken);

    /// <summary>Called at startup by a new process, so packages are found on disk rather than remembered from a download.</summary>
    public void DiscardDownloads(string version)
    {
        if (VelopackLocator.IsCurrentSet)
        {
            DiscardPackages(VelopackLocator.Current, version);
        }
    }

    /// <summary>
    /// Deletes the full and delta packages of <paramref name="version"/>. Velopack reuses a package that is
    /// already on disk instead of downloading it again, so a kept package would fail the next apply too.
    /// </summary>
    internal static void DiscardPackages(IVelopackLocator locator, string version)
    {
        if (!SemanticVersion.TryParse(version, out var discarded) || locator.PackagesDir is not { } directory || !Directory.Exists(directory))
        {
            return;
        }

        foreach (var package in locator.GetLocalPackages())
        {
            if (package.Version == discarded)
            {
                File.Delete(Path.Combine(directory, package.FileName));
            }
        }
    }

    public void ApplyAndRestart(UpdateOffer offer) =>
        manager.ApplyUpdatesAndRestart(((UpdateInfo)offer.Handle).TargetFullRelease);

    public void ApplyOnExit(UpdateOffer offer) =>
        manager.WaitExitThenApplyUpdates(((UpdateInfo)offer.Handle).TargetFullRelease, silent: true, restart: false);
}
