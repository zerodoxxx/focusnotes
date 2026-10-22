using System;
using System.IO;
using CaptureApp.Platform.Tray;
using Xunit;

namespace CaptureApp.Platform.Tests.Tray;

public sealed class TrayMenuModelTests
{
    [Fact]
    public void DefaultTrayAssetsAreCopiedBesideTheApplication()
    {
        var assets = TrayIconAssets.FindDefault();
        var expectedDirectory = Path.Combine(AppContext.BaseDirectory, "Assets");

        Assert.Equal(Path.GetFullPath(expectedDirectory), Path.GetFullPath(Path.GetDirectoryName(assets.Light)!));
        Assert.True(File.Exists(assets.Light));
        Assert.True(File.Exists(assets.Dark));
        Assert.True(File.Exists(assets.AttentionLight));
        Assert.True(File.Exists(assets.AttentionDark));
    }

    [Fact]
    public void HoldsActionStateShortcutsChildrenAndSeparators()
    {
        var model = new TrayMenuModel(
        [
            new TrayMenuItem("capture", "Capture Area", "Alt+Shift+G", Enabled: true),
            TrayMenuItem.Separator(),
            new TrayMenuItem("setup", "Setup…", Checked: true,
                Children: [new TrayMenuItem("shortcuts", "Shortcuts", Enabled: false)])
        ]);

        Assert.Equal(3, model.Items.Count);
        Assert.Equal("Alt+Shift+G", model.Items[0].ShortcutText);
        Assert.True(model.Items[1].IsSeparator);
        Assert.Equal("shortcuts", model.Items[2].Children![0].Id);
        Assert.True(model.Items[2].Checked);
    }

    [Fact]
    public void RequiresUniqueIdsAcrossSubmenus()
    {
        Assert.Throws<ArgumentException>(() => new TrayMenuModel(
        [
            new TrayMenuItem("same", "One"),
            new TrayMenuItem("parent", "Two", Children: [new TrayMenuItem("same", "Nested")])
        ]));
    }
}

public sealed class TrayInteractiveTests
{
    [Fact]
    [Trait("Needs", "InteractiveDesktop")]
    public void TrayIconRegistersAndCanShowItsMenu()
    {
        var assets = FindRepositoryAssets();
        using var tray = new TrayIcon(static _ => { }, assets)
        {
            Menu = new TrayMenuModel([new TrayMenuItem("capture", "Capture Area")])
        };

        if (!tray.IsRegistered)
        {
            Assert.Skip("The interactive Windows shell did not accept the tray icon.");
        }

        using var dismiss = new System.Threading.Timer(_ => tray.CancelCurrentMenu(), null, 500, Timeout.Infinite);
        if (!tray.TryShowMenu())
        {
            Assert.Skip("SetForegroundWindow could not foreground the tray owner's own window.");
        }

        Assert.True(tray.IsRegistered);
    }

    private static TrayIconAssets FindRepositoryAssets()
    {
        for (var directory = new DirectoryInfo(Environment.CurrentDirectory); directory is not null; directory = directory.Parent)
        {
            foreach (var candidatePath in new[]
                     {
                         Path.Combine(directory.FullName, "windows", "src", "CaptureApp.Platform", "Assets"),
                         Path.Combine(directory.FullName, "src", "CaptureApp.Platform", "Assets")
                     })
            {
                if (File.Exists(Path.Combine(candidatePath, "tray-light.ico")))
                {
                    return TrayIconAssets.FromDirectory(candidatePath);
                }
            }
        }

        return TrayIconAssets.FindDefault();
    }
}

public sealed class TrayCallbackTests
{
    private const uint WmMouseMove = 0x0200;
    private const uint WmContextMenu = 0x007B;
    private const uint WmLButtonUp = 0x0202;
    private const uint WmRButtonUp = 0x0205;
    private const uint NinSelect = 0x0400;
    private const uint NinKeySelect = 0x0401;

    [Fact]
    public void VersionFourCallbacksRouteContextLeftAndKeyboardActivationThroughOwnerWindow()
    {
        var requests = new List<CaptureApp.Platform.Tray.TrayNativeMethods.Point?>();
        using var tray = new TrayIcon(
            static _ => { },
            TrayIconAssets.FindDefault(),
            registerShellIcon: false,
            version4Callbacks: true,
            menuPresenterForTesting: position =>
            {
                requests.Add(position);
                return true;
            });

        Assert.NotEqual(IntPtr.Zero, tray.NativeWindowHandleForTesting);
        Send(tray, WmContextMenu, x: 410, y: 320);
        Send(tray, NinSelect, x: 411, y: 321);
        Send(tray, NinKeySelect, x: -1, y: -1);

        Assert.Equal(3, requests.Count);
        Assert.Equal(new CaptureApp.Platform.Tray.TrayNativeMethods.Point { X = 410, Y = 320 }, requests[0]);
        Assert.Equal(new CaptureApp.Platform.Tray.TrayNativeMethods.Point { X = 411, Y = 321 }, requests[1]);
        Assert.Null(requests[2]);
    }

