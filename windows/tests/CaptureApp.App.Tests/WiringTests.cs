using System.IO;
using System.Windows;
using System.Windows.Threading;
using CaptureApp.App;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Overlay;
using CaptureApp.Platform.Hotkeys;
using System.Windows.Input;
using Xunit;

namespace CaptureApp.App.Tests;

public sealed class WiringTests
{
    // Reuse SetupWindowTests' STA/Application: WPF permits one Application per process.
    internal static void OutsideCaptureEscapeUsesTitlePickerCancellation(Application app)
    {
        foreach (var image in new[] { false, true })
        {
            var root = Path.Combine(Path.GetTempPath(), "outside-picker-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                using var pipeline = CapturePipeline.Open(Path.Combine(root, "vault"), Path.Combine(root, "state"), TimeZoneInfo.Utc);
                using var controller = new AppController(app, pipeline.StateDirectory, pipeline);
                var session = pipeline.Sessions.Start("Inbox");
                var sessionUrl = pipeline.Vault.ManagedUrl(session.NotePath);
                var sessionBefore = File.ReadAllBytes(sessionUrl);
                var nestedUrl = Path.Combine(pipeline.Vault.Root, "science", "Inbox.md");
                const string nestedBefore = "# Inbox\n\nKeep this nested Inbox unchanged.\n";
                Directory.CreateDirectory(Path.GetDirectoryName(nestedUrl)!);
                File.WriteAllText(nestedUrl, nestedBefore);
                var capture = (image ? PendingCaptures.Image([137, 80, 78, 71], "picker OCR", new())
                    : PendingCaptures.Selection("outside picker escape capture", new())) with { OutsideSession = true };
                var stage = controller.Coordinator.StageAsync(capture);
                UiWait.Pump(stage, TimeSpan.FromSeconds(5));
                Assert.True(stage.IsCompleted, "Outside capture staging did not complete.");
                stage.GetAwaiter().GetResult();
                var journaled = pipeline.Journal.Load(Assert.Single(pipeline.Journal.RecordPaths()));
                Assert.Equal(new Destination(pipeline.Vault.InboxUrl, Vault.InboxTitle, NoteKind.Inbox), journaled.Prepared.Destination);

                WaitUntil(() => controller.InputForChecks is { IsVisible: true }, "Outside capture did not open its title picker.");
                var picker = Assert.IsType<InputPanelController>(controller.InputForChecks);
                Assert.True(picker.HandleInput(Key.Escape));
                // This runs InputPanel's close handler, PresentInput's onCancel,
                // and ShowTitlePicker's CommitPending callback before inspecting the save.
                WaitUntil(() => controller.InputForChecks is null, "Escape did not close the title picker.");
                Assert.Null(controller.Coordinator.Pending);
                var commit = controller.Coordinator.SettleCapturesAsync();
                UiWait.Pump(commit, TimeSpan.FromSeconds(5));
                Assert.True(commit.IsCompleted, "The title picker cancellation did not finish saving.");
                commit.GetAwaiter().GetResult();
                Assert.Equal("Inbox.md", pipeline.Index.Capture(capture.Id)?.NotePath);
                Assert.Empty(pipeline.Journal.RecordPaths());
                Assert.Equal(sessionBefore, File.ReadAllBytes(sessionUrl));
                Assert.Equal(nestedBefore, File.ReadAllText(nestedUrl));
                Assert.Equal(session, pipeline.Sessions.Current());
                if (image)
                {
                    var asset = Assert.Single(Directory.GetFiles(pipeline.Vault.AssetsUrl));
                    Assert.Equal(capture.Png, File.ReadAllBytes(asset));
                }
            }
            finally { Directory.Delete(root, true); }
        }

        static void WaitUntil(Func<bool> condition, string failure)
        {
            var completed = new TaskCompletionSource();
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
            timer.Tick += (_, _) => { if (condition()) completed.TrySetResult(); };
            timer.Start();
            try
            {
                UiWait.Pump(completed.Task, TimeSpan.FromSeconds(5));
                Assert.True(completed.Task.IsCompleted, failure);
            }
            finally { timer.Stop(); }
        }
    }

