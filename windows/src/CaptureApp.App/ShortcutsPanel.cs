using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using CaptureApp.AppCore.Shell;
using CaptureApp.Platform.Hotkeys;

namespace CaptureApp.App;

/// The shortcut list shared by Setup step 2 and Settings → Shortcuts: status per combo, rebinding, disabling.
internal sealed class ShortcutsPanel : StackPanel
{
    private static readonly (HotkeyAction Action, string Label)[] Rows =
    [
        (HotkeyAction.CaptureSelection, "Capture Selection"),
        (HotkeyAction.CaptureArea, "Capture Area"),
        (HotkeyAction.CaptureSelectionOutsideSession, "Capture Selection outside session"),
        (HotkeyAction.CaptureAreaOutsideSession, "Capture Area outside session"),
        (HotkeyAction.SearchNotes, "Search Notes"),
        (HotkeyAction.ToggleSession, "Start or End Session"),
        (HotkeyAction.WriteNote, "Quick Note"),
        (HotkeyAction.WriteNoteOutsideSession, "Quick Note outside session"),
        (HotkeyAction.AddSubheading, "Add Subheading"),
        (HotkeyAction.OpenNotesFolder, "Open Notes Folder")
    ];

    private readonly AppController controller;
    private readonly Action changed;
    private readonly Grid grid = new();
    private readonly TextBlock adjustments = UiKit.Secondary("");
    private readonly TextBlock message = UiKit.Secondary("");

    public ShortcutsPanel(AppController controller, Action changed)
    {
        this.controller = controller;
        this.changed = changed;
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.4, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.6, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.8, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Children.Add(grid);
        Children.Add(adjustments);
        Children.Add(message);
        Children.Add(UiKit.Row(
            UiKit.Button("Check again", () => { controller.RegisterHotkeys(); Refresh(); changed(); }),
            UiKit.Button("Reset to defaults", ResetToDefaults)));
        Refresh();
    }

    /// Every action is registered or explicitly disabled: the Required step 2 condition.
    public bool AllResolved => Rows.All(row => controller.Settings.DisabledShortcuts.Contains(row.Action.ToString())
                                               || !controller.ShortcutFailures.ContainsKey(row.Action) && controller.IsRegistered(row.Action));

    public void Refresh()
    {
        adjustments.Text = string.Join(Environment.NewLine, controller.BindingStore.Adjustments.Select(adjustment =>
            $"{Rows.First(row => row.Action == adjustment.Action).Label}: using {adjustment.Replacement.DisplayString} instead of {adjustment.PreviousChord.DisplayString}. {adjustment.Reason} Use Change… to choose another combination."));
        adjustments.Visibility = adjustments.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        grid.Children.Clear();
        grid.RowDefinitions.Clear();
        var disabled = controller.Settings.DisabledShortcuts;
        for (var i = 0; i < Rows.Length; i++)
        {
            var (action, label) = Rows[i];
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var isDisabled = disabled.Contains(action.ToString());
            string status;
            string brush = "Secondary";
            if (isDisabled) { status = "Turned off"; }
            else if (controller.ShortcutFailures.TryGetValue(action, out var failure))
            {
                status = failure.ValidationError ?? (failure.Win32Error == 1409 ? "Another app already uses this combination" : $"Couldn't register (error {failure.Win32Error})");
                brush = "Warning";
            }
            else { status = controller.IsRegistered(action) ? "Registered" : "Not registered yet"; }

            Place(UiKit.Text(label, 13, false, "TextPrimary", 0), i, 0);
            Place(UiKit.Text(isDisabled ? "—" : controller.BindingText(action), 13, true, "TextPrimary", 0), i, 1);
            Place(UiKit.Text(status, 12, false, brush, 0), i, 2);
            var buttons = UiKit.Row(UiKit.Button("Change…", () => Rebind(action, label)), UiKit.Button(isDisabled ? "Turn on" : "Turn off", () => Toggle(action, isDisabled)));
            buttons.Margin = new Thickness(0, 2, 0, 2);
            Place(buttons, i, 3);
        }
    }

