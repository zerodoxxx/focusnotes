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
}