    [Fact]
    public void OutsideSessionActionUsesControlShiftNAndOnlyAppearsForAnActiveSession()
    {
        Assert.Equal(NoteActionId.WriteOutsideSession, QuickNoteView.ShortcutAction(Key.N, ModifierKeys.Control | ModifierKeys.Shift));
        Assert.Equal(NoteActionId.NewNote, QuickNoteView.ShortcutAction(Key.N, ModifierKeys.Control));
        Assert.DoesNotContain(ActionItem.Standard(false, true), action => action.Id == NoteActionId.WriteOutsideSession);
        var action = Assert.Single(ActionItem.Standard(false, true, canWriteOutsideSession: true), item => item.Id == NoteActionId.WriteOutsideSession);
        Assert.Equal("Write outside session", action.Title);
        Assert.Equal(new[] { "Ctrl", "Shift", "N" }, action.Keys);
    }

    [Fact]
    public void OutsideQuickNoteHotkeyIsGlobalAndLeavesThePanelToggleOnControlShiftN()
    {
        var chord = HotkeyDefaults.For(HotkeyAction.WriteNoteOutsideSession);
        Assert.Equal("Ctrl+Shift+W", chord.DisplayString);
        Assert.True(HotkeyValidator.Validate(chord).IsValid);
        Assert.Null(QuickNoteView.ShortcutAction(Key.W, ModifierKeys.Control | ModifierKeys.Shift));
        Assert.False(HotkeyValidator.Validate(KeyChord.Parse("Ctrl+Shift+N")).IsValid);
        var session = new Destination("session.md", "Thermo", NoteKind.Session);
        Assert.True(new QuickNoteState(session, outsideSession: true).OutsideSession);
        Assert.Equal(session, new QuickNoteState(session).Destination);
    }

    [Theory]
    [InlineData(ModifierKeys.None, true, InputSubmitAction.Submit)]
    [InlineData(ModifierKeys.Control, true, InputSubmitAction.Alternate)]
    [InlineData(ModifierKeys.Control, false, InputSubmitAction.Submit)]
    [InlineData(ModifierKeys.Alt, true, InputSubmitAction.Ignore)]
    [InlineData(ModifierKeys.Shift, true, InputSubmitAction.Ignore)]
    [InlineData(ModifierKeys.Windows, true, InputSubmitAction.Ignore)]
    [InlineData(ModifierKeys.Control | ModifierKeys.Shift, true, InputSubmitAction.Ignore)]
    [InlineData(ModifierKeys.Control | ModifierKeys.Alt, true, InputSubmitAction.Ignore)]
    public void SessionPickerEnterUsesControlOnlyForRename(ModifierKeys modifiers, bool hasAlternate, InputSubmitAction expected) =>
        Assert.Equal(expected, InputPanelController.SubmissionAction(modifiers, hasAlternate));

    [Fact]
    public void ToastMappingKeepsStyleTextAndHint()
    {
        var toast = UiHost.Map(new AppToast(AppToastStyle.Warning, "Title", "Sub", "Ctrl+Q", "choose note", 6));
        Assert.Equal(ToastStyle.Warning, toast.Style);
        Assert.Equal("Title", toast.Title);
        Assert.Equal("Sub", toast.Subtitle);
        Assert.Equal(new ToastHint("Ctrl+Q", "choose note"), toast.Hint);
        Assert.Equal(6, toast.DurationSeconds);
        Assert.Null(UiHost.Map(new AppToast(AppToastStyle.Success, "x")).Hint);
    }

    [Fact]
    public void PanelPositionsPersistInTheSettingsSection()
    {
        var path = Path.Combine(Path.GetTempPath(), "captureapp-app-tests-" + Guid.NewGuid().ToString("N"), "settings.json");
        try
        {
            var store = new SettingsPanelPositionStore(new SettingsStore(path));
            Assert.Null(store.Load("k"));
            store.Save("k", new PanelPosition(0.5, 0.25));
            store.Save("bad", new PanelPosition(double.NaN, 1));
            Assert.Equal(new PanelPosition(0.5, 0.25), new SettingsPanelPositionStore(new SettingsStore(path)).Load("k"));
            Assert.Null(store.Load("bad"));
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(path)!, true);
        }
    }

    [Fact]
    public void ModelsAreReportedInstalledOnlyWhenEveryFileExists()
    {
        var directory = Path.Combine(Path.GetTempPath(), "captureapp-app-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            Assert.False(AppController.ModelsInstalled(directory));
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }
}

public sealed class ForegroundTrackerTests
{
    [Theory]
    [InlineData("Shell_TrayWnd", true)]
    [InlineData("Shell_SecondaryTrayWnd", true)]
    [InlineData("NotifyIconOverflowWindow", true)]
    [InlineData("TopLevelWindowForOverflowXamlIsland", true)]
    [InlineData("Progman", true)]
    [InlineData("WorkerW", true)]
    [InlineData("Notepad", false)]
    [InlineData("Chrome_WidgetWin_1", false)]
    [InlineData(null, false)]
    public void ShellClassesAreNeverCaptureTargets(string? className, bool isShell) =>
        Assert.Equal(isShell, ForegroundTracker.IsShellClass(className));
}

