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

    public static void WithHotkeysPaused(AppController controller, Action action)
    {
        controller.PauseHotkeys();
        try { action(); }
        finally { controller.RegisterHotkeys(); }
    }
}
