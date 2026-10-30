using System.Globalization;
using CaptureApp.Core;

namespace CaptureApp.AppCore.Shell;

/// The user-visible string table. Wording is the Mac's (AppController.swift, SemanticModelsMenu.swift) with the
/// DV9 maps applied: "tray icon → Setup" for the menu bar Permissions, Ctrl for ⌘, "File Explorer" for "Finder",
/// and the user's current binding in place of the Mac's ⌥⇧ hints. Platform refusals live in PlatformStrings.
public static class Strings
{
    // Capture and save feedback.
    public const string ShortcutsUnavailableTitle = "Some keyboard shortcuts are unavailable";
    public const string ShortcutsUnavailableSubtitle = "Use the tray icon commands, then choose Retry Shortcuts, or change them in Settings";
    public const string SetupNeedsAttentionTitle = "Setup needs attention";
    public const string OpenTraySetup = "Open the tray icon → Setup";
    public const string FinishSetupToCaptureTitle = "Finish Setup to capture";
    public const string CapturePausedTitle = "Capturing is paused";
    public const string NotesFolderUnavailableTitle = "Notes folder unavailable";
    public const string NoTextSelectedTitle = "No text selected";
    public const string CouldNotCaptureArea = "Couldn't capture area";
    public const string CouldNotJournal = "Couldn't journal capture";
    public const string CouldNotSaveCapture = "Couldn't save capture";
    public const string CouldNotSaveToNote = "Couldn't save to that note";
    public const string CouldNotSavePreviousCapture = "Couldn't save the previous capture";
    public const string PreviousCaptureNotSaved = "Couldn't save the previous capture · recovery will retry";
    public const string ChooseWhereToSave = "Choose where to save";
    public const string CouldNotAddNote = "Couldn't add note; draft kept";
    public const string CouldNotResetDraftPin = "Couldn't reset draft pin";
    public const string CouldNotSelectNote = "Couldn't select note";
    public const string CouldNotOpenNote = "Couldn't open note";
    public const string CouldNotRevealNote = "Couldn't reveal note";
    public const string CouldNotUpdatePinned = "Couldn't update Pinned";
    public const string CouldNotKeepDraft = "Couldn't keep draft; editor stays open";
    public const string CouldNotRestoreDraft = "Couldn't restore draft";
    public const string CouldNotResolveDestination = "Couldn't resolve note destination";
    public const string CouldNotAddSubheading = "Couldn't add subheading";
    public const string CouldNotStartSession = "Couldn't start session";
    public const string CouldNotEndSession = "Couldn't end session";
    public const string CouldNotResumeSession = "Couldn't resume session";
    public const string CouldNotCopyCapture = "Couldn't copy capture";
    public const string CouldNotSaveSettings = "Couldn't save settings";
    public const string CouldNotSaveSettingsHint = "Close other apps using settings.json and try again.";
    public const string CouldNotOpenFolder = "Couldn't open the notes folder";
    public const string NothingToOpen = "Nothing to open yet";
    public const string WriteSomethingFirst = "Write something first";
    public const string SubheadingAdded = "Subheading added";
    public const string Copied = "Copied";
    public const string SearchFailed = "Search failed. Try again.";
    public const string SemanticReady = "Semantic search is ready";
    public const string CouldNotDownloadModels = "Couldn't download semantic search models";
    public const string CouldNotRemoveModels = "Couldn't remove semantic search models";
    public const string UpdateCheckFailed = "Update check failed";
    public const string UpToDate = "You're up to date";

    // Panels.
    public const string AddToNotePlaceholder = "Add to note…";
    public const string ChooseNoteHint = "choose note";
    public const string SessionNamePlaceholder = "Session name";
    public const string SelectSessionPlaceholder = "Select a session…";
    public const string MultipleSessionsTitle = "Multiple sessions found with the given name";
    public const string SessionPickerHint = "Enter resumes · Ctrl+Enter renames";
    public const string RenameSessionTitle = "Rename and resume session";
    public const string RenameSessionHint = "Enter renames and resumes · Esc returns to sessions";
    public const string RenameSessionFailureHint = "Check the name and file access. Existing files are kept.";
    public const string RenameSessionNameInUseHint = "A session with that name already exists. Choose a different name.";
    public const string RenameSessionCaseOnlyHint = "Choose a name that changes more than letter casing.";
    public const string RenameSessionInvalidNameHint = "Enter a valid session name without folder separators.";
    public const string RenameSessionMissingHint = "This session no longer exists. Choose another session.";
    public const string RenameSessionChangedHint = "This session changed. Select it again before renaming.";
    public const string CouldNotRenameSession = "Couldn't rename session";
    public const string SubheadingPlaceholder = "Subheading";
    public const string AddSubheadingTitle = "Add subheading";
    public const string RecentSection = "Recent";
    public const string ResultsSection = "Results";

