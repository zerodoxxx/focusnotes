namespace CaptureApp.Platform.Power;

public interface IPowerSource : IDisposable
{
    bool IsOnAC { get; }

    bool IsBatterySaverOn { get; }

    event EventHandler? Changed;

    event EventHandler? Suspending;

    event EventHandler? Resumed;
}

/// <summary>A change is any difference in either field.</summary>
internal readonly record struct PowerSnapshot(bool IsOnAc, bool IsBatterySaverOn);

/// <summary>Mutable power source for deterministic gate tests.</summary>
public sealed class FakePowerSource(bool isOnAc = true, bool isBatterySaverOn = false) : IPowerSource
{
    private readonly object _sync = new();
    private PowerSnapshot _power = new(isOnAc, isBatterySaverOn);

    public bool IsOnAC
    {
        get { lock (_sync) return _power.IsOnAc; }
    }

    public bool IsBatterySaverOn
    {
        get { lock (_sync) return _power.IsBatterySaverOn; }
    }

    public event EventHandler? Changed;

    public event EventHandler? Suspending;

    public event EventHandler? Resumed;

    public void SetPower(bool isOnAc, bool isBatterySaverOn)
    {
        var changed = false;
        lock (_sync)
        {
            var next = new PowerSnapshot(isOnAc, isBatterySaverOn);
            changed = _power != next;
            _power = next;
        }

        if (changed)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void SignalSuspending() => Suspending?.Invoke(this, EventArgs.Empty);

    public void SignalResumed() => Resumed?.Invoke(this, EventArgs.Empty);

    public void Dispose()
    {
    }
}
