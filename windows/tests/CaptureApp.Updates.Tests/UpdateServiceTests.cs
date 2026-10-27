using CaptureApp.Updates;
using Xunit;

namespace CaptureApp.Updates.Tests;

public sealed class UpdateServiceTests
{
    private sealed class FakeTimeProvider(DateTimeOffset start) : TimeProvider
    {
        private DateTimeOffset now = start;

        public override DateTimeOffset GetUtcNow() => now;

        public void Advance(TimeSpan by) => now += by;
    }

    private sealed class MemoryStore : IUpdateStateStore
    {
        public UpdateLedgerState State { get; set; } = new();

        public UpdateLedgerState Load() => State;

        public void Save(UpdateLedgerState state) => State = state;
    }

    private sealed class FakeClient : IUpdateClient, IUpdateApplier
    {
        public string? OfferVersion { get; set; } = "1.1.0";
        public Exception? Failure { get; set; }
        public int Checks { get; private set; }
        public List<string> Discarded { get; } = [];
        public Exception? DiscardFailure { get; set; }
        public List<string> Applied { get; } = [];

        public Task<UpdateOffer?> CheckAsync(CancellationToken cancellationToken)
        {
            Checks++;
            if (Failure is not null)
            {
                throw Failure;
            }

            return Task.FromResult(OfferVersion is null ? null : new UpdateOffer(OfferVersion, OfferVersion));
        }

        public Task DownloadAsync(UpdateOffer offer, Action<int> progress, CancellationToken cancellationToken) => Task.CompletedTask;

        public void DiscardDownloads(string version)
        {
            Discarded.Add(version);
            if (DiscardFailure is not null)
            {
                throw DiscardFailure;
            }
        }

        public void ApplyAndRestart(UpdateOffer offer) => Applied.Add("restart " + offer.Version);

        public void ApplyOnExit(UpdateOffer offer) => Applied.Add("exit " + offer.Version);
    }

    private static readonly UpdateServiceOptions Options = new() { CurrentVersion = "1.0.0", InstallerUrl = "https://example.invalid/releases" };

    private static (UpdateService Service, FakeClient Client, MemoryStore Store, FakeTimeProvider Time) Create(string current = "1.0.0", MemoryStore? existing = null)
    {
        var client = new FakeClient();
        var store = existing ?? new MemoryStore();
        var time = new FakeTimeProvider(new DateTimeOffset(2026, 10, 19, 12, 0, 0, TimeSpan.Zero));
        var service = new UpdateService(client, client, store, new UpdateServiceOptions { CurrentVersion = current, InstallerUrl = Options.InstallerUrl }, time);
        return (service, client, store, time);
    }

    [Fact]
    public async Task EmptyKeySetDisablesUpdates()
    {
        var store = new MemoryStore();
        var service = UpdateService.CreateDisabled(store, Options);
        Assert.False(service.IsEnabled);
        Assert.Equal(UpdateStatus.Disabled, service.Snapshot.Status);
        Assert.False(await service.CheckAsync(manual: true, CancellationToken.None));
        Assert.Equal(UpdateStatus.Disabled, service.Snapshot.Status);
        Assert.Equal(TrustedKeys.Empty.IsEmpty, TrustedKeys.Parse("").IsEmpty);
    }

    [Fact]
    public async Task CheckDownloadsAndOffersRestart()
    {
        var (service, _, _, _) = Create();
        Assert.True(await service.CheckAsync(manual: false, CancellationToken.None));
        Assert.Equal("Restart to Update (v1.1.0)", service.Snapshot.RestartLabel);
    }

    [Fact]
    public async Task AutomaticChecksHonourBackoffButManualBypasses()
    {
        var (service, client, _, time) = Create();
        client.Failure = new UpdateHttpException(429, TimeSpan.FromHours(6), "rate limited");
        Assert.False(await service.CheckAsync(manual: false, CancellationToken.None));
        Assert.Equal(1, client.Checks);
        Assert.Equal(UpdateStatus.Idle, service.Snapshot.Status);

        await service.CheckAsync(manual: false, CancellationToken.None);
        Assert.Equal(1, client.Checks);
        Assert.Equal(TimeSpan.FromHours(6), service.NextAutomaticDelay());

        client.Failure = null;
        await service.CheckAsync(manual: true, CancellationToken.None);
        Assert.Equal(2, client.Checks);
        Assert.Equal(UpdateStatus.ReadyToRestart, service.Snapshot.Status);

        time.Advance(TimeSpan.FromHours(25));
        Assert.Equal(TimeSpan.Zero, service.NextAutomaticDelay());
    }

    [Fact]
    public async Task ManualCheckSurfacesARefusedIndex()
    {
        var (service, client, _, _) = Create();
        client.Failure = new IndexVerificationException(IndexRejection.InvalidSignature, "The update index signature is invalid.");
        Assert.False(await service.CheckAsync(manual: true, CancellationToken.None));
        Assert.Equal(UpdateStatus.CheckFailed, service.Snapshot.Status);
        Assert.True(service.Snapshot.CanRetry);
    }