    public static string RenameSessionErrorHint(Exception error) => error switch
    {
        SessionStoreException { Kind: SessionStoreError.NameAlreadyExists } => RenameSessionNameInUseHint,
        SessionStoreException { Kind: SessionStoreError.CaseOnlyRename } => RenameSessionCaseOnlyHint,
        SessionStoreException { Kind: SessionStoreError.CandidateNoLongerExists } or FileNotFoundException => RenameSessionMissingHint,
        NotePathNameException or VaultFileException { Kind: VaultFileError.InvalidFileName } => RenameSessionInvalidNameHint,
        VaultFileException { Kind: VaultFileError.Changed } => RenameSessionChangedHint,
        _ => RenameSessionFailureHint
    };

    public static string NoTextSelectedSubtitle(string areaBinding) => $"Select text first, or use {areaBinding} for an area";

    public static string SavedTo(string title) => $"Saved to {title}";
    public static string AddedTo(string name) => $"Added to {name}";
    public static string SessionStillActive(string message, string? sessionName) => sessionName is null ? message : $"{message} · {sessionName} still active";
    public static string InNote(string title) => $"In {title}";
    public static string CaptureKept(string binding) => $"Capture kept · press {binding} to choose again";
    public static string SeveralNotesTitled(string title) => $"Several notes are titled \"{title}\"";
    public static string CaptureKeptPickByPath(string binding) => $"Capture kept · press {binding}, then pick one by its path";
    public static string PreviousCaptureSaved(string? title) => title is null ? "Previous capture saved" : $"Previous capture saved to {title}";
    public static string RecoveryWillRetry(string? title) => title is null ? "Recovery will retry the staged capture." : $"Recovery will retry: {title}.";
    public static string SessionStarted(string name, bool resumed) => $"Session {(resumed ? "resumed" : "started")} · {name}";
    public static string SessionCapturesGoHere(string binding) => $"Captures go here until {binding}";
    public static string SessionEnded(string name) => $"Session ended · {name}";
    public static string CaptureCount(int count) => count == 1 ? "1 capture" : $"{count} captures";
    public static string NoteCreatedOrAdded(bool created) => created ? "Note created" : "Note added";
    public const string NoteNotPinned = "Note saved, but not pinned";

    /// Subtitle for a session candidate in the picker.
    public static string CandidateSecondary(DateTimeOffset modified, string path, TimeZoneInfo zone) =>
        $"Modified {Stamp(modified, "MMM d, yyyy", zone)} · {path}";

    /// <param name="explicitPath">The path a nested, HOME or same-titled note is picked by; shown so those notes can be told apart.</param>
    public static string SuggestionDetail(bool session, DateTimeOffset modified, string path, TimeZoneInfo zone, string? explicitPath = null)
    {
        var detail = $"{(session ? "Session" : "Note")} · {Stamp(modified, "MMM d, yyyy", zone)}";
        return session ? $"{detail} · {path}" : explicitPath is null ? detail : $"{detail} · {explicitPath}";
    }

    public static string BrowseDetail(bool session, DateTimeOffset modified, TimeZoneInfo zone) =>
        $"{(session ? "Session" : "Note")} · {Stamp(modified, "MMM d", zone)}";

    public static string Stamp(DateTimeOffset date, string pattern, TimeZoneInfo zone) =>
        CaptureFormat.LocalStamp(date, pattern, zone);

