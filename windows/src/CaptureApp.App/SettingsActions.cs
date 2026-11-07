using System.Windows.Controls;
using CaptureApp.AppCore.Shell;

namespace CaptureApp.App;

/// Settings policy shared by the Setup and Settings windows and the shortcut panels.
internal static class SettingsActions
{
    public const string UpdatesAutoLabel = "Check for updates automatically (daily)";
    public const string UpdatesManualLabel = "Only when I ask";

    /// Shows the update choice that is actually saved, e.g. after a failed save.
    public static void ShowSavedUpdatesChoice(AppController controller, RadioButton auto, RadioButton manual)
    {
        auto.IsChecked = controller.Settings.UpdatesChoice != UpdatesChoice.Manual;
        manual.IsChecked = controller.Settings.UpdatesChoice == UpdatesChoice.Manual;
    }

    /// The update choice radio pair. With autoWhenUnset false, an unset choice leaves both unchecked.
    public static (RadioButton Auto, RadioButton Manual) UpdatesRadios(AppController controller, string group, bool autoWhenUnset)
    {
        var choice = controller.Settings.UpdatesChoice;
        var auto = UiKit.Radio(UpdatesAutoLabel, group, autoWhenUnset ? choice != UpdatesChoice.Manual : choice == UpdatesChoice.Auto);
        return (auto, UiKit.Radio(UpdatesManualLabel, group, choice == UpdatesChoice.Manual));
    }

    public static UpdatesChoice SelectedUpdatesChoice(RadioButton auto) => auto.IsChecked == true ? UpdatesChoice.Auto : UpdatesChoice.Manual;

    public static void WithHotkeysPaused(AppController controller, Action action)
    {
        controller.PauseHotkeys();
        try { action(); }
        finally { controller.RegisterHotkeys(); }
    }
}
