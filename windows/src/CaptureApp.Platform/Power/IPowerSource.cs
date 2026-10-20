namespace CaptureApp.Platform.Power;

public interface IPowerSource : IDisposable
{
    bool IsOnAC { get; }

    bool IsBatterySaverOn { get; }

    event EventHandler? Changed;

    event EventHandler? Suspending;

    event EventHandler? Resumed;
}

/// <summary>Mutable power source for deterministic gate tests.</summary>
public sealed class FakePowerSource(bool isOnAc = true, bool isBatterySaverOn = false) : IPowerSource
{
    private readonly object _sync = new();
    private bool _isOnAc = isOnAc;
    private bool _isBatterySaverOn = isBatterySaverOn;

    public bool IsOnAC
    {
        get { lock (_sync) return _isOnAc; }
    }

    public bool IsBatterySaverOn
    {
        get { lock (_sync) return _isBatterySaverOn; }
    }

    public event EventHandler? Changed;

    public event EventHandler? Suspending;

    public event EventHandler? Resumed;

    public void SetPower(bool isOnAc, bool isBatterySaverOn)
    {
        var changed = false;
        lock (_sync)
        {
            changed = _isOnAc != isOnAc || _isBatterySaverOn != isBatterySaverOn;
            _isOnAc = isOnAc;
            _isBatterySaverOn = isBatterySaverOn;
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
