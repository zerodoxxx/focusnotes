namespace CaptureApp.AppCore.Shell;

/// A platform-neutral menu entry; the App maps it onto the Platform tray model.
public sealed record MenuEntry(string Id, string Title, string Shortcut = "", bool Enabled = true, bool Checked = false,
    IReadOnlyList<MenuEntry>? Children = null, bool IsSeparator = false)
{
    public static MenuEntry Separator { get; } = new(string.Empty, string.Empty, IsSeparator: true);
}

public static class MenuIds
{
    public const string FinishSetup = "finish-setup";
    public const string CaptureSelection = "capture-selection";
    public const string CaptureArea = "capture-area";
    public const string CaptureSelectionOutsideSession = "capture-selection-outside-session";
    public const string CaptureAreaOutsideSession = "capture-area-outside-session";
    public const string Search = "search";
    public const string Session = "session";
    public const string WriteNote = "write-note";
    public const string AddSubheading = "add-subheading";
    public const string ShortcutStatus = "shortcut-status";
    public const string RetryShortcuts = "retry-shortcuts";
    public const string OpenFolder = "open-folder";
    public const string Semantic = "semantic";
    public const string RemoveModels = "remove-models";
    public const string Setup = "setup";
    public const string Settings = "settings";
    public const string CheckUpdates = "check-updates";
    public const string RestartToUpdate = "restart-to-update";
    public const string UpdateFailed = "update-failed";
    public const string RetryUpdate = "retry-update";
    public const string DownloadInstaller = "download-installer";
    public const string Quit = "quit";
}

public enum SemanticMenuPhase { NotInstalled, Downloading, Removing, Installed }

public sealed record SemanticMenuState(SemanticMenuPhase Phase, bool HasPartialDownload = false, int? Percent = null);

public enum UpdateMenuKind { Hidden, Idle, Checking, Downloading, ReadyToRestart, Failed }

public sealed record UpdateMenuState(UpdateMenuKind Kind, string? Version = null);

/// Everything the menu depends on. Binding texts are the user's current shortcuts ("" when none).
public sealed record MenuState(
    bool ConsentAnswered,
    int SetupAttention,
    string? SessionName,
    IReadOnlyDictionary<string, string> Bindings,
    int FailedShortcuts,
    SemanticMenuState Semantic,
    UpdateMenuState Update);

/// Builds the tray menu in the Mac's order (AppController.swift:1165-1206, SemanticModelsMenu.swift:99-112), with
/// Permissions ▸ replaced by Setup… and Settings… added.
public static class TrayMenuBuilder
{
    public static IReadOnlyList<MenuEntry> Build(MenuState state)
    {
        var quit = new MenuEntry(MenuIds.Quit, Strings.MenuQuit);
        if (!state.ConsentAnswered)
        {
            // Until step 0 is answered nothing runs: only Finish Setup… and Quit.
            return [new(MenuIds.FinishSetup, Strings.MenuFinishSetup(Math.Max(1, state.SetupAttention))), quit];
        }

        var items = new List<MenuEntry>();
        if (state.SetupAttention > 0)
        {
            items.Add(new(MenuIds.FinishSetup, Strings.MenuFinishSetup(state.SetupAttention)));
            items.Add(MenuEntry.Separator);
        }

        items.Add(Command(state, MenuIds.CaptureSelection, Strings.MenuCaptureSelection));
        items.Add(Command(state, MenuIds.CaptureArea, Strings.MenuCaptureArea));
        items.Add(Command(state, MenuIds.CaptureSelectionOutsideSession, Strings.MenuCaptureSelectionOutsideSession));
        items.Add(Command(state, MenuIds.CaptureAreaOutsideSession, Strings.MenuCaptureAreaOutsideSession));
        items.Add(Command(state, MenuIds.Search, Strings.MenuSearch));
        items.Add(Command(state, MenuIds.Session, state.SessionName is { } name ? Strings.MenuEndSession(name) : Strings.MenuStartSession));
        items.Add(Command(state, MenuIds.WriteNote, Strings.MenuWriteNote));
        items.Add(Command(state, MenuIds.AddSubheading, Strings.MenuAddSubheading));
        if (state.FailedShortcuts > 0)
        {
            items.Add(new(MenuIds.ShortcutStatus, Strings.MenuShortcutsUnavailable(state.FailedShortcuts), Enabled: false));
            items.Add(new(MenuIds.RetryShortcuts, Strings.MenuRetryShortcuts));
        }

        items.Add(MenuEntry.Separator);
        items.Add(Command(state, MenuIds.OpenFolder, Strings.MenuOpenFolder));
        items.Add(Semantic(state.Semantic));
        items.Add(new(MenuIds.Setup, Strings.MenuSetup));
        items.Add(new(MenuIds.Settings, Strings.MenuSettings));
        items.AddRange(Update(state.Update));
        items.Add(MenuEntry.Separator);
        items.Add(quit);
        return items;
    }

    private static MenuEntry Command(MenuState state, string id, string title) =>
        new(id, title, state.Bindings.TryGetValue(id, out var binding) ? binding : "");

    private static MenuEntry Semantic(SemanticMenuState semantic) => semantic.Phase switch
    {
        SemanticMenuPhase.Installed => new(MenuIds.Semantic, Strings.MenuSemanticSearch, Checked: true,
            Children: [new(MenuIds.RemoveModels, Strings.MenuRemoveModels)]),
        SemanticMenuPhase.Removing => new(MenuIds.Semantic, Strings.MenuRemovingModels, Enabled: false),
        SemanticMenuPhase.Downloading => new(MenuIds.Semantic, Strings.MenuDownloadingModels(semantic.Percent)),
        _ => new(MenuIds.Semantic, semantic.HasPartialDownload ? Strings.MenuResumeSemantic : Strings.MenuEnableSemantic)
    };

    private static IEnumerable<MenuEntry> Update(UpdateMenuState update)
    {
        switch (update.Kind)
        {
            case UpdateMenuKind.Hidden:
                yield break;
            case UpdateMenuKind.Checking:
                yield return new(MenuIds.CheckUpdates, Strings.MenuCheckingUpdates, Enabled: false);
                break;
            case UpdateMenuKind.Downloading:
                yield return new(MenuIds.CheckUpdates, Strings.MenuDownloadingUpdate(update.Version), Enabled: false);
                break;
            case UpdateMenuKind.ReadyToRestart:
                yield return new(MenuIds.RestartToUpdate, Strings.MenuRestartToUpdate(update.Version));
                break;
            case UpdateMenuKind.Failed:
                yield return new(MenuIds.UpdateFailed, Strings.MenuUpdateFailed, Children:
                [
                    new(MenuIds.RetryUpdate, Strings.MenuRetryUpdate),
                    new(MenuIds.DownloadInstaller, Strings.MenuDownloadInstaller)
                ]);
                break;
            default:
                yield return new(MenuIds.CheckUpdates, Strings.MenuCheckUpdates);
                break;
        }
    }
}
