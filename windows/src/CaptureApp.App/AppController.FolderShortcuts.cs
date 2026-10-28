using System.IO;
using CaptureApp.AppCore.Shell;
using CaptureApp.Platform.Hotkeys;
using CaptureApp.Platform.Tray;

namespace CaptureApp.App;

internal sealed partial class AppController
{
    private IReadOnlyList<FolderShortcutBinding> folderBindings = [];
    private readonly Dictionary<Guid, HotkeyRegistrationResult> folderFailures = [];
    private string? folderBindingsLoadError;
    internal IReadOnlyList<FolderShortcutBinding> FolderBindings => folderBindings;
    internal IReadOnlyDictionary<Guid, HotkeyRegistrationResult> FolderShortcutFailures => folderFailures;
    internal string? FolderBindingsLoadError => folderBindingsLoadError;
    private FolderShortcutStore FolderBindingStore => new(Path.Combine(pipeline.StateDirectory, "folder-shortcuts.json"));
    internal KeyChord CurrentBinding(HotkeyAction action) => Bindings[action];
    internal void ValidateFolderBindingsAgainstDefaults() => FolderShortcutStore.Validate(folderBindings, HotkeyDefaults.All);

    private void LoadFolderBindings()
    {
        try { folderBindings = FolderBindingStore.Load(); folderBindingsLoadError = null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            folderBindingsLoadError = error.Message;
            log.Error($"Folder shortcuts could not be loaded: {error.Message}");
        }
    }

    private void RegisterFolderBindings()
    {
        folderFailures.Clear();
        foreach (var binding in folderBindings)
        {
            if (ValidateFolderChord(binding.Id, binding.Shortcut) is { } reason)
            {
                folderFailures[binding.Id] = new(null, binding.Shortcut, false, 87, reason);
                continue;
            }
            var result = hotkeys!.Register(binding.Id, binding.Shortcut,
                () => dispatcher.BeginInvoke(() => RunFolderShortcut(binding)));
            if (!result.Succeeded) { folderFailures[binding.Id] = result; }
        }
    }

    internal string? ValidateFolderChord(Guid id, KeyChord chord, IEnumerable<FolderShortcutBinding>? proposed = null)
    {
        var validation = HotkeyValidator.Validate(chord);
        if (!validation.IsValid) { return validation.Error; }
        if (!AltGrGuard.IsSafe(chord)) { return "This combination types a letter on an installed keyboard layout (AltGr)."; }
        if (Bindings.Any(pair => pair.Value == chord && !Settings.DisabledShortcuts.Contains(pair.Key.ToString())))
            return "This combination is already used by a built-in shortcut.";
        if ((proposed ?? folderBindings).Any(binding => binding.Id != id && binding.Shortcut == chord))
            return "This combination is already used by another folder shortcut.";
        return null;
    }

    internal void SaveFolderBindings(IReadOnlyList<FolderShortcutBinding> proposed)
    {
        if (folderBindingsLoadError is not null) { throw new InvalidDataException("Existing folder shortcuts could not be read. Repair the settings file before replacing them."); }
        FolderShortcutStore.Validate(proposed, Bindings, Settings.DisabledShortcuts);
        var previous = folderBindings;
        hotkeys ??= new HotkeyRegistrar();
        hotkeys.UnregisterAll();
        try
        {
            foreach (var binding in proposed)
            {
                if (ValidateFolderChord(binding.Id, binding.Shortcut, proposed) is { } reason) throw new InvalidDataException(reason);
                var result = hotkeys.Register(binding.Id, binding.Shortcut, () => { });
                if (!result.Succeeded) throw new InvalidDataException(result.ValidationError ?? $"{binding.Shortcut.DisplayString} is unavailable (Windows error {result.Win32Error}).");
            }
            FolderBindingStore.Save(proposed);
            folderBindings = proposed.ToArray();
        }
        catch { folderBindings = previous; throw; }
        finally { RegisterHotkeys(); }
    }

    private void RunFolderShortcut(FolderShortcutBinding binding)
    {
        if (quitting || !RequireConsent()) return;
        if (binding.Action == FolderShortcutAction.QuickNote) { OpenNoteEditor(binding.Folder); return; }
        Coordinator.Enqueue(async c =>
        {
            await c.WaitForAcquisitionAsync();
            _ = c.CommitPending();
            await c.WaitForProcessingAsync();
            _ = c.CommitPending();
            if (!await ClosePanelsAsync()) return;
            await c.WaitForCommitsAsync();
            if (c.IsTerminating) return;
            await PresentFolderSessionInputAsync(binding.Folder);
        });
    }

    internal async Task PresentFolderSessionInputAsync(string folder)
    {
        var suggestions = await Coordinator.FolderSessionSuggestionsAsync(folder);
        if (quitting || Coordinator.IsTerminating) return;
        // Opaque values distinguish selected rows from typed names, even when a header differs from its filename.
        var selectedValues = suggestions.ToDictionary(s => s.Path, _ => "folder-session:" + Guid.NewGuid().ToString("N"));
        var candidates = suggestions.ToDictionary(s => selectedValues[s.Path], s =>
            new CaptureApp.Core.SessionCandidate(s.Title, s.Path, s.Modified));
        PresentInput(Strings.SessionNamePlaceholder, title: "Start Session", secondary: "In Sessions/" + folder,
            suggestions: suggestions, suggestionValue: suggestion => selectedValues[suggestion.Path],
            onSubmit: name => Coordinator.Enqueue(async c =>
            {
                if (string.IsNullOrWhiteSpace(name) || c.IsTerminating) return;
                await c.WaitForAcquisitionAsync();
                _ = c.CommitPending();
                await c.WaitForProcessingAsync();
                _ = c.CommitPending();
                await c.WaitForCommitsAsync();
                if (c.IsTerminating) return;
                try
                {
                    if (candidates.TryGetValue(name, out var selected)) await c.ResumeSessionAsync(selected);
                    else await c.StartFolderSessionAsync(folder, name);
                }
                catch (CaptureApp.Core.SessionStoreException ambiguous) when (ambiguous.Kind == CaptureApp.Core.SessionStoreError.Ambiguous)
                {
                    PresentSessionCandidates(ambiguous.Candidates);
                }
                catch (Exception error) { c.Report(error, Strings.CouldNotStartSession); }
            }));
    }

    private TrayMenuItem FolderShortcutsMenu()
    {
        var children = new List<TrayMenuItem> { new("folder-shortcuts.settings", "Configure Folder Shortcuts…") };
        children.AddRange(folderBindings.Select(binding => new TrayMenuItem("folder-shortcuts." + binding.Id,
            (binding.Action == FolderShortcutAction.QuickNote ? "Quick Note → " : "Start Session → Sessions/") + binding.Folder,
            folderFailures.ContainsKey(binding.Id) ? "" : binding.Shortcut.DisplayString)));
        return new("folder-shortcuts", "Folder Shortcuts", Children: children);
    }
}
