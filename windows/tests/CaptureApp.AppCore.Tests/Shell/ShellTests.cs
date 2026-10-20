using CaptureApp.AppCore.Shell;
using Xunit;

namespace CaptureApp.AppCore.Tests.Shell;

public sealed class SetupStateTests
{
    private static SetupState Open(TempDirectory directory) => new(new SettingsStore(Path.Combine(directory.Path, "settings.json")));

    private static void PassRequired(SetupState state)
    {
        state.Mark(SetupStepId.Disclosure, SetupStatus.Passed);
        state.Mark(SetupStepId.NotesFolder, SetupStatus.Passed);
        state.Mark(SetupStepId.Shortcuts, SetupStatus.Passed);
    }

    [Fact]
    public void FreshStateNeedsSetupAndStoresNothing()
    {
        using var directory = new TempDirectory();
        var state = Open(directory);
        Assert.True(state.NeverRan);
        Assert.False(state.ConsentAnswered);
        Assert.True(state.ShouldOpenOnLaunch(false));
        Assert.Equal(SetupStepId.Disclosure, state.FirstIncompleteRequired);
        Assert.False(File.Exists(Path.Combine(directory.Path, "settings.json")));
    }

    [Theory]
    [InlineData(SetupStepId.Disclosure)]
    [InlineData(SetupStepId.NotesFolder)]
    [InlineData(SetupStepId.Shortcuts)]
    [InlineData(SetupStepId.SelectionTest)]
    [InlineData(SetupStepId.AreaTest)]
    [InlineData(SetupStepId.TrayIcon)]
    [InlineData(SetupStepId.StartAtLogin)]
    [InlineData(SetupStepId.Updates)]
    public void KillingAfterAnyStepResumesThere(SetupStepId last)
    {
        using var directory = new TempDirectory();
        var state = Open(directory);
        foreach (var info in SetupSteps.All)
        {
            state.Mark(info.Id, SetupStatus.Passed, "ok");
            if (info.Id == last) { break; }
        }

        var relaunched = Open(directory);
        foreach (var info in SetupSteps.All.TakeWhile(info => (int)info.Id <= (int)last))
        {
            Assert.Equal(SetupStatus.Passed, relaunched.Status(info.Id));
        }

        Assert.Equal((int)last >= (int)SetupStepId.Shortcuts, relaunched.FirstIncompleteRequired is null);
        Assert.False(relaunched.NeverRan);
    }

    [Theory]
    [InlineData(SetupStepId.SelectionTest)]
    [InlineData(SetupStepId.AreaTest)]
    [InlineData(SetupStepId.TrayIcon)]
    [InlineData(SetupStepId.StartAtLogin)]
    [InlineData(SetupStepId.Updates)]
    [InlineData(SetupStepId.Semantic)]
    public void SkippingARecommendedStepRaisesNoBadge(SetupStepId id)
    {
        using var directory = new TempDirectory();
        var state = Open(directory);
        PassRequired(state);
        state.Mark(id, SetupStatus.Skipped);
        Assert.False(state.NeedsAttention);
        Assert.Equal(0, state.AttentionCount);
        Assert.False(Open(directory).ShouldOpenOnLaunch(false));
    }

    [Theory]
    [InlineData(SetupStepId.Disclosure)]
    [InlineData(SetupStepId.NotesFolder)]
    [InlineData(SetupStepId.Shortcuts)]
    public void FailingARequiredStepRaisesBadgeAndReopens(SetupStepId id)
    {
        using var directory = new TempDirectory();
        var state = Open(directory);
        PassRequired(state);
        state.Mark(id, SetupStatus.Failed, "cause");
        Assert.True(state.NeedsAttention);
        Assert.Equal(1, state.AttentionCount);
        var relaunched = Open(directory);
        Assert.True(relaunched.ShouldOpenOnLaunch(false));
        Assert.Equal(id, relaunched.FirstIncompleteRequired);
        Assert.Equal("cause", relaunched.State(id).Detail);
    }

