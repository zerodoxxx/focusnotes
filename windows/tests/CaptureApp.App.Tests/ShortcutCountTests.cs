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
}
