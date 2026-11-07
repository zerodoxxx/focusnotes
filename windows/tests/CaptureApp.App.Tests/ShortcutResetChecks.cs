using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using CaptureApp.App;
using Xunit;

namespace CaptureApp.App.Tests;

// Runs on SetupWindowTests' STA/Application: WPF permits one Application per process.
internal static class ShortcutResetChecks
{
    internal static void ResetReportsUnreadableShortcutData(Application app)
    {
        var directory = Path.Combine(Path.GetTempPath(), "shortcut-reset-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var controller = new AppController(app, directory, firstRun: false);
            var panel = new ShortcutsPanel(controller, () => { });
            const string unreadable = "{\"shortcuts\":\"not an object\"}";
            File.WriteAllText(controller.SettingsPath, unreadable);

            var reset = Descendants(panel).OfType<Button>().Single(button => Equals(button.Content, "Reset to defaults"));
            reset.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

            Assert.Contains("The settings shortcuts value must be a JSON object.",
                Descendants(panel).OfType<TextBlock>().Select(block => block.Text));
            Assert.Equal(unreadable, File.ReadAllText(controller.SettingsPath));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            foreach (var descendant in Descendants(child)) { yield return descendant; }
        }
    }
}
