using CaptureApp.Core;
using Velopack;

namespace CaptureApp.Updates;

public static class UpdateServiceFactory
{
    /// <summary>
    /// Builds the update service. Returns a disabled service (updates unavailable, like the Mac app
    /// without a Sparkle key) when no trusted keys are configured or the app was not installed by Setup.
    /// </summary>
    public static UpdateService Create(string settingsPath)
    {
        var keys = TrustedKeys.Empty;
        IIndexLocator? locator = null;
#if CI_UPDATE_TESTS
        (keys, locator) = CiOverrides.Read();
#endif
        return Create(settingsPath, keys, locator);
    }

    public static UpdateService Create(string settingsPath, TrustedKeys keys, IIndexLocator? locator)
    {
        var store = new SettingsFileUpdateStateStore(settingsPath);
        var options = new UpdateServiceOptions
        {
            CurrentVersion = AppInfo.Version,
            InstallerUrl = $"https://github.com/{AppInfo.GitHubRepo}/releases/latest",
        };

        if (keys.IsEmpty && TryParseConfiguredKeys(out var configured))
        {
            keys = configured;
        }

        if (keys.IsEmpty)
        {
            return UpdateService.CreateDisabled(store, options);
        }

        var fetcher = new HttpIndexFetcher();
        var beta = store.Load().IncludePrereleases;
        locator ??= beta ? new PrereleaseIndexLocator(AppInfo.GitHubRepo, fetcher) : new StableIndexLocator(AppInfo.GitHubRepo, fetcher);
        var manager = new UpdateManager(new VerifiedUpdateSource(locator, fetcher, keys));
        if (!manager.IsInstalled)
        {
            return UpdateService.CreateDisabled(store, options);
        }

        var client = new VelopackUpdateClient(manager);
        return new UpdateService(client, client, store, new UpdateServiceOptions
        {
            CurrentVersion = manager.CurrentVersion?.ToString() ?? AppInfo.Version,
            InstallerUrl = options.InstallerUrl,
        });
    }

    private static bool TryParseConfiguredKeys(out TrustedKeys keys)
    {
        try
        {
            keys = TrustedKeys.Parse(AppInfo.WindowsUpdateKeys);
            return !keys.IsEmpty;
        }
        catch (FormatException)
        {
            keys = TrustedKeys.Empty;
            return false;
        }
    }
}
