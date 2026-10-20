using Xunit;


namespace CaptureApp.Platform.Tests;

public sealed class PlatformSmokeTests
{
    [Fact]
    public void PlatformAssemblyLoads() => Assert.NotNull(typeof(CaptureApp.Platform.PlatformAssembly).Assembly);
}
