using System.Text;
using CaptureApp.AppCore;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class JournalScannerLockTests
{
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
