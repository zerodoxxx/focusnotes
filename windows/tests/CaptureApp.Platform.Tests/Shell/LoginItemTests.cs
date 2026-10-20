using System;
using CaptureApp.Platform.Shell;
using Xunit;

namespace CaptureApp.Platform.Tests.Shell;

public sealed class LoginItemTests
{
    [Fact]
    public void WritesReadsAndDeletesTheNamedRunValue()
    {
        var valueName = $"Platform.Tests.{Guid.NewGuid():N}";
        var executablePath = Environment.ProcessPath ?? throw new InvalidOperationException("Test process path is unavailable.");
        var loginItem = new LoginItem(valueName, executablePath);

        try
        {
            loginItem.SetEnabled(true);
            Assert.True(loginItem.IsEnabled);
            Assert.Equal(LoginItem.QuoteExecutablePath(executablePath), loginItem.RegisteredCommand);

            loginItem.SetEnabled(false);
            Assert.False(loginItem.IsEnabled);
        }
        finally
        {
            loginItem.SetEnabled(false);
        }
    }

    [Fact]
    public void QuotedRunCommandMustFitWithinMaxPath()
    {
        var tooLongPath = $@"C:\{new string('a', 258)}.exe";
        Assert.Throws<ArgumentException>(() => LoginItem.QuoteExecutablePath(tooLongPath));
    }
}