public sealed class MenuCaptureFlowTests
{
    private sealed class FakeProbe : IForegroundProbe
    {
        public nint Last { get; set; } = 100;
        public bool Restorable { get; set; } = true;
        public Func<nint> ForegroundWindow { get; set; } = () => 100;
        public nint ContextWindow { get; set; } = 100;
        public int Brought { get; private set; }
        public bool CanRestore(nint window) => Restorable;
        public void BringToForeground(nint window) => Brought++;
        public nint Foreground() => ForegroundWindow();
        public CaptureApp.Platform.Context.FrontmostContext CaptureContext() => new(ContextWindow, 7);
    }

    private static async Task<(int Refused, int Captured)> Run(FakeProbe probe)
    {
        var (refused, captured, _) = await RunDetailed(probe);
        return (refused, captured);
    }

    private static async Task<(int Refused, int Captured, bool? HadTarget)> RunDetailed(FakeProbe probe)
    {
        int refused = 0, captured = 0;
        bool? hadTarget = null;
        await new MenuCaptureFlow(probe).RunAsync(had => { refused++; hadTarget = had; }, _ => captured++, TimeSpan.FromMilliseconds(60));
        return (refused, captured, hadTarget);
    }

    [Fact]
    public async Task OnlyAMissingTargetIsNoTextSelected()
    {
        Assert.False((await RunDetailed(new FakeProbe { Last = 0 })).HadTarget);
        Assert.True((await RunDetailed(new FakeProbe { Restorable = false })).HadTarget);
        Assert.True((await RunDetailed(new FakeProbe { ForegroundWindow = () => 5 })).HadTarget);
        Assert.True((await RunDetailed(new FakeProbe { ContextWindow = 5 })).HadTarget);
    }

    [Fact]
    public void DesktopClearsTheTargetButOwnAndTrayWindowsKeepIt()
    {
        Assert.Equal(ForegroundTracker.Decision.Clear, ForegroundTracker.Decide(11, 10, "Progman"));
        Assert.Equal(ForegroundTracker.Decision.Clear, ForegroundTracker.Decide(11, 10, "WorkerW"));
        Assert.Equal(ForegroundTracker.Decision.Keep, ForegroundTracker.Decide(10, 10, "Notepad"));
        Assert.Equal(ForegroundTracker.Decision.Keep, ForegroundTracker.Decide(11, 10, "Shell_TrayWnd"));
        Assert.Equal(ForegroundTracker.Decision.Keep, ForegroundTracker.Decide(11, 10, "NotifyIconOverflowWindow"));
        Assert.Equal(ForegroundTracker.Decision.Track, ForegroundTracker.Decide(11, 10, "Notepad"));
    }

    [Fact]
    public async Task HappyPathCapturesTheTargetWindow()
    {
        var probe = new FakeProbe();
        Assert.Equal((0, 1), await Run(probe));
        Assert.Equal(1, probe.Brought);
    }

    [Fact]
    public async Task NoTargetOrUnrestorableTargetRefusesWithoutTouchingFocus()
    {
        var none = new FakeProbe { Last = 0 };
        Assert.Equal((1, 0), await Run(none));
        var gone = new FakeProbe { Restorable = false };
        Assert.Equal((1, 0), await Run(gone));
        Assert.Equal(0, none.Brought + gone.Brought);
    }

    [Fact]
    public async Task TargetThatNeverComesForegroundRefusesAfterTheDeadline()
    {
        var probe = new FakeProbe { ForegroundWindow = () => 5 };
        Assert.Equal((1, 0), await Run(probe));
    }

    [Fact]
    public async Task ForegroundChangingBeforeTheContextReadRefuses()
    {
        var probe = new FakeProbe { ContextWindow = 5 };
        Assert.Equal((1, 0), await Run(probe));
    }

    [Fact]
    public void OwnProcessAndShellWindowsAreNotTracked()
    {
        Assert.False(ForegroundTracker.ShouldTrack(10, 10, "Notepad"));
        Assert.False(ForegroundTracker.ShouldTrack(0, 10, "Notepad"));
        Assert.False(ForegroundTracker.ShouldTrack(11, 10, "Shell_TrayWnd"));
        Assert.True(ForegroundTracker.ShouldTrack(11, 10, "Notepad"));
    }
}
