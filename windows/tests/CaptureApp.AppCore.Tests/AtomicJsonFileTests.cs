using System.Text;
using CaptureApp.AppCore;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class AtomicJsonFileTests
{
    private const int SharingViolation = unchecked((int)0x80070020);

    [Fact]
    public void ReplaceRetriesSharingViolationsUntilTheScannerLetsGo()
    {
        using var temp = new TempDirectory();
        var path = Path.Combine(temp.Path, "unsaved", "record.json");
        AtomicJsonFile.Write(path, "old"u8.ToArray());
        var attempts = 0;
        AtomicJsonFile.MoveHook.Value = (source, target) =>
        {
            if (++attempts < 3) { throw new IOException("Held open by a scanner.", SharingViolation); }
            File.Move(source, target, true);
        };
        try { AtomicJsonFile.Write(path, "new"u8.ToArray()); }
        finally { AtomicJsonFile.MoveHook.Value = null; }

        Assert.Equal(3, attempts);
        Assert.Equal("new", File.ReadAllText(path));
        Assert.Equal(path, Assert.Single(Directory.GetFiles(Path.GetDirectoryName(path)!)));
    }

    [Fact]
    public void ReplaceDoesNotRetryOtherFailuresAndRemovesItsTemporary()
    {
        using var temp = new TempDirectory();
        var path = Path.Combine(temp.Path, "state.json");
        var attempts = 0;
        AtomicJsonFile.MoveHook.Value = (_, _) =>
        {
            attempts++;
            throw new IOException("Disk full.", unchecked((int)0x80070070));
        };
        try { Assert.Throws<IOException>(() => AtomicJsonFile.Write(path, "new"u8.ToArray())); }
        finally { AtomicJsonFile.MoveHook.Value = null; }

        Assert.Equal(1, attempts);
        Assert.Empty(Directory.GetFiles(temp.Path));
    }

    [Theory]
    [InlineData(0x80070020, false, true)] // ERROR_SHARING_VIOLATION
    [InlineData(0x80070021, false, true)] // ERROR_LOCK_VIOLATION
    [InlineData(11, false, true)] // EAGAIN
    [InlineData(0x80070070, true, false)] // ERROR_DISK_FULL
    [InlineData(0x80070003, true, false)] // ERROR_PATH_NOT_FOUND
    public void OnlySharingAndLockViolationsAreTransientIOErrors(uint hresult, bool windows, bool transient)
    {
        Assert.Equal(transient, AtomicJsonFile.IsTransient(new IOException("", unchecked((int)hresult)), windows));
    }

    [Fact]
    public void AccessDeniedIsTransientOnlyOnWindows()
    {
        Assert.True(AtomicJsonFile.IsTransient(new UnauthorizedAccessException(), windows: true));
        Assert.False(AtomicJsonFile.IsTransient(new UnauthorizedAccessException(), windows: false));
    }

    [Fact]
    public async Task CommitSavesAStagedCaptureWhileAScannerBrieflyHoldsItsJournalRecord()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Requires Windows sharing semantics.");
        using var temp = new TempDirectory();
        using var pipeline = CapturePipeline.Open(Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
        var job = pipeline.PrepareNote("Biology\n\nscannedrecordneedle", new());
        pipeline.Stage(job);
        var record = Assert.Single(pipeline.Journal.RecordPaths());
        var scanner = new FileStream(record, FileMode.Open, FileAccess.Read, FileShare.Read);
        var release = Task.Run(async () =>
        {
            await Task.Delay(300, TestContext.Current.CancellationToken);
            await scanner.DisposeAsync();
        }, TestContext.Current.CancellationToken);
        SavedCapture saved;
        try { saved = pipeline.Commit(job); }
        finally { await release; }

        Assert.Contains("scannedrecordneedle", File.ReadAllText(saved.Destination.Url, Encoding.UTF8), StringComparison.Ordinal);
        Assert.Empty(pipeline.Journal.RecordPaths());
    }
}