    // External-note registry problems (AppController.reportExternalRegistryProblem).
    public static (string Title, string Subtitle) ExternalRegistry(ExternalNoteRegistryError? kind, int? version, bool forSave)
    {
        var title = forSave ? "Couldn't save external note" : "External notes unavailable";
        var subtitle = kind switch
        {
            ExternalNoteRegistryError.MalformedRegistry => forSave
                ? "The registry is damaged. Its existing entries were preserved; this note was not saved."
                : "The registry is damaged. Existing entries were preserved; external saves are paused. Vault notes still work.",
            ExternalNoteRegistryError.UnsupportedVersion => forSave
                ? $"The registry uses version {version?.ToString(CultureInfo.InvariantCulture)}. Its entries were preserved; this note was not saved."
                : $"The registry uses version {version?.ToString(CultureInfo.InvariantCulture)}. Existing entries were preserved; update this app. Vault notes still work.",
            ExternalNoteRegistryError.UnreadableRegistry => forSave
                ? "The registry could not be read safely. Its entries were preserved; this note was not saved."
                : "The registry could not be read safely. Existing entries were preserved; external notes are unavailable. Vault notes still work.",
            _ => forSave
                ? "The registry could not be read; its contents were left unchanged and this note was not saved."
                : "The registry could not be read. External notes are unavailable; vault notes still work."
        };
        return (title, subtitle);
    }

    // Tray menu.
    public const string MenuCaptureSelection = "Capture Selection";
    public const string MenuCaptureArea = "Capture Area";
    public const string MenuCaptureSelectionOutsideSession = "Capture Selection Outside Session…";
    public const string MenuCaptureAreaOutsideSession = "Capture Area Outside Session…";
    public const string MenuSearch = "Search Notes…";
    public const string MenuStartSession = "Start Session…";
    public const string MenuWriteNote = "Quick-note";
    public const string MenuWriteNoteOutsideSession = "Quick-note Outside Session";
    public const string MenuAddSubheading = "Add Subheading…";
    public const string MenuRetryShortcuts = "Retry Shortcuts";
    public const string MenuOpenFolder = "Open Notes Folder";
    public const string MenuChooseFolder = "Choose Notes Folder…";
    public const string MenuSetup = "Setup…";
    public const string MenuSettings = "Settings…";
    public const string MenuCheckUpdates = "Check for Updates…";
    public const string MenuCheckingUpdates = "Checking for Updates…";
    public const string MenuUpdateFailed = "Update failed";
    public const string MenuRetryUpdate = "Retry";
    public const string MenuDownloadInstaller = "Download installer";
    public const string MenuRemoveModels = "Remove Models…";
    public static string MenuQuit => $"Quit {AppInfo.Name}";
    public static string MenuEndSession(string name) => $"End Session “{name}”";
    public static string MenuFinishSetup(int remaining) => $"Finish Setup… ({remaining} left)";
    public static string MenuShortcutsUnavailable(int count) => count == 1 ? "1 keyboard shortcut unavailable" : $"{count} keyboard shortcuts unavailable";
    public static string MenuDownloadingUpdate(string? version) => version is null ? "Downloading Update…" : $"Downloading Update (v{version})…";
    public static string MenuRestartToUpdate(string? version) => $"Restart to Update (v{version})";
    public static string MenuDownloadingModels(int? percent) => percent is { } value ? $"Downloading Models… {value}%" : "Downloading Models…";
    public const string MenuRemovingModels = "Removing Models…";
    public const string MenuSemanticSearch = "Semantic Search";
    public const string MenuResumeSemantic = "Resume Semantic Search…";
    public const string MenuEnableSemantic = "Enable Semantic Search…";

    // Semantic-search dialogs. Windows downloads only the models (A3), so the runtime archive is not mentioned.
    public const string RemoveModelsTitle = "Remove semantic search models?";
    public const string CancelDownloadTitle = "Cancel the download?";
    public const string CancelDownloadBody = "Downloaded data is kept, so the next download resumes where it stopped.";
    public const string KeepDownloading = "Keep Downloading";
    public const string CancelDownload = "Cancel Download";
    public static string RemoveModelsBody(string size) =>
        $"This frees about {size}. Keyword search keeps working, and you can download the models again later.";
    public static string DownloadModelsTitle(bool resuming) =>
        resuming ? "Resume the semantic search model download?" : "Download semantic search models?";
    public static string DownloadModelsBody(string size) =>
        $"{AppInfo.Name} will download about {size} from huggingface.co: the EmbeddingGemma model (Apache-2.0). Each file is checked against a pinned SHA-256 hash before use. Your notes never leave your computer, and you can remove the models at any time.";

    // Tray tooltip and badge.
    public static string TrayTooltip => AppInfo.Name;
}
