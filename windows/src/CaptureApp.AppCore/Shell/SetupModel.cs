using System.Globalization;
using System.Text.Json.Nodes;

namespace CaptureApp.AppCore.Shell;

public enum SetupStepId { Disclosure, NotesFolder, Shortcuts, SelectionTest, AreaTest, TrayIcon, StartAtLogin, Updates, Semantic }

/// Required steps must pass; Recommended steps need a Pass or an explicit Skip (§5 "Step classes").
public enum SetupStepClass { Required, Recommended }

public enum SetupStatus { Pending, Passed, Failed, Skipped }

public sealed record SetupStepInfo(SetupStepId Id, string Key, int Number, string Title, SetupStepClass Class, int IntroducedIn = 1);

public sealed record SetupStepState(SetupStepId Id, SetupStatus Status, DateTimeOffset? At = null, string? Detail = null);

public static class SetupSteps
{
    /// Bump when a release adds steps; only steps introduced after the stored version are shown again.
    public const int CurrentVersion = 1;

    public static IReadOnlyList<SetupStepInfo> All { get; } =
    [
        new(SetupStepId.Disclosure, "disclosure", 0, "Disclosure and consent", SetupStepClass.Required),
        new(SetupStepId.NotesFolder, "notesFolder", 1, "Notes folder", SetupStepClass.Required),
        new(SetupStepId.Shortcuts, "shortcuts", 2, "Keyboard shortcuts", SetupStepClass.Required),
        new(SetupStepId.SelectionTest, "selectionTest", 3, "Selection capture test", SetupStepClass.Recommended),
        new(SetupStepId.AreaTest, "areaTest", 4, "Area capture test", SetupStepClass.Recommended),
        new(SetupStepId.TrayIcon, "trayIcon", 5, "Tray icon", SetupStepClass.Recommended),
        new(SetupStepId.StartAtLogin, "startAtLogin", 6, "Start at login", SetupStepClass.Recommended),
        new(SetupStepId.Updates, "updates", 7, "Updates", SetupStepClass.Recommended),
        new(SetupStepId.Semantic, "semantic", 8, "Semantic search", SetupStepClass.Recommended)
    ];

    public static SetupStepInfo Info(SetupStepId id) => All.Single(step => step.Id == id);
}

/// The cheap checks re-run at every launch (§5 "Re-validation"). null means the check did not apply.
public sealed record RevalidationReport(bool? FolderWritable, IReadOnlyCollection<string> FailedShortcuts,
    bool? RunKeyPresent, bool UpdateChoicePresent);

/// The persisted Setup state machine: settings.json → setup { version, steps.&lt;id&gt; { status, at, detail } }.
/// Every change is written atomically before it returns, so killing the app at any point resumes there.
public sealed class SetupState
{
    private readonly SettingsStore store;
    private readonly TimeProvider clock;
    private int storedVersion;
    private bool hasStoredState;
    private Dictionary<SetupStepId, SetupStepState> states = [];

    public SetupState(SettingsStore store, TimeProvider? clock = null)
    {
        this.store = store;
        this.clock = clock ?? TimeProvider.System;
        Reload();
    }

    /// True when no Setup state has ever been stored (first run, or a corrupt file was quarantined).
    public bool NeverRan => !hasStoredState;

    public int StoredVersion => storedVersion;

    public IReadOnlyList<SetupStepState> Steps => SetupSteps.All.Select(info => State(info.Id)).ToArray();

    public SetupStepState State(SetupStepId id) =>
        states.TryGetValue(id, out var state) ? state : new SetupStepState(id, SetupStatus.Pending);

    public SetupStatus Status(SetupStepId id) => State(id).Status;

    /// Step 0 answered: both the clipboard-fallback choice and the update choice were recorded.
    public bool ConsentAnswered => Status(SetupStepId.Disclosure) == SetupStatus.Passed;

    public void Reload()
    {
        var section = store.ReadSetup();
        states = [];
        hasStoredState = section is not null;
        storedVersion = section?["version"] is JsonValue version && version.TryGetValue<int>(out var number) ? number : 0;
        if (section?["steps"] is not JsonObject steps) { return; }
        foreach (var info in SetupSteps.All)
        {
            if (steps[info.Key] is not JsonObject entry) { continue; }
            var status = entry["status"] is JsonValue text && text.TryGetValue<string>(out var name)
                         && Enum.TryParse<SetupStatus>(name, true, out var parsed) ? parsed : SetupStatus.Pending;
            DateTimeOffset? at = entry["at"] is JsonValue when && when.TryGetValue<string>(out var stamp)
                                 && DateTimeOffset.TryParse(stamp, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var time)
                ? time : null;
            var detail = entry["detail"] is JsonValue note && note.TryGetValue<string>(out var message) ? message : null;
            states[info.Id] = new SetupStepState(info.Id, status, at, detail);
        }
    }