    [Fact]
    public async Task ApplyIsRecordedAndFailsThroughTheO5Sequence()
    {
        var (service, client, store, _) = Create();
        await service.CheckAsync(manual: true, CancellationToken.None);
        service.ApplyOnExit();
        Assert.Equal(["exit 1.1.0"], client.Applied);
        Assert.Equal("1.1.0", store.State.PendingApplyVersion);

        // Relaunch still on 1.0.0: first failure, retried once at the next quit.
        var (second, client2, store2, _) = Create(existing: store);
        await second.StartAsync(CancellationToken.None);
        Assert.Equal(UpdateStatus.ReadyToRestart, second.Snapshot.Status);
        second.ApplyOnExit();
        Assert.Equal(["exit 1.1.0"], client2.Applied);

        // Still failing: package discarded, Failed state, automatic attempts paused.
        var (third, client3, _, time3) = Create(existing: store2);
        await third.StartAsync(CancellationToken.None);
        Assert.Equal(["1.1.0"], client3.Discarded);
        Assert.Equal(UpdateStatus.Failed, third.Snapshot.Status);
        Assert.Equal(Options.InstallerUrl, third.Snapshot.InstallerUrl);
        time3.Advance(TimeSpan.FromHours(25));
        Assert.False(await third.CheckAsync(manual: false, CancellationToken.None));
        Assert.Equal(1, client3.Checks);
        Assert.Equal(UpdateStatus.Failed, third.Snapshot.Status);
        Assert.Empty(client3.Applied);

        // A newer version lifts the automatic pause.
        client3.OfferVersion = "1.2.0";
        time3.Advance(TimeSpan.FromHours(25));
        Assert.True(await third.CheckAsync(manual: false, CancellationToken.None));
        Assert.Equal("1.2.0", third.Snapshot.Version);
    }

    [Fact]
    public async Task UndeletablePackageStillShowsTheFailedState()
    {
        var store = new MemoryStore { State = new UpdateLedgerState { PendingApplyVersion = "1.1.0", ApplyFailureVersion = "1.1.0", ApplyFailures = 1 } };
        var (service, client, _, _) = Create(existing: store);
        client.DiscardFailure = new IOException("package in use");
        await Assert.ThrowsAsync<IOException>(() => service.StartAsync(CancellationToken.None));
        Assert.Equal(["1.1.0"], client.Discarded);
        Assert.Equal(UpdateStatus.Failed, service.Snapshot.Status);
        Assert.Equal(Options.InstallerUrl, service.Snapshot.InstallerUrl);
    }

    [Fact]
    public async Task SuccessfulApplyClearsPending()
    {
        var (service, _, store, _) = Create();
        await service.CheckAsync(manual: true, CancellationToken.None);
        service.ApplyAndRestart();

        var (relaunched, _, _, _) = Create(current: "1.1.0", existing: store);
        await relaunched.StartAsync(CancellationToken.None);
        Assert.Null(store.State.PendingApplyVersion);
        Assert.NotEqual(UpdateStatus.Failed, relaunched.Snapshot.Status);
    }

    [Fact]
    public void SettingsStorePreservesOtherSectionsAndRoundTrips()
    {
        var path = Path.Combine(Path.GetTempPath(), "updates-test-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            File.WriteAllText(path, "{\"theme\":\"dark\"}");
            var store = new SettingsFileUpdateStateStore(path);
            store.Save(new UpdateLedgerState { ConsecutiveFailures = 2, PausedVersion = "1.2.0" });
            var loaded = store.Load();
            Assert.Equal(2, loaded.ConsecutiveFailures);
            Assert.Equal("1.2.0", loaded.PausedVersion);
            Assert.Contains("\"theme\"", File.ReadAllText(path), StringComparison.Ordinal);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task UnwritableSettingsNeverBreakChecksOrStartup()
    {
        var blocker = Path.Combine(Path.GetTempPath(), "updates-block-" + Guid.NewGuid().ToString("N"));
        File.WriteAllText(blocker, "x");
        try
        {
            var logged = new List<string>();
            var store = new SettingsFileUpdateStateStore(Path.Combine(blocker, "settings.json"), logged.Add);
            store.Save(new UpdateLedgerState());
            Assert.Single(logged);

            var client = new FakeClient();
            var service = new UpdateService(client, client, store, new UpdateServiceOptions { CurrentVersion = "1.0.0" });
            await service.StartAsync(CancellationToken.None);
            Assert.True(await service.CheckAsync(manual: true, CancellationToken.None));
            service.ApplyOnExit();
            Assert.Single(client.Applied);
        }
        finally
        {
            File.Delete(blocker);
        }
    }

    private sealed class FakeFetcher(Uri redirect) : IIndexFetcher
    {
        public Task<byte[]> GetBytesAsync(Uri uri, CancellationToken cancellationToken) => throw new NotSupportedException();

        public Task<Uri> ResolveRedirectAsync(Uri uri, CancellationToken cancellationToken) => Task.FromResult(redirect);
    }

    [Fact]
    public async Task StableLocatorPinsTheConcreteReleaseTag()
    {
        var locator = new StableIndexLocator("owner/repo", new FakeFetcher(new Uri("https://github.com/owner/repo/releases/tag/v1.2.3")));
        var location = await locator.LocateAsync("win-x64", CancellationToken.None);
        Assert.Equal("https://github.com/owner/repo/releases/download/v1.2.3/releases.win-x64.json", location.For("releases.win-x64.json").ToString());
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            new StableIndexLocator("owner/repo", new FakeFetcher(new Uri("https://github.com/owner/repo"))).LocateAsync("win-x64", CancellationToken.None));
    }
}
