using System;
using System.Collections.Generic;
using CaptureApp.Platform.Power;
using Xunit;

namespace CaptureApp.Platform.Tests.Power;

public sealed class PowerMonitorTests
{
    [Theory]
    [InlineData(true, false, true)]
    [InlineData(true, true, false)]
    [InlineData(false, false, false)]
    [InlineData(false, true, false)]
    public void ImageEmbeddingGateRequiresAcAndBatterySaverOff(bool onAc, bool batterySaver, bool expectedAllowed)
    {
        var source = new FakePowerSource(onAc, batterySaver);
        using var monitor = new PowerMonitor(source);

        Assert.Equal(expectedAllowed, monitor.IsImageEmbeddingAllowed);
    }

    [Fact]
    public void GateChangesAreReportedWhenPowerStateChanges()
    {
        var source = new FakePowerSource(isOnAc: false);
        using var monitor = new PowerMonitor(source);
        var changes = new List<bool>();
        monitor.ImageEmbeddingAllowedChanged += (_, allowed) => changes.Add(allowed);

        source.SetPower(isOnAc: true, isBatterySaverOn: false);
        source.SetPower(isOnAc: true, isBatterySaverOn: true);

        Assert.Equal(new[] { true, false }, changes);
    }

    [Fact]
    public void SuspendAndResumeEventsPassThroughThePowerSource()
    {
        var source = new FakePowerSource();
        using var monitor = new PowerMonitor(source);
        var suspendCount = 0;
        var resumeCount = 0;
        monitor.Suspending += (_, _) => suspendCount++;
        monitor.Resumed += (_, _) => resumeCount++;

        source.SignalSuspending();
        source.SignalResumed();

        Assert.Equal(1, suspendCount);
        Assert.Equal(1, resumeCount);
    }
}
