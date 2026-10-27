using System.IO.Compression;
using CaptureApp.Updates;
using Velopack.Locators;
using Xunit;

namespace CaptureApp.Updates.Tests;

public sealed class VelopackUpdateClientTests
{
    private static void WritePackage(string directory, string fileName, string version)
    {
        using var archive = ZipFile.Open(Path.Combine(directory, fileName), ZipArchiveMode.Create);
        using var writer = new StreamWriter(archive.CreateEntry("app.nuspec").Open());
        writer.Write($"<package><metadata><id>app</id><version>{version}</version></metadata></package>");
    }

    [Fact]
    public void DiscardDeletesOnlyTheFailedVersionsPackagesFoundOnDisk()
    {
        var directory = Path.Combine(Path.GetTempPath(), "updates-discard-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            WritePackage(directory, "app-1.0.0-full.nupkg", "1.0.0");
            WritePackage(directory, "app-1.1.0-full.nupkg", "1.1.0");
            WritePackage(directory, "app-1.1.0-delta.nupkg", "1.1.0");
            WritePackage(directory, "app-1.1.0-beta.1-full.nupkg", "1.1.0-beta.1");
            WritePackage(directory, "app-11.1.0-full.nupkg", "11.1.0");

            // A new process: nothing was downloaded by this client, as after the relaunch that discards.
            VelopackUpdateClient.DiscardPackages(new TestVelopackLocator("app", "1.0.0", directory, null), "1.1.0");

            var left = Directory.EnumerateFiles(directory).Select(Path.GetFileName).Order(StringComparer.Ordinal);
            Assert.Equal(["app-1.0.0-full.nupkg", "app-1.1.0-beta.1-full.nupkg", "app-11.1.0-full.nupkg"], left);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
