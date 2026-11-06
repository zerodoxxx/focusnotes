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

    [Fact]
    public void LoginItemErrorsCoverRunKeyFailuresOnly()
    {
        Assert.True(SettingsFailures.IsLoginItemError(new InvalidOperationException()));
        Assert.True(SettingsFailures.IsLoginItemError(new UnauthorizedAccessException()));
        Assert.True(SettingsFailures.IsLoginItemError(new System.Security.SecurityException()));
        Assert.True(SettingsFailures.IsLoginItemError(new ArgumentException()));
        Assert.False(SettingsFailures.IsLoginItemError(new IOException()));
    }
}