    [Fact]
    public void RevokedChecksFlipOnRevalidation()
    {
        using var directory = new TempDirectory();
        var state = Open(directory);
        PassRequired(state);
        state.Mark(SetupStepId.StartAtLogin, SetupStatus.Passed);
        state.Mark(SetupStepId.Updates, SetupStatus.Passed);

        var regressed = state.Revalidate(new RevalidationReport(false, ["CaptureArea"], false, false));
        Assert.Equal([SetupStepId.NotesFolder, SetupStepId.Shortcuts, SetupStepId.StartAtLogin, SetupStepId.Updates], regressed);
        Assert.Equal(4, state.AttentionCount);

        var healed = state.Revalidate(new RevalidationReport(true, [], true, true));
        Assert.Empty(healed);
        Assert.Equal(0, state.AttentionCount);
    }

    [Fact]
    public void NothingIsRevalidatedBeforeConsent()
    {
        using var directory = new TempDirectory();
        var state = Open(directory);
        Assert.Empty(state.Revalidate(new RevalidationReport(false, ["x"], false, false)));
    }

    [Fact]
    public void VersionBumpShowsOnlyNewStepsUnlessOpenedManually()
    {
        using var directory = new TempDirectory();
        var state = Open(directory);
        PassRequired(state);
        Assert.Equal(SetupSteps.All.Count, state.StepsToShow(manualOpen: false).Count);
        Assert.Equal(SetupSteps.All.Count, state.StepsToShow(manualOpen: true).Count);
        Assert.Equal(SetupSteps.CurrentVersion, state.StoredVersion);
    }

    [Fact]
    public void CorruptSettingsRerunSetup()
    {
        using var directory = new TempDirectory();
        File.WriteAllText(Path.Combine(directory.Path, "settings.json"), "{ nope");
        var state = Open(directory);
        Assert.True(state.NeverRan);
        Assert.True(state.ShouldOpenOnLaunch(false));
    }

    [Fact]
    public void SettingsKeepIndependentSections()
    {
        using var directory = new TempDirectory();
        var store = new SettingsStore(Path.Combine(directory.Path, "settings.json"));
        store.ClipboardFallback = true;
        store.NotesFolder = "D:\\Notes";
        store.StartAtLogin = false;
        store.UpdatesChoice = UpdatesChoice.Manual;
        store.DisabledShortcuts = new HashSet<string> { "CaptureArea" };
        store.WritePanel("k", 0.5, 0.25);
        new SetupState(store).Mark(SetupStepId.Disclosure, SetupStatus.Passed);

        var reopened = new SettingsStore(store.Path);
        Assert.True(reopened.ClipboardFallback);
        Assert.Equal("D:\\Notes", reopened.NotesFolder);
        Assert.False(reopened.StartAtLogin);
        Assert.Equal(UpdatesChoice.Manual, reopened.UpdatesChoice);
        Assert.Contains("CaptureArea", reopened.DisabledShortcuts);
        Assert.Equal((0.5, 0.25), reopened.ReadPanel("k"));
        Assert.True(new SetupState(reopened).ConsentAnswered);
        reopened.ClipboardFallback = null;
        Assert.Null(reopened.ClipboardFallback);
    }
}

public sealed class CapabilityTests
{
    private static CapabilityInputs Inputs(bool consent = true, int failed = 0, bool? fallback = true, bool? folder = true,
        bool? login = true, bool run = true, bool service = true, UpdatesChoice? updates = UpdatesChoice.Auto) =>
        new(consent, 7 - failed, failed, 0, fallback, folder, true, login, run, service, updates);

    [Fact]
    public void EverythingAvailableWhenHealthy()
    {
        Assert.All(Capabilities.Evaluate(Inputs()), status => Assert.True(status.IsAvailable));
    }