    [Fact]
    public void VersionFourCallbacksIgnoreOtherIconsAndNonActivationEvents()
    {
        var requests = new List<CaptureApp.Platform.Tray.TrayNativeMethods.Point?>();
        using var tray = new TrayIcon(
            static _ => { },
            TrayIconAssets.FindDefault(),
            registerShellIcon: false,
            version4Callbacks: true,
            menuPresenterForTesting: position =>
            {
                requests.Add(position);
                return true;
            });

        Send(tray, WmMouseMove, x: 410, y: 320);
        Send(tray, WmContextMenu, x: 410, y: 320, iconId: 2);

        Assert.Empty(requests);
    }

    [Fact]
    public void VersionFourMouseUpAndSemanticCallbackPairsPresentOneMenuPerClick()
    {
        var requests = new List<CaptureApp.Platform.Tray.TrayNativeMethods.Point?>();
        using var tray = new TrayIcon(
            static _ => { },
            TrayIconAssets.FindDefault(),
            registerShellIcon: false,
            version4Callbacks: true,
            menuPresenterForTesting: position =>
            {
                requests.Add(position);
                return true;
            });

        // Explorer sends both callbacks for each physical click. The mouse-up must
        // not start a native menu loop before the semantic activation arrives.
        Send(tray, WmLButtonUp, x: 410, y: 320);
        Assert.Empty(requests);
        Send(tray, NinSelect, x: 410, y: 320);
        Assert.Single(requests);

        Send(tray, WmRButtonUp, x: 411, y: 321);
        Assert.Single(requests);
        Send(tray, WmContextMenu, x: 411, y: 321);
        Assert.Equal(2, requests.Count);
    }

    [Fact]
    public void SemanticActivationDuringAnOpenMenuDoesNotReenterAndNextClickStillOpens()
    {
        var presentationCount = 0;
        TrayIcon? tray = null;
        using (tray = new TrayIcon(
            static _ => { },
            TrayIconAssets.FindDefault(),
            registerShellIcon: false,
            version4Callbacks: true,
            menuPresenterForTesting: _ =>
            {
                presentationCount++;
                if (presentationCount == 1)
                {
                    // TrackPopupMenuEx runs a nested message loop. A callback received
                    // there must leave the existing native menu in control.
                    Send(tray!, NinSelect, x: 410, y: 320);
                }

                return true;
            }))
        {
            Send(tray, WmContextMenu, x: 410, y: 320);
            Assert.Equal(1, presentationCount);

            Send(tray, NinSelect, x: 411, y: 321);
            Assert.Equal(2, presentationCount);
        }
    }

    [Fact]
    public void LegacyCallbacksRemainRoutableWhenVersionFourNegotiationFails()
    {
        var requests = new List<CaptureApp.Platform.Tray.TrayNativeMethods.Point?>();
        using var tray = new TrayIcon(
            static _ => { },
            TrayIconAssets.FindDefault(),
            registerShellIcon: false,
            version4Callbacks: false,
            menuPresenterForTesting: position =>
            {
                requests.Add(position);
                return true;
            });

        SendLegacy(tray, WmContextMenu);
        SendLegacy(tray, WmLButtonUp);
        SendLegacy(tray, WmRButtonUp);

        Assert.Equal(3, requests.Count);
        Assert.All(requests, position => Assert.Null(position));
    }

    [Fact]
    public void BackToBackMenuCallbacksPostBenignCleanupAndPresentBothMenus()
    {
        const uint WmNull = 0x0000;
        var presentationCount = 0;
        var postedMessages = new List<uint>();
        using var tray = new TrayIcon(
            static _ => { },
            TrayIconAssets.FindDefault(),
            registerShellIcon: false,
            version4Callbacks: true,
            menuPresenterForTesting: _ =>
            {
                presentationCount++;
                return true;
            },
            postTrackMessageForTesting: message =>
            {
                postedMessages.Add(message);
                return true;
            });

        Send(tray, WmContextMenu, x: 410, y: 320);
        Send(tray, NinSelect, x: 411, y: 321);

        Assert.Equal(2, presentationCount);
        Assert.Equal(new[] { WmNull, WmNull }, postedMessages);
    }

    private static void Send(TrayIcon tray, uint eventId, short x, short y, uint iconId = 1)
    {
        var packedCoordinates = (nuint)(unchecked((ushort)x) | ((uint)unchecked((ushort)y) << 16));
        var packedCallback = unchecked((nint)((iconId << 16) | (eventId & 0xFFFF)));
        CaptureApp.Platform.Tray.TrayNativeMethods.SendMessage(
            tray.NativeWindowHandleForTesting,
            TrayIcon.NotifyCallbackMessageForTesting,
            packedCoordinates,
            packedCallback);
    }

    private static void SendLegacy(TrayIcon tray, uint eventId)
    {
        CaptureApp.Platform.Tray.TrayNativeMethods.SendMessage(
            tray.NativeWindowHandleForTesting,
            TrayIcon.NotifyCallbackMessageForTesting,
            1,
            unchecked((nint)eventId));
    }
}
