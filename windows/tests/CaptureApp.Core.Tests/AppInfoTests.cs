using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class AppInfoTests
{
    [Fact]
    public void IdentityMatchesTheSharedBuildEnvironment()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "Config", "app.env")))
        {
            directory = directory.Parent;
        }

        Assert.NotNull(directory);
        var environment = File.ReadAllLines(Path.Combine(directory.FullName, "Config", "app.env"))
            .Where(line => line.Contains('='))
            .Select(line => line.Split('=', 2))
            .ToDictionary(parts => parts[0], parts => parts[1], StringComparer.Ordinal);
        Assert.Equal(AppInfo.Name, environment["APPNAME"]);
        Assert.Equal(AppInfo.BundlePrefix, environment["BUNDLE_PREFIX"]);
        Assert.Equal($"{AppInfo.BundlePrefix}.{AppInfo.Name}", AppInfo.BundleId);
        Assert.Equal(AppInfo.Version, environment["VERSION"]);
        Assert.Equal(AppInfo.Build, environment["BUILD"]);
        Assert.Equal(AppInfo.GitHubRepo, environment["GITHUB_REPO"]);
    }
}