    [Fact]
    public void NothingRunsBeforeConsent()
    {
        var table = Capabilities.Evaluate(Inputs(consent: false, fallback: null));
        Assert.Equal(CapabilityState.Unavailable, Capabilities.Of(table, CapabilityId.Shortcuts).State);
        Assert.Equal(CapabilityState.Unavailable, Capabilities.Of(table, CapabilityId.SelectionCapture).State);
        Assert.Equal(CapabilityState.Unavailable, Capabilities.Of(table, CapabilityId.AreaCapture).State);
    }

    [Fact]
    public void ChoicesAndFailuresMapToStates()
    {
        var table = Capabilities.Evaluate(Inputs(failed: 2, fallback: false, folder: false, login: true, run: false, service: false));
        Assert.Equal(CapabilityState.Unavailable, Capabilities.Of(table, CapabilityId.Shortcuts).State);
        Assert.Equal("2 keyboard shortcuts unavailable", Capabilities.Of(table, CapabilityId.Shortcuts).Reason);
        Assert.Equal(CapabilityState.Off, Capabilities.Of(table, CapabilityId.ClipboardFallback).State);
        Assert.Equal(CapabilityState.Unavailable, Capabilities.Of(table, CapabilityId.NotesFolder).State);
        Assert.Equal(CapabilityState.Unavailable, Capabilities.Of(table, CapabilityId.StartAtLogin).State);
        Assert.Equal(CapabilityState.Unavailable, Capabilities.Of(table, CapabilityId.Updates).State);
        Assert.Equal(CapabilityState.Off, Capabilities.Of(Capabilities.Evaluate(Inputs(login: false)), CapabilityId.StartAtLogin).State);
        Assert.Equal(CapabilityState.Off, Capabilities.Of(Capabilities.Evaluate(Inputs(updates: UpdatesChoice.Manual)), CapabilityId.Updates).State);
    }
}

public sealed class TrayMenuTests
{
    private static MenuState State(bool consent = true, int attention = 0, string? session = null, int failed = 0,
        SemanticMenuState? semantic = null, UpdateMenuState? update = null) =>
        new(consent, attention, session, new Dictionary<string, string> { [MenuIds.Search] = "Ctrl+Alt+Shift+F" }, failed,
            semantic ?? new(SemanticMenuPhase.NotInstalled), update ?? new(UpdateMenuKind.Idle));

    private static string[] Ids(IEnumerable<MenuEntry> entries) => entries.Select(e => e.IsSeparator ? "-" : e.Id).ToArray();

    [Fact]
    public void DefaultOrderMatchesTheMacMenu()
    {
        Assert.Equal(["capture-selection", "capture-area", "search", "session", "write-note", "add-subheading", "-", "open-folder",
            "semantic", "setup", "settings", "check-updates", "-", "quit"], Ids(TrayMenuBuilder.Build(State())));
    }

    [Fact]
    public void LabelsAndBindings()
    {
        var items = TrayMenuBuilder.Build(State(session: "Standup"));
        Assert.Equal("End Session “Standup”", items.Single(i => i.Id == MenuIds.Session).Title);
        Assert.Equal("Ctrl+Alt+Shift+F", items.Single(i => i.Id == MenuIds.Search).Shortcut);
        Assert.Equal("Enable Semantic Search…", items.Single(i => i.Id == MenuIds.Semantic).Title);
        Assert.Equal("Start Session…", TrayMenuBuilder.Build(State()).Single(i => i.Id == MenuIds.Session).Title);
    }

    [Fact]
    public void FailedShortcutsAddStatusAndRetry()
    {
        var items = TrayMenuBuilder.Build(State(failed: 1));
        var status = items.Single(i => i.Id == MenuIds.ShortcutStatus);
        Assert.Equal("1 keyboard shortcut unavailable", status.Title);
        Assert.False(status.Enabled);
        Assert.Equal(MenuIds.RetryShortcuts, items[items.ToList().IndexOf(status) + 1].Id);
        Assert.Equal("3 keyboard shortcuts unavailable", TrayMenuBuilder.Build(State(failed: 3)).Single(i => i.Id == MenuIds.ShortcutStatus).Title);
    }

