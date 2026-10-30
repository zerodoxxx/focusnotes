using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class DurableFileTests : IDisposable
{
    private const int SharingViolation = unchecked((int)0x80070020);

    private readonly string directory = Path.Combine(Path.GetTempPath(), "captureapp-durable-" + Guid.NewGuid().ToString("N"));

    public DurableFileTests() => Directory.CreateDirectory(directory);

    public void Dispose() => Directory.Delete(directory, true);

    [Fact]
    public void ReplaceRetriesSharingViolationsUntilTheScannerLetsGo()
    {
        var path = Path.Combine(directory, "unsaved", "record.json");
        DurableFile.Write(path, "old"u8.ToArray());
        var attempts = 0;
        DurableFile.MoveHook.Value = (source, target) =>
        {
            if (++attempts < 3) { throw new IOException("Held open by a scanner.", SharingViolation); }
            File.Move(source, target, true);
        };
        try { DurableFile.Write(path, "new"u8.ToArray()); }
        finally { DurableFile.MoveHook.Value = null; }

        Assert.Equal(3, attempts);
        Assert.Equal("new", File.ReadAllText(path));
        Assert.Equal(path, Assert.Single(Directory.GetFiles(Path.GetDirectoryName(path)!)));
    }

    [Fact]
    public void ReplaceDoesNotRetryOtherFailuresAndRemovesItsTemporary()
    {
        var path = Path.Combine(directory, "state.json");
        var attempts = 0;
        DurableFile.MoveHook.Value = (_, _) =>
        {
            attempts++;
            throw new IOException("Disk full.", unchecked((int)0x80070070));
        };
        try { Assert.Throws<IOException>(() => DurableFile.Write(path, "new"u8.ToArray())); }
        finally { DurableFile.MoveHook.Value = null; }

        Assert.Equal(1, attempts);
        Assert.Empty(Directory.GetFiles(directory));
    }

    [Theory]
    [InlineData(0x80070020, false, true)] // ERROR_SHARING_VIOLATION
    [InlineData(0x80070021, false, true)] // ERROR_LOCK_VIOLATION
    [InlineData(11, false, true)] // EAGAIN
    [InlineData(0x80070070, true, false)] // ERROR_DISK_FULL
    [InlineData(0x80070003, true, false)] // ERROR_PATH_NOT_FOUND
    public void OnlySharingAndLockViolationsAreTransientIOErrors(uint hresult, bool windows, bool transient)
    {
        Assert.Equal(transient, DurableFile.IsTransient(new IOException("", unchecked((int)hresult)), windows));
    }

    [Fact]
    public void AccessDeniedIsTransientOnlyOnWindows()
    {
        Assert.True(DurableFile.IsTransient(new UnauthorizedAccessException(), windows: true));
        Assert.False(DurableFile.IsTransient(new UnauthorizedAccessException(), windows: false));
    }
}
