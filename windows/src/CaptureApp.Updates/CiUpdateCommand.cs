#if CI_UPDATE_TESTS
using System.Runtime.InteropServices;
using Velopack;
using Velopack.Locators;

namespace CaptureApp.Updates;

/// <summary>Test-only overrides; compiled only into CI packages (CIUpdateTests=true), never into releases.</summary>
internal static class CiOverrides
{
    public static (TrustedKeys Keys, IIndexLocator? Locator) Read()
    {
        var keys = Environment.GetEnvironmentVariable("CAPTUREAPP_UPDATE_KEYS_OVERRIDE");
        var url = Environment.GetEnvironmentVariable("CAPTUREAPP_UPDATE_URL_OVERRIDE");
        return (TrustedKeys.Parse(keys), string.IsNullOrEmpty(url) ? null : new StaticIndexLocator(new Uri(url)));
    }
}

internal sealed class StaticIndexLocator(Uri baseUri) : IIndexLocator
{
    public Task<IndexLocation> LocateAsync(string channel, CancellationToken cancellationToken) =>
        Task.FromResult(new IndexLocation(baseUri));
}

/// <summary><c>--ci-update info|check|apply</c>: drives the installed app's update flow from CI.</summary>
public static class CiUpdateCommand
{
    public static async Task<int> RunAsync(string[] args)
    {
        var verb = args.Length > 1 ? args[1] : "";
        var (keys, locator) = CiOverrides.Read();
        var manager = new UpdateManager(new VerifiedUpdateSource(locator ?? throw new InvalidOperationException("CAPTUREAPP_UPDATE_URL_OVERRIDE is required."), new HttpIndexFetcher(), keys));
        if (verb == "info")
        {
            Console.WriteLine($"arch={RuntimeInformation.ProcessArchitecture} channel={VelopackLocator.Current.Channel} version={manager.CurrentVersion} installed={manager.IsInstalled}");
            return 0;
        }

        var service = UpdateServiceFactory.Create(Path.Combine(Path.GetTempPath(), "captureapp-ci-settings.json"), keys, locator);
        var ready = await service.CheckAsync(manual: true, CancellationToken.None).ConfigureAwait(false);
        var snapshot = service.Snapshot;
        Console.WriteLine($"status={snapshot.Status} version={snapshot.Version} message={snapshot.Message}");
        if (verb == "check")
        {
            return snapshot.Status is UpdateStatus.CheckFailed or UpdateStatus.Failed or UpdateStatus.Disabled ? 3 : 0;
        }

        if (verb == "apply" && ready)
        {
            service.ApplyAndRestart();
            return 0;
        }

        return 4;
    }
}
#endif