    [Fact]
    public void AttentionPutsFinishSetupFirstAndConsentGatesTheRest()
    {
        var first = TrayMenuBuilder.Build(State(attention: 2))[0];
        Assert.Equal("Finish Setup… (2 left)", first.Title);
        Assert.Equal(["finish-setup", "quit"], Ids(TrayMenuBuilder.Build(State(consent: false, attention: 3))));
    }

    [Fact]
    public void SemanticStates()
    {
        string Title(SemanticMenuState s) => TrayMenuBuilder.Build(State(semantic: s)).Single(i => i.Id == MenuIds.Semantic).Title;
        Assert.Equal("Resume Semantic Search…", Title(new(SemanticMenuPhase.NotInstalled, true)));
        Assert.Equal("Downloading Models… 42%", Title(new(SemanticMenuPhase.Downloading, Percent: 42)));
        Assert.Equal("Removing Models…", Title(new(SemanticMenuPhase.Removing)));
        var installed = TrayMenuBuilder.Build(State(semantic: new(SemanticMenuPhase.Installed))).Single(i => i.Id == MenuIds.Semantic);
        Assert.True(installed.Checked);
        Assert.Equal("Remove Models…", installed.Children!.Single().Title);
    }

    [Fact]
    public void UpdateItems()
    {
        Assert.DoesNotContain(TrayMenuBuilder.Build(State(update: new(UpdateMenuKind.Hidden))), i => i.Id == MenuIds.CheckUpdates);
        Assert.Equal("Restart to Update (v1.2.3)", TrayMenuBuilder.Build(State(update: new(UpdateMenuKind.ReadyToRestart, "1.2.3")))
            .Single(i => i.Id == MenuIds.RestartToUpdate).Title);
        var failed = TrayMenuBuilder.Build(State(update: new(UpdateMenuKind.Failed))).Single(i => i.Id == MenuIds.UpdateFailed);
        Assert.Equal(["Retry", "Download installer"], failed.Children!.Select(c => c.Title));
    }
}

public sealed class StringTableTests
{
    [Fact]
    public void MappedWording()
    {
        Assert.Equal("Open the tray icon → Setup", Strings.OpenTraySetup);
        Assert.Equal("Select text first, or use Ctrl+Alt+Shift+G for an area", Strings.NoTextSelectedSubtitle("Ctrl+Alt+Shift+G"));
        Assert.Equal("Captures go here until Ctrl+Alt+Shift+A", Strings.SessionCapturesGoHere("Ctrl+Alt+Shift+A"));
        Assert.Equal("Session resumed · X", Strings.SessionStarted("X", true));
        Assert.Equal("1 capture", Strings.CaptureCount(1));
        Assert.Equal("3 captures", Strings.CaptureCount(3));
        Assert.Equal("Note created", Strings.NoteCreatedOrAdded(true));
        Assert.DoesNotContain("⌥", Strings.ShortcutsUnavailableSubtitle);
        Assert.DoesNotContain("menu bar", Strings.ShortcutsUnavailableSubtitle);
        Assert.Contains("huggingface.co", Strings.DownloadModelsBody("1 GB"));
    }

    [Fact]
    public void FirstLineIsCutAtOneHundredCharacters()
    {
        Assert.Equal("a", PendingCaptures.FirstLine("a\nb"));
        var cut = PendingCaptures.FirstLine(new string('x', 150));
        Assert.Equal(100, cut.Length);
        Assert.EndsWith("…", cut);
    }
}

public sealed class ControllerSelfTestTests
{
    [Fact]
    public async Task ControllerSectionsPass()
    {
        using var directory = new TempDirectory();
        var output = new StringWriter();
        await ControllerSelfTest.RunAsync(directory.Path, TimeZoneInfo.Utc, output, TestContext.Current.CancellationToken);
        Assert.Contains("controller shutdown drain", output.ToString());
        Assert.Contains("in-flight quit recovered", output.ToString());
    }
}
