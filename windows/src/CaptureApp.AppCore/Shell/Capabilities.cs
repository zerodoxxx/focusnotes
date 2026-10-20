namespace CaptureApp.AppCore.Shell;

public enum CapabilityId { Shortcuts, SelectionCapture, ClipboardFallback, AreaCapture, NotesFolder, StartAtLogin, Updates }

public enum CapabilityState { Available, Unavailable, Off }

public sealed record CapabilityStatus(CapabilityId Id, CapabilityState State, string? Reason = null)
{
    public bool IsAvailable => State == CapabilityState.Available;
}

/// What the table needs from the running app (§5 "Skipped or unavailable capabilities").
public sealed record CapabilityInputs(
    bool ConsentAnswered,
    int RegisteredShortcuts,
    int FailedShortcuts,
    int DisabledShortcuts,
    bool? ClipboardFallback,
    bool? FolderWritable,
    bool? OcrAvailable,
    bool? StartAtLoginChosen,
    bool RunKeyPresent,
    bool UpdatesServiceEnabled,
    UpdatesChoice? UpdatesChoice);

public static class Capabilities
{
    public const string FinishSetupReason = "Setup isn't finished yet";

    public static IReadOnlyList<CapabilityStatus> Evaluate(CapabilityInputs input)
    {
        var shortcuts = !input.ConsentAnswered
            ? new CapabilityStatus(CapabilityId.Shortcuts, CapabilityState.Unavailable, FinishSetupReason)
            : input.FailedShortcuts > 0
                ? new CapabilityStatus(CapabilityId.Shortcuts, CapabilityState.Unavailable, Strings.MenuShortcutsUnavailable(input.FailedShortcuts))
                : input.RegisteredShortcuts == 0 && input.DisabledShortcuts > 0
                    ? new CapabilityStatus(CapabilityId.Shortcuts, CapabilityState.Off, "You turned the shortcuts off")
                    : new CapabilityStatus(CapabilityId.Shortcuts, CapabilityState.Available);

        var selection = input.ConsentAnswered
            ? new CapabilityStatus(CapabilityId.SelectionCapture, CapabilityState.Available)
            : new CapabilityStatus(CapabilityId.SelectionCapture, CapabilityState.Unavailable, FinishSetupReason);

        var fallback = !input.ConsentAnswered || input.ClipboardFallback is null
            ? new CapabilityStatus(CapabilityId.ClipboardFallback, CapabilityState.Unavailable, FinishSetupReason)
            : input.ClipboardFallback == true
                ? new CapabilityStatus(CapabilityId.ClipboardFallback, CapabilityState.Available)
                : new CapabilityStatus(CapabilityId.ClipboardFallback, CapabilityState.Off, "You turned the clipboard fallback off");

        var area = input.ConsentAnswered
            ? new CapabilityStatus(CapabilityId.AreaCapture, CapabilityState.Available)
            : new CapabilityStatus(CapabilityId.AreaCapture, CapabilityState.Unavailable, FinishSetupReason);

        var folder = input.FolderWritable == false
            ? new CapabilityStatus(CapabilityId.NotesFolder, CapabilityState.Unavailable,
                "The notes folder can't be written to; captures are kept safely until it works again")
            : new CapabilityStatus(CapabilityId.NotesFolder, CapabilityState.Available);

        var login = input.StartAtLoginChosen == false
            ? new CapabilityStatus(CapabilityId.StartAtLogin, CapabilityState.Off, "You turned start at login off")
            : input.StartAtLoginChosen == true && !input.RunKeyPresent
                ? new CapabilityStatus(CapabilityId.StartAtLogin, CapabilityState.Unavailable, "Start at login is no longer registered")
                : new CapabilityStatus(CapabilityId.StartAtLogin, CapabilityState.Available);

        var updates = !input.UpdatesServiceEnabled
            ? new CapabilityStatus(CapabilityId.Updates, CapabilityState.Unavailable, "Updates aren't available in this install")
            : input.UpdatesChoice == UpdatesChoice.Manual
                ? new CapabilityStatus(CapabilityId.Updates, CapabilityState.Off, "Updates are checked only when you ask")
                : new CapabilityStatus(CapabilityId.Updates, CapabilityState.Available);

        return [shortcuts, selection, fallback, area, folder, login, updates];
    }

    public static CapabilityStatus Of(IReadOnlyList<CapabilityStatus> table, CapabilityId id) => table.Single(status => status.Id == id);
}