    private void Place(UIElement element, int row, int column)
    {
        if (element is FrameworkElement frame) { frame.VerticalAlignment = VerticalAlignment.Center; frame.Margin = new Thickness(0, 4, 8, 4); }
        Grid.SetRow(element, row);
        Grid.SetColumn(element, column);
        grid.Children.Add(element);
    }

    private void Toggle(HotkeyAction action, bool wasDisabled)
    {
        if (wasDisabled && controller.ValidateBinding(action, controller.CurrentBinding(action)) is { } error)
        {
            message.Text = "Not enabled: " + error;
            return;
        }
        var set = controller.Settings.DisabledShortcuts.ToHashSet(StringComparer.Ordinal);
        if (wasDisabled) { set.Remove(action.ToString()); } else { set.Add(action.ToString()); }
        if (!controller.TrySave(() => controller.Settings.DisabledShortcuts = set)) { Refresh(); return; }
        controller.RegisterHotkeys();
        message.Text = "";
        Refresh();
        changed();
    }

    private void ResetToDefaults()
    {
        try
        {
            controller.ValidateFolderBindingsAgainstDefaults();
            controller.BindingStore.Save(HotkeyDefaults.All);
            controller.Settings.DisabledShortcuts = new HashSet<string>(StringComparer.Ordinal);
            controller.RegisterHotkeys();
            message.Text = "Shortcuts reset to the defaults.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            controller.ReportSaveFailure(error);
            message.Text = error is InvalidDataException ? error.Message : Strings.CouldNotSaveSettings;
        }
        Refresh();
        changed();
    }

    private void Rebind(HotkeyAction action, string label)
    {
        controller.PauseHotkeys();
        try
        {
            var recorder = new ChordRecorder(label, chord => controller.ValidateBinding(action, chord)) { Owner = Window.GetWindow(this) };
            if (recorder.ShowDialog() == true && recorder.Chord is { } chord)
            {
                var result = controller.TrySaveBinding(action, chord);
                message.Text = result.Succeeded ? $"{label} is now {chord.DisplayString}." : $"Not saved: {result.ValidationError ?? "another app already uses this combination."}";
            }
        }
        finally
        {
            controller.RegisterHotkeys();
        }

        Refresh();
        changed();
    }
}

/// Records one combination from the keyboard and validates it before it can be saved.
internal sealed class ChordRecorder : Window
{
    private readonly Func<KeyChord, string?> validate;
    private readonly TextBlock chordText = UiKit.Text("Press the new shortcut…", 18, true);
    private readonly TextBlock problem = UiKit.Text("", 12, false, "Warning");
    private readonly Button save;

    public KeyChord? Chord { get; private set; }

    public ChordRecorder(string label, Func<KeyChord, string?> validate)
    {
        this.validate = validate;
        Title = $"Change shortcut: {label}";
        Width = 420;
        Height = 230;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        UiKit.Themed(this);
        save = UiKit.Button("Save", () => DialogResult = true, true);
        save.IsEnabled = false;
        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(UiKit.Secondary("Hold the modifiers and press the key. Windows-key combinations and Ctrl+Alt without Shift aren't allowed."));
        panel.Children.Add(chordText);
        panel.Children.Add(problem);
        panel.Children.Add(UiKit.Row(save, UiKit.Button("Cancel", () => DialogResult = false)));
        Content = panel;
        PreviewKeyDown += OnKey;
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        e.Handled = true;
        if (e.IsRepeat) return;
        var key = e.Key switch { Key.System => e.SystemKey, Key.ImeProcessed => e.ImeProcessedKey, _ => e.Key };
        if (key == Key.Escape) { DialogResult = false; return; }
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin or Key.None) { return; }
        var modifiers = HotkeyModifiers.None;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { modifiers |= HotkeyModifiers.Control; }
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) { modifiers |= HotkeyModifiers.Alt; }
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { modifiers |= HotkeyModifiers.Shift; }
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows)) { modifiers |= HotkeyModifiers.Windows; }
        var virtualKey = KeyInterop.VirtualKeyFromKey(key);
        if (virtualKey is < 1 or > 0xFF) { return; }
        var chord = new KeyChord(modifiers, virtualKey);
        chordText.Text = chord.DisplayString;
        var error = validate(chord);
        problem.Text = error ?? "";
        Chord = error is null ? chord : null;
        save.IsEnabled = error is null;
    }
}
