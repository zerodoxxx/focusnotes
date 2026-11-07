using System.IO;
using System.Windows;
using CaptureApp.AppCore.Shell;
using CaptureApp.Platform.Hotkeys;
using Xunit;

namespace CaptureApp.App.Tests;

public sealed class ShortcutCountTests
{
    [Fact]
    public void RegisteredShortcutCountTracksEveryHotkeyAction()
    {
        Assert.Equal(HotkeyDefaults.All.Count, Enum.GetValues<HotkeyAction>().Length);
        Assert.Equal(HotkeyDefaults.All.Count, AppController.RegisteredShortcutCount(0, 0));
        Assert.Equal(HotkeyDefaults.All.Count - 5, AppController.RegisteredShortcutCount(2, 3));
    }

    // Runs on SetupWindowTests' STA/Application: WPF permits one Application per process.
    internal static void CapabilityTableKeepsShortcutsOnWhileSomeStayEnabled(Application app)
    {
        var directory = Path.Combine(Path.GetTempPath(), "shortcut-count-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var controller = new AppController(app, directory, firstRun: false);
            controller.Setup.Mark(SetupStepId.Disclosure, SetupStatus.Passed);
            // Seven was the old hard-coded table size: turning off seven actions must leave the rest on.
            controller.Settings.DisabledShortcuts = Enum.GetValues<HotkeyAction>().Take(7)
                .Select(action => action.ToString()).ToHashSet(StringComparer.Ordinal);
            Assert.True(HotkeyDefaults.All.Count > 7);
            var shortcuts = Capabilities.Of(controller.CapabilityTable(), CapabilityId.Shortcuts);
            Assert.Equal(CapabilityState.Available, shortcuts.State);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
