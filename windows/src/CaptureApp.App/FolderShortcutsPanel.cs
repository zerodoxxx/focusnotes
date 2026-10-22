using System.Windows;
using System.Windows.Controls;
using CaptureApp.Platform.Hotkeys;

namespace CaptureApp.App;

/// The same custom shortcut editor is available in Settings and Setup.
internal sealed class FolderShortcutsPanel : StackPanel
{
    private sealed class Row
    {
        internal Guid Id = Guid.NewGuid();
        internal KeyChord? Chord;
        internal ComboBox Action = new() { Width = 125, ItemsSource = new[] { "Quick Note", "Start Session" }, SelectedIndex = 0 };
        internal TextBox Folder = new() { MinWidth = 160, Width = 180, Margin = new Thickness(8, 0, 8, 0) };
        internal Button Record = UiKit.Button("Record…", () => { });
        internal StackPanel View = new();
    }

    private readonly AppController controller;
    private readonly StackPanel list = new();
    private readonly List<Row> rows = [];
    private readonly TextBlock message = UiKit.Text("", 12, false, "Warning");
    private readonly Button add;
    private IReadOnlyList<FolderShortcutBinding> original = [];

    public FolderShortcutsPanel(AppController controller)
    {
        this.controller = controller;
        Children.Add(UiKit.Text("Folder Shortcuts", 16, true));
        Children.Add(UiKit.Secondary("Quick notes use a folder inside your notes folder. Start Session asks for a name, then creates or resumes a session inside Sessions/<folder>. Enter a relative path such as Work/Research. Choosing an existing note in Browse overrides the folder."));
        Children.Add(list);
        add = UiKit.Button("Add Shortcut", () => { if (rows.Count < FolderShortcutStore.MaximumBindings) { AddRow(); UpdateCount(); } });
        Children.Add(UiKit.Row(add, UiKit.Button("Save Folder Shortcuts", Save), UiKit.Button("Revert Changes", Reload)));
        Children.Add(message);
        Reload();
    }

    private void Reload()
    {
        rows.Clear();
        list.Children.Clear();
        foreach (var binding in controller.FolderBindings) AddRow(binding);
        original = controller.FolderBindings.ToArray();
        message.Text = controller.FolderBindingsLoadError is { } error ? "Could not read existing folder shortcuts: " + error : "";
        UpdateCount();
    }

    private void UpdateCount()
    {
        add.Content = $"Add Shortcut ({rows.Count}/{FolderShortcutStore.MaximumBindings})";
        add.IsEnabled = rows.Count < FolderShortcutStore.MaximumBindings;
    }

    private void AddRow(FolderShortcutBinding? binding = null)
    {
        var row = new Row();
        if (binding is not null)
        {
            row.Id = binding.Id;
            row.Chord = binding.Shortcut;
            row.Action.SelectedIndex = binding.Action == FolderShortcutAction.StartSession ? 1 : 0;
            row.Folder.Text = binding.Folder;
            row.Record.Content = binding.Shortcut.DisplayString;
        }
        row.Folder.ToolTip = "Relative destination folder";
        System.Windows.Automation.AutomationProperties.SetName(row.Folder, "Destination folder");
        row.Record.Click += (_, _) => Record(row);
        var delete = UiKit.Button("Delete", () => { rows.Remove(row); list.Children.Remove(row.View); UpdateCount(); });
        row.View.Margin = new Thickness(0, 6, 0, 6);
        row.View.Children.Add(UiKit.Row(row.Action, row.Folder, row.Record, delete));
        if (binding is not null && controller.FolderShortcutFailures.TryGetValue(binding.Id, out var failure))
            row.View.Children.Add(UiKit.Text(failure.ValidationError ?? $"Unavailable (Windows error {failure.Win32Error}). Release it in the other app and check again.", 12, false, "Warning"));
        list.Children.Add(row.View);
        rows.Add(row);
    }

    private IEnumerable<FolderShortcutBinding> Proposed() => rows.Where(row => row.Chord is not null)
        .Select(row => new FolderShortcutBinding(row.Id, row.Chord!.Value,
            row.Action.SelectedIndex == 1 ? FolderShortcutAction.StartSession : FolderShortcutAction.QuickNote, row.Folder.Text));

    private void Record(Row row)
    {
        controller.PauseHotkeys();
        try
        {
            var recorder = new ChordRecorder("Folder Shortcut", chord => controller.ValidateFolderChord(row.Id, chord, Proposed())) { Owner = Window.GetWindow(this) };
            if (recorder.ShowDialog() == true && recorder.Chord is { } chord)
            {
                row.Chord = chord;
                row.Record.Content = chord.DisplayString;
                message.Text = "Save Folder Shortcuts to apply this change.";
            }
        }
        finally { controller.RegisterHotkeys(); }
    }

    private void Save()
    {
        if (!original.SequenceEqual(controller.FolderBindings))
        {
            message.Text = "Folder shortcuts changed in another window. Revert Changes to load them before editing again.";
            return;
        }
        if (rows.Any(row => row.Chord is null)) { message.Text = "Record every shortcut, or delete unused rows."; return; }
        try { controller.SaveFolderBindings(Proposed().ToArray()); Reload(); message.Text = "Folder shortcuts saved."; }
        catch (Exception error) { message.Text = "Not saved: " + error.Message; }
    }
}
