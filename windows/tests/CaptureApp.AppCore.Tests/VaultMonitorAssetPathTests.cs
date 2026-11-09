using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class VaultMonitorAssetPathTests
{
    [Fact]
    public void AssetPathsAreRecognisedWhateverTheCaseOfTheDirectoryName()
    {
        Assert.True(VaultMonitor.IsKnownAssetPath("assets/x.png"));
        Assert.True(VaultMonitor.IsKnownAssetPath("ASSETS/x.png"));
        Assert.True(VaultMonitor.IsKnownAssetPath("Assets/sub/x.png"));
    }

    [Fact]
    public void PathsOutsideAssetsOrEscapingItAreNotKnownAssets()
    {
        Assert.False(VaultMonitor.IsKnownAssetPath("notes/x.png"));
        Assert.False(VaultMonitor.IsKnownAssetPath("assets"));
        Assert.False(VaultMonitor.IsKnownAssetPath("assets/../x.png"));
    }

    [Fact]
    public void WatcherReportedAssetCasingsCanonicaliseToOneRecheckPath()
    {
        var recheck = new HashSet<string>(
            new[] { "Assets/x.png", "ASSETS/x.png", "assets/x.png" }.Select(VaultMonitor.CanonicalAssetPath),
            StringComparer.Ordinal);

        Assert.Equal("assets/x.png", Assert.Single(recheck));
        Assert.Equal("assets/Sub/X.png", VaultMonitor.CanonicalAssetPath("ASSETS/Sub/X.png"));
        Assert.Equal("notes/Assets.md", VaultMonitor.CanonicalAssetPath("notes/Assets.md"));
    }
}