    public void Mark(SetupStepId id, SetupStatus status, string? detail = null)
    {
        var next = new SetupStepState(id, status, clock.GetUtcNow(), detail);
        var info = SetupSteps.Info(id);
        store.UpdateSetup(existing =>
        {
            var section = existing ?? [];
            // The version is stamped on first write; a later bump is acknowledged explicitly.
            if (section["version"] is not JsonValue) { section["version"] = SetupSteps.CurrentVersion; }
            var steps = section["steps"] as JsonObject ?? [];
            steps[info.Key] = new JsonObject
            {
                ["status"] = status.ToString().ToLowerInvariant(),
                ["at"] = next.At!.Value.ToString("O", CultureInfo.InvariantCulture),
                ["detail"] = detail
            };
            section["steps"] = steps;
            return section;
        });
        states[id] = next;
        hasStoredState = true;
        if (storedVersion == 0) { storedVersion = SetupSteps.CurrentVersion; }
    }

    /// Records that the user has seen the steps introduced up to the current version.
    public void AcknowledgeVersion()
    {
        if (storedVersion >= SetupSteps.CurrentVersion && hasStoredState) { return; }
        store.UpdateSetup(existing =>
        {
            var section = existing ?? [];
            section["version"] = SetupSteps.CurrentVersion;
            return section;
        });
        storedVersion = SetupSteps.CurrentVersion;
        hasStoredState = true;
    }

    public bool IsIncomplete(SetupStepId id)
    {
        var info = SetupSteps.Info(id);
        var status = Status(id);
        return info.Class == SetupStepClass.Required ? status != SetupStatus.Passed : status == SetupStatus.Failed;
    }

    /// Required steps not passed, plus any failed step: what the tray badge and "Finish Setup… (n left)" count.
    /// Pending or skipped Recommended steps ("Not tested") never raise it.
    public int AttentionCount => SetupSteps.All.Count(info => IsIncomplete(info.Id));

    public bool NeedsAttention => AttentionCount > 0;

    public SetupStepId? FirstIncompleteRequired =>
        SetupSteps.All.Where(info => info.Class == SetupStepClass.Required && Status(info.Id) != SetupStatus.Passed)
            .Select(info => (SetupStepId?)info.Id).FirstOrDefault();

    /// The first step to show on a launch-time reopen: an incomplete Required step, else a failed one.
    public SetupStepId? FirstStepNeedingAttention =>
        FirstIncompleteRequired ?? SetupSteps.All.Where(info => Status(info.Id) == SetupStatus.Failed)
            .Select(info => (SetupStepId?)info.Id).FirstOrDefault();

    /// Launch trigger: Velopack first run, no stored state, or an incomplete Required step.
    public bool ShouldOpenOnLaunch(bool isFirstRun) => isFirstRun || NeverRan || FirstIncompleteRequired is not null;

    /// The steps the window shows: everything on a first run or manual open, only new steps after a version bump.
    public IReadOnlyList<SetupStepInfo> StepsToShow(bool manualOpen)
    {
        if (manualOpen || NeverRan || storedVersion >= SetupSteps.CurrentVersion) { return SetupSteps.All; }
        return SetupSteps.All.Where(info => info.IntroducedIn > storedVersion || IsIncomplete(info.Id)).ToArray();
    }

    /// Flips passed checks that no longer hold. Nothing is revalidated before step 0 is answered.
    public IReadOnlyList<SetupStepId> Revalidate(RevalidationReport report)
    {
        var regressed = new List<SetupStepId>();
        if (!ConsentAnswered) { return regressed; }

        Apply(SetupStepId.NotesFolder, report.FolderWritable, "The notes folder can't be written to.", regressed);
        Apply(SetupStepId.Shortcuts, report.FailedShortcuts.Count == 0,
            report.FailedShortcuts.Count == 1 ? "1 keyboard shortcut couldn't be registered." : $"{report.FailedShortcuts.Count} keyboard shortcuts couldn't be registered.",
            regressed);
        Apply(SetupStepId.StartAtLogin, report.RunKeyPresent, "Start at login is no longer registered.", regressed);
        Apply(SetupStepId.Updates, report.UpdateChoicePresent ? true : Status(SetupStepId.Updates) == SetupStatus.Passed ? false : null,
            "The update choice is missing.", regressed);
        return regressed;
    }

    private void Apply(SetupStepId id, bool? holds, string failure, List<SetupStepId> regressed)
    {
        if (holds is null) { return; }
        var status = Status(id);
        if (holds == false && status == SetupStatus.Passed)
        {
            Mark(id, SetupStatus.Failed, failure);
            regressed.Add(id);
        }
        else if (holds == true && status == SetupStatus.Failed)
        {
            Mark(id, SetupStatus.Passed);
        }
    }
}
