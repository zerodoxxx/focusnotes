using CaptureApp.Updates;
using Xunit;

namespace CaptureApp.Updates.Tests;

public sealed class UpdateLedgerTests
{
    private static readonly DateTimeOffset T0 = new(2026, 10, 19, 12, 0, 0, TimeSpan.Zero);

    private static UpdateLedger NewLedger(out int saves)
    {
        saves = 0;
        return new UpdateLedger(new UpdateLedgerState(), () => { });
    }

    [Fact]
    public void BackoffSequenceCapsAtTwentyFourHours()
    {
        Assert.Equal([1, 4, 12, 24, 24, 24], Enumerable.Range(1, 6).Select(n => (int)UpdateBackoff.Delay(n).TotalHours));
    }

    [Fact]
    public void RetryAfterOnlyLengthensTheWait()
    {
        Assert.Equal(TimeSpan.FromHours(3), UpdateBackoff.Delay(1, TimeSpan.FromHours(3)));
        Assert.Equal(TimeSpan.FromHours(4), UpdateBackoff.Delay(2, TimeSpan.FromMinutes(5)));
    }

    [Fact]
    public void FailuresWalkTheBackoffAndSuccessResetsIt()
    {
        var ledger = NewLedger(out _);
        var now = T0;
        foreach (var hours in new[] { 1, 4, 12, 24, 24 })
        {
            ledger.CheckFailed(now, null);
            Assert.Equal(now.AddHours(hours), ledger.NextAutomaticCheck(now));
            Assert.False(ledger.ShouldCheckAutomatically(now));
            now = now.AddHours(hours);
            Assert.True(ledger.ShouldCheckAutomatically(now));
        }

        ledger.CheckSucceeded(now);
        Assert.Equal(0, ledger.State.ConsecutiveFailures);
        Assert.Equal(now.AddHours(24), ledger.NextAutomaticCheck(now));
        ledger.CheckFailed(now, null);
        Assert.Equal(now.AddHours(1), ledger.NextAutomaticCheck(now));
    }

    [Fact]
    public void RetryAfterIsHonouredInTheSchedule()
    {
        var ledger = NewLedger(out _);
        ledger.CheckFailed(T0, TimeSpan.FromHours(6));
        Assert.Equal(T0.AddHours(6), ledger.NextAutomaticCheck(T0));
    }

    [Fact]
    public void ClockMovedBackNeverStallsChecksBeyondADay()
    {
        var ledger = NewLedger(out _);
        ledger.CheckSucceeded(T0.AddDays(30));
        Assert.True(ledger.NextAutomaticCheck(T0) <= T0.AddHours(24));
        Assert.True(ledger.ShouldCheckAutomatically(T0));
    }

    [Fact]
    public void AbsurdRetryAfterIsCappedAtADayAndNegativeIgnored()
    {
        Assert.Equal(TimeSpan.FromHours(24), UpdateBackoff.Delay(1, TimeSpan.FromDays(365)));
        Assert.Equal(TimeSpan.FromHours(1), UpdateBackoff.Delay(1, TimeSpan.FromHours(-5)));
        var ledger = NewLedger(out _);
        ledger.CheckFailed(T0, TimeSpan.FromDays(365));
        Assert.Equal(T0.AddHours(24), ledger.NextAutomaticCheck(T0));
    }

    [Fact]
    public void FirstLaunchChecksImmediately()
    {
        Assert.True(NewLedger(out _).ShouldCheckAutomatically(T0));
    }

    [Fact]
    public void ApplyThatTookEffectClearsTheBookkeeping()
    {
        var ledger = NewLedger(out _);
        ledger.ApplyStarted("1.2.0");
        Assert.Equal(StartupOutcome.Applied, ledger.ReconcileStartup("1.2.0"));
        Assert.Null(ledger.State.PendingApplyVersion);
        Assert.Equal(StartupOutcome.None, ledger.ReconcileStartup("1.2.0"));
    }

    [Fact]
    public void FirstFailedApplyRetriesOnceThenSecondDiscardsAndPauses()
    {
        var ledger = NewLedger(out _);
        ledger.ApplyStarted("1.2.0");
        Assert.Equal(StartupOutcome.RetryAtQuit, ledger.ReconcileStartup("1.1.0"));
        Assert.False(ledger.IsPaused("1.2.0"));

        ledger.ApplyStarted("1.2.0");
        Assert.Equal(StartupOutcome.Discard, ledger.ReconcileStartup("1.1.0"));
        Assert.True(ledger.IsPaused("1.2.0"));
        Assert.True(ledger.IsPaused("1.1.5"));
        Assert.False(ledger.IsPaused("1.2.1"));
    }

    [Fact]
    public void ManualRetryLiftsThePause()
    {
        var ledger = NewLedger(out _);
        ledger.ApplyStarted("1.2.0");
        ledger.ReconcileStartup("1.1.0");
        ledger.ApplyStarted("1.2.0");
        ledger.ReconcileStartup("1.1.0");
        ledger.ClearPause();
        Assert.False(ledger.IsPaused("1.2.0"));
    }

    [Fact]
    public void FailureCountIsPerVersion()
    {
        var ledger = NewLedger(out _);
        ledger.ApplyStarted("1.2.0");
        ledger.ReconcileStartup("1.1.0");
        ledger.ApplyStarted("1.3.0");
        Assert.Equal(StartupOutcome.RetryAtQuit, ledger.ReconcileStartup("1.1.0"));
    }

    [Theory]
    [InlineData("1.2.0", "1.2.0-ci.1", 1)]
    [InlineData("1.2.0-ci.2", "1.2.0-ci.10", -1)]
    [InlineData("1.10.0", "1.9.9", 1)]
    [InlineData("v1.0.0", "1.0.0", 0)]
    public void VersionOrdering(string a, string b, int expected) =>
        Assert.Equal(expected, Math.Sign(VersionOrder.Compare(a, b)));
}
