using CaptureApp.AppCore.Shell;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class SettingsFailuresTests
{
    [Fact]
    public void SaveErrorsCoverLockedDeniedAndUnreplaceableData()
    {
        Assert.True(SettingsFailures.IsSaveError(new IOException()));
        Assert.True(SettingsFailures.IsSaveError(new UnauthorizedAccessException()));
        Assert.True(SettingsFailures.IsSaveError(new InvalidDataException()));
    }

    [Fact]
    public void OtherFailuresAreNotSaveErrors()
    {
        Assert.False(SettingsFailures.IsSaveError(new InvalidOperationException()));
    }
}
