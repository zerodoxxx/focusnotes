namespace CaptureApp.Platform.Power;

/// <summary>Publishes power changes and gates image embeddings on AC power with battery saver disabled.</summary>
public sealed class PowerMonitor : IDisposable
{
    private readonly IPowerSource _source;
    private readonly bool _ownsSource;
    private bool _lastAllowed;
    private bool _stopped;

    public PowerMonitor() : this(new WindowsPowerSource(), ownsSource: true)
    {
    }

    public PowerMonitor(IPowerSource source, bool ownsSource = false)
    {
        ArgumentNullException.ThrowIfNull(source);
        _source = source;
        _ownsSource = ownsSource;
        _lastAllowed = IsImageEmbeddingAllowed;
        _source.Changed += SourceChanged;
        _source.Suspending += SourceSuspending;
        _source.Resumed += SourceResumed;
    }

    public event EventHandler? PowerStateChanged;

    public event EventHandler<bool>? ImageEmbeddingAllowedChanged;

    public event EventHandler? Suspending;

    public event EventHandler? Resumed;

    public bool IsOnAC => _source.IsOnAC;

    public bool IsBatterySaverOn => _source.IsBatterySaverOn;

    public bool IsImageEmbeddingAllowed => _source.IsOnAC && !_source.IsBatterySaverOn;

    private void SourceChanged(object? sender, EventArgs eventArgs)
    {
        if (_stopped)
        {
            return;
        }

        PowerStateChanged?.Invoke(this, EventArgs.Empty);
        var allowed = IsImageEmbeddingAllowed;
        if (_lastAllowed != allowed)
        {
            _lastAllowed = allowed;
            ImageEmbeddingAllowedChanged?.Invoke(this, allowed);
        }
    }

    private void SourceSuspending(object? sender, EventArgs eventArgs)
    {
        if (!_stopped)
        {
            Suspending?.Invoke(this, EventArgs.Empty);
        }
    }

    private void SourceResumed(object? sender, EventArgs eventArgs)
    {
        if (!_stopped)
        {
            SourceChanged(sender, eventArgs);
            Resumed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Stop()
    {
        if (_stopped)
        {
            return;
        }

        _stopped = true;
        _source.Changed -= SourceChanged;
        _source.Suspending -= SourceSuspending;
        _source.Resumed -= SourceResumed;
        if (_ownsSource)
        {
            _source.Dispose();
        }
    }

    public void Dispose() => Stop();
}
