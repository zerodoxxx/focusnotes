namespace CaptureApp.Updates;

/// <summary>
/// Holds the first-run flag. The Velopack hook itself (<c>VelopackApp.Build().OnFirstRun(...).Run()</c>) must be
/// written literally in the exe's <c>Main</c>, because <c>vpk pack</c> scans the main executable for the call.
/// </summary>
public static class UpdateBootstrap
{
    /// <summary>True when this launch is the first run after a fresh install (the Setup flow reads it).</summary>
    public static bool IsFirstRun { get; private set; }

    /// <summary>Call from the <c>OnFirstRun</c> callback.</summary>
    public static void MarkFirstRun() => IsFirstRun = true;
}
