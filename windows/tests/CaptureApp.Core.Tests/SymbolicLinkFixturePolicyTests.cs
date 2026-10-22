using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class SymbolicLinkFixturePolicyTests
{
    [Theory]
    [InlineData(true, unchecked((int)0x80070522), "1", null, null, true)]
    [InlineData(false, unchecked((int)0x80070522), "1", null, null, false)]
    [InlineData(true, unchecked((int)0x80070522), null, null, null, false)]
    [InlineData(true, unchecked((int)0x80070522), "0", null, null, false)]
    [InlineData(true, unchecked((int)0x80070522), "true", null, null, false)]
    [InlineData(true, unchecked((int)0x80070522), "1", "1", null, false)]
    [InlineData(true, unchecked((int)0x80070522), "1", null, "true", false)]
    [InlineData(true, unchecked((int)0x80070522), "1", "false", null, false)]
    [InlineData(true, unchecked((int)0x80070005), "1", null, null, false)]
    [InlineData(true, unchecked((int)0x80040522), "1", null, null, false)]
    [InlineData(true, 1314, "1", null, null, false)]
    public void OnlyExplicitLocalWindowsPrivilegeFailuresCanSkip(bool windows, int hresult, string? optIn,
        string? ci, string? githubActions, bool expected)
    {
        var error = new IOException("Fixture creation failed.", hresult);
        Assert.Equal(expected, CheckVault.MaySkipMissingSymbolicLinkPrivilege(error, windows, optIn, ci, githubActions));
    }
}
