using CaptureApp.AppCore;
using System.ComponentModel;
using Microsoft.Win32;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Markup;
using System.Windows.Media;
using Ellipse = System.Windows.Shapes.Ellipse;
using Shape = System.Windows.Shapes.Shape;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.ModelInstall;
using CaptureApp.Platform.Hotkeys;

namespace CaptureApp.App;

/// The first-launch Setup flow (§5): one page per step, with progress saved after every step.
/// All decisions live in <see cref="SetupState"/>; this window only presents them.
internal sealed class SetupWindow : Window
{
    private readonly AppController controller;
    private readonly IReadOnlyList<SetupStepInfo> steps;
    private readonly StackPanel list = new() { Margin = new Thickness(18, 20, 18, 20) };
    private readonly ContentControl page = new();
    private readonly Border pageCard = new() { CornerRadius = new CornerRadius(14), Padding = new Thickness(28), MinHeight = 420 };
    private readonly TextBlock status = UiKit.Text("", 12, false, "Secondary", 0);
    private readonly Button backButton;
    private readonly Button nextButton;
    private readonly Button closeButton;
    private readonly Style quietButtonStyle;
    private readonly Style primaryButtonStyle;
    private int current;
    private Action? detach;
    private bool closed;

    public SetupWindow(AppController controller, bool manual)
    {
        this.controller = controller;
        steps = controller.Setup.StepsToShow(manual);
        Title = $"{AppInfo.Name} Setup";
        Width = 960;
        Height = 720;
        MinWidth = 820;
        MinHeight = 620;
        ShowInTaskbar = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        UiKit.Themed(this);
        SetResourceReference(Control.BackgroundProperty, "SurfaceTint");
        quietButtonStyle = CreateButtonStyle(primary: false, promoteDefault: true);
        primaryButtonStyle = CreateButtonStyle(primary: true, promoteDefault: false);
        Resources[typeof(Button)] = quietButtonStyle;
        Resources[typeof(RadioButton)] = CreateChoiceStyle(radio: true);
        Resources[typeof(CheckBox)] = CreateChoiceStyle(radio: false);
        RefreshSetupPalette();
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        SystemParameters.StaticPropertyChanged += OnSystemParametersChanged;

        var layout = new Grid();
        layout.SetResourceReference(Panel.BackgroundProperty, "SurfaceTint");
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(260) });
        layout.ColumnDefinitions.Add(new ColumnDefinition());
        var sidebar = new Border
        {
            Child = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            BorderThickness = new Thickness(0, 0, 0.5, 0)
        };
        sidebar.SetResourceReference(Border.BackgroundProperty, "QuickClusterFill");
        sidebar.SetResourceReference(Border.BorderBrushProperty, "SurfaceBorder");
        layout.Children.Add(sidebar);

        pageCard.Child = page;
        pageCard.SetResourceReference(Border.BackgroundProperty, "CardFill");
        pageCard.SetResourceReference(Border.BorderBrushProperty, "CardBorder");
        pageCard.BorderThickness = new Thickness(0.5);
        var scroll = new ScrollViewer
        {
            Content = pageCard,
            Margin = new Thickness(28, 24, 28, 12),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };

        backButton = UiKit.Button("Back", () => Go(current - 1));
        nextButton = UiKit.Button("Next", () => Go(current + 1));
        closeButton = UiKit.Button("Close", Close);
        backButton.Style = quietButtonStyle;
        nextButton.Style = primaryButtonStyle;
        closeButton.Style = quietButtonStyle;
        AutomationProperties.SetAutomationId(backButton, "setup-back");
        AutomationProperties.SetAutomationId(nextButton, "setup-next");
        AutomationProperties.SetAutomationId(closeButton, "setup-close");
        backButton.MinWidth = nextButton.MinWidth = closeButton.MinWidth = 96;
        backButton.Padding = nextButton.Padding = closeButton.Padding = new Thickness(16, 8, 16, 8);

        var nav = new Grid();
        nav.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        nav.ColumnDefinitions.Add(new ColumnDefinition());
        nav.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(closeButton);
        actions.Children.Add(nextButton);
        closeButton.Margin = new Thickness(0, 0, 8, 0);
        nextButton.Margin = new Thickness(0);
        Grid.SetColumn(backButton, 0);
        Grid.SetColumn(actions, 2);
        nav.Children.Add(backButton);
        nav.Children.Add(actions);

        var footerGrid = new Grid { Margin = new Thickness(28, 0, 28, 22) };
        footerGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        footerGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        status.Margin = new Thickness(0, 0, 0, 12);
        Grid.SetRow(nav, 1);
        footerGrid.Children.Add(status);
        footerGrid.Children.Add(nav);

        var main = new Grid();
        main.RowDefinitions.Add(new RowDefinition());
        main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetColumn(scroll, 1);
        Grid.SetRow(scroll, 0);
        Grid.SetColumn(footerGrid, 1);
        Grid.SetRow(footerGrid, 1);
        main.Children.Add(scroll);
        main.Children.Add(footerGrid);
        Grid.SetColumn(main, 1);
        layout.Children.Add(main);
        Content = layout;

        // Reopen at the first incomplete Required step; a fresh run starts at the top.
        var first = controller.Setup.FirstStepNeedingAttention;
        var start = first is { } id ? steps.ToList().FindIndex(step => step.Id == id) : 0;
        Go(Math.Max(0, start));
        Closed += (_, _) =>
        {
            closed = true;
            detach?.Invoke();
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            SystemParameters.StaticPropertyChanged -= OnSystemParametersChanged;
        };
        Loaded += (_, _) => RefreshSetupPalette();
    }

    private SetupState State => controller.Setup;

    private void Go(int index)
    {
        if (index < 0 || index >= steps.Count) { return; }
        detach?.Invoke();
        detach = null;
        current = index;
        RenderList();
        backButton.Visibility = index == 0 ? Visibility.Collapsed : Visibility.Visible;
        nextButton.Visibility = index == steps.Count - 1 ? Visibility.Collapsed : Visibility.Visible;
        nextButton.IsDefault = false;
        closeButton.IsDefault = index == steps.Count - 1;
        closeButton.Style = index == steps.Count - 1 ? primaryButtonStyle : quietButtonStyle;
        closeButton.Margin = new Thickness(0, 0, index == steps.Count - 1 ? 0 : 8, 0);
        var info = steps[index];
        var body = new StackPanel();
        var tag = info.Class == SetupStepClass.Required ? "Required" : "Recommended";
        body.Children.Add(UiKit.Text($"STEP {index + 1} OF {steps.Count}  ·  {tag.ToUpperInvariant()}", 11, true, "BrandAccent", 12));
        var heading = UiKit.Text(info.Title, 28, true, "TextPrimary", 20);
        heading.FontFamily = new FontFamily("Segoe UI Variable Display, Segoe UI");
        body.Children.Add(heading);
        body.Children.Add(UiKit.Rule());
        var state = State.State(info.Id);
        if (state.Status == SetupStatus.Failed && state.Detail is { Length: > 0 } cause)
        {
            body.Children.Add(UiKit.Text(cause, 12, false, "Warning"));
        }

        switch (info.Id)
        {
            case SetupStepId.Disclosure: Disclosure(body); break;
            case SetupStepId.NotesFolder: NotesFolder(body); break;
            case SetupStepId.Shortcuts: Shortcuts(body); break;
            case SetupStepId.SelectionTest: CaptureTest(body, info.Id, CaptureTrigger.Selection); break;
            case SetupStepId.AreaTest: CaptureTest(body, info.Id, CaptureTrigger.Region); break;
            case SetupStepId.TrayIcon: TrayIcon(body); break;
            case SetupStepId.StartAtLogin: StartAtLogin(body); break;
            case SetupStepId.Updates: Updates(body); break;
            default: Semantic(body); break;
        }

        page.Content = body;
        status.Text = StatusText(info.Id);
    }

    private string StatusText(SetupStepId id)
    {
        var state = State.State(id);
        return state.Status switch
        {
            SetupStatus.Passed => "Done",
            SetupStatus.Failed => "Needs attention",
            SetupStatus.Skipped => "Not tested",
            _ => SetupSteps.Info(id).Class == SetupStepClass.Required ? "Not done yet" : "Not tested"
        };
    }

    private void RenderList()
    {
        list.Children.Clear();
        var heading = UiKit.Text("Setup", 21, true, "TextPrimary", 2);
        heading.FontFamily = new FontFamily("Segoe UI Variable Display, Segoe UI");
        list.Children.Add(heading);
        list.Children.Add(UiKit.Secondary("Get focusnotes ready", 16));
        list.Children.Add(UiKit.Rule());
        for (var i = 0; i < steps.Count; i++)
        {
            var index = i;
            var info = steps[i];
            var selected = i == current;
            var stepStatus = StatusText(info.Id);
            var glyph = State.Status(info.Id) switch
            {
                SetupStatus.Passed => "✓",
                SetupStatus.Failed => "!",
                SetupStatus.Skipped => "–",
                _ => (i + 1).ToString(System.Globalization.CultureInfo.InvariantCulture)
            };
            var item = new Button
            {
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                VerticalContentAlignment = VerticalAlignment.Stretch,
                Padding = new Thickness(0),
                Margin = new Thickness(0, 2, 0, 2),
                Style = quietButtonStyle
            };
            AutomationProperties.SetAutomationId(item, $"setup-step-{index + 1}");
            AutomationProperties.SetName(item, $"{info.Title}, {stepStatus}");
            AutomationProperties.SetItemStatus(item, selected ? "Current step" : stepStatus);

            var row = new Border { Padding = new Thickness(10, 9, 10, 9), CornerRadius = new CornerRadius(8) };
            row.SetResourceReference(Border.BackgroundProperty, selected ? "SetupSelectionFill" : "Transparent");
            var columns = new Grid();
            columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
            columns.ColumnDefinitions.Add(new ColumnDefinition());
            var glyphBlock = UiKit.Text(glyph, 12, true, State.Status(info.Id) == SetupStatus.Failed && !selected ? "Warning" : selected ? "SetupSelectionAccent" : "Secondary", 0);
            glyphBlock.HorizontalAlignment = HorizontalAlignment.Center;
            glyphBlock.VerticalAlignment = VerticalAlignment.Center;
            glyphBlock.TextAlignment = TextAlignment.Center;
            var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            labels.Children.Add(UiKit.Text(info.Title, 13, selected, selected ? "SetupSelectionText" : "TextPrimary", 2));
            labels.Children.Add(UiKit.Text(stepStatus, 11, false, selected ? "SetupSelectionSecondary" : State.Status(info.Id) == SetupStatus.Failed ? "Warning" : "Secondary", 0));
            Grid.SetColumn(labels, 1);
            columns.Children.Add(glyphBlock);
            columns.Children.Add(labels);
            row.Child = columns;
            item.Content = row;
            item.Click += (_, _) => Go(index);
            list.Children.Add(item);
        }
    }

    private bool Mark(SetupStepId id, SetupStatus value, string? detail = null) => controller.MarkSetup(id, value, detail);

    private void Finish(SetupStepId id, SetupStatus value, string? detail = null)
    {
        if (!Mark(id, value, detail)) { return; }
        if (current + 1 < steps.Count && value != SetupStatus.Failed) { Go(current + 1); } else { Go(current); }
    }

    private Button SkipButton(SetupStepId id) => UiKit.Button("Skip", () => Finish(id, SetupStatus.Skipped));

    // Step 0.
    private void Disclosure(StackPanel body)
    {
        body.Children.Add(UiKit.Text($"{AppInfo.Name} uses the following. Nothing runs, and no shortcut is registered, until you answer both choices below.", 13, false, "TextPrimary", 8));
        foreach (var bullet in new[]
                 {
                     "Global keyboard shortcuts, registered system-wide.",
                     "Reading the selected text of the app in front, only when you press Capture Selection, through UI Automation.",
                     "The clipboard fallback: it briefly sends Ctrl+C to that app, then restores your clipboard. The app's own copy may appear in Windows clipboard history.",
                     "Screen pixels, only while you drag a Capture Area.",
                     $"Writing Markdown into your notes folder, and app state into %LocalAppData%\\{AppInfo.BundleId}.",
                     "Network: only update checks and downloads from github.com and, if you later enable semantic search, model downloads from huggingface.co.",
                     "Start at login is pre-checked on its setup page."
                 })
        {
            body.Children.Add(UiKit.Text("•  " + bullet, 13, false, "TextPrimary", 3));
        }

        body.Children.Add(UiKit.Rule());
        body.Children.Add(UiKit.Text("Clipboard fallback", 13, true));
        var use = UiKit.Radio("Use clipboard fallback", "fallback", controller.Settings.ClipboardFallback == true);
        var dont = UiKit.Radio("Don't", "fallback", controller.Settings.ClipboardFallback == false);
        body.Children.Add(use);
        body.Children.Add(dont);
        body.Children.Add(UiKit.Text("Updates", 13, true));
        var auto = UiKit.Radio("Check for updates automatically (daily)", "updates", controller.Settings.UpdatesChoice == UpdatesChoice.Auto);
        var manual = UiKit.Radio("Only when I ask", "updates", controller.Settings.UpdatesChoice == UpdatesChoice.Manual);
        body.Children.Add(auto);
        body.Children.Add(manual);
        var message = UiKit.Text("", 12, false, "Warning");
        body.Children.Add(message);
        body.Children.Add(UiKit.Row(UiKit.Button("Continue", () =>
        {
            if ((use.IsChecked != true && dont.IsChecked != true) || (auto.IsChecked != true && manual.IsChecked != true))
            {
                message.Text = "Choose one option in each group to continue.";
                return;
            }

            var previousFallback = controller.Settings.ClipboardFallback;
            var previousChoice = controller.Settings.UpdatesChoice;
            if (!controller.ApplyClipboardFallback(use.IsChecked == true)) { return; }
            if (!controller.ApplyUpdatesChoice(auto.IsChecked == true ? UpdatesChoice.Auto : UpdatesChoice.Manual)
                || !Mark(SetupStepId.Disclosure, SetupStatus.Passed))
            {
                // Step 0 stays unanswered, so neither choice may look saved.
                controller.TrySave(() => controller.Settings.ClipboardFallback = previousFallback);
                controller.TrySave(() => controller.Settings.UpdatesChoice = previousChoice);
                return;
            }

            controller.OnConsentAnswered();
            Go(current + 1);
        }, true)));
    }

    // Step 1.
    private void NotesFolder(StackPanel body)
    {
        body.Children.Add(UiKit.Text("Captures are saved as Markdown in this folder. The default is inside Documents. Changes take effect after restarting; existing notes stay in their current folder.", 13, false, "TextPrimary", 8));
        var path = new TextBox { Text = controller.CurrentNotesFolder, Margin = new Thickness(0, 4, 8, 4), MinWidth = 380 };
        var result = UiKit.Text(controller.NotesFolderNeedsRestart ? controller.NotesFolderChangeMessage : "", 12, false, "Secondary");
        void Check()
        {
            var folder = path.Text.Trim();
            var notes = new List<string>();
            if (IsOneDrive(folder)) { notes.Add("This folder is backed up by OneDrive. If files are online-only, indexing may be slow until they are downloaded; consider \"Always keep on this device\"."); }
            if (!controller.SaveNotesFolder(folder, out var error))
            {
                var detail = error ?? Strings.CouldNotSaveSettings;
                if (IsProtectedFolder(folder)) { detail += " Controlled folder access in Windows Security may be blocking this app. Allow it under Windows Security → Virus & threat protection → Ransomware protection → Allow an app. Until then captures are kept safely in the app's recovery folder."; }
                Mark(SetupStepId.NotesFolder, SetupStatus.Failed, detail);
                result.SetResourceReference(TextBlock.ForegroundProperty, "Warning");
                result.Text = string.Join("\n", notes.Prepend(detail));
                RenderList();
                status.Text = StatusText(SetupStepId.NotesFolder);
                return;
            }

            path.Text = controller.CurrentNotesFolder;
            var changed = controller.NotesFolderNeedsRestart;
            Mark(SetupStepId.NotesFolder, SetupStatus.Passed, changed ? "Applied on restart" : null);
            result.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
            result.Text = string.Join("\n", notes.Prepend(changed ? controller.NotesFolderChangeMessage : "The folder is writable."));
            RenderList();
            status.Text = StatusText(SetupStepId.NotesFolder);
        }

        body.Children.Add(path);
        body.Children.Add(UiKit.Row(
            UiKit.Button("Choose another folder…", () =>
            {
                var selected = controller.PickNotesFolder(this, path.Text, out var error);
                if (selected is not null) { path.Text = selected; Check(); }
                else if (error is not null) { result.Text = error; }
            }),
            UiKit.Button("Check again", Check, true)));
        body.Children.Add(result);
    }

    private static bool IsOneDrive(string folder) => folder.Contains("OneDrive", StringComparison.OrdinalIgnoreCase);

    private static bool IsProtectedFolder(string folder)
    {
        var documents = Platform.Shell.KnownFolders.Documents;
        return folder.StartsWith(documents, StringComparison.OrdinalIgnoreCase);
    }

    // Step 2.
    private void Shortcuts(StackPanel body)
    {
        body.Children.Add(UiKit.Text("All shortcuts must be registered, changed, or turned off by you.", 13, false, "TextPrimary", 8));
        ShortcutsPanel? panel = null;
        panel = new ShortcutsPanel(controller, () => { Evaluate(); });
        body.Children.Add(panel);
        void Evaluate()
        {
            if (!State.ConsentAnswered) { return; }
            if (panel!.AllResolved) { Mark(SetupStepId.Shortcuts, SetupStatus.Passed); }
            else { Mark(SetupStepId.Shortcuts, SetupStatus.Failed, $"{controller.ShortcutFailures.Count} shortcut(s) couldn't be registered. Change or turn them off."); }
            RenderList();
            status.Text = StatusText(SetupStepId.Shortcuts);
        }

        if (State.ConsentAnswered) { Evaluate(); }
        else { body.Children.Add(UiKit.Text("Answer step 0 first; shortcuts are registered after that.", 12, false, "Warning")); }
    }

    // Steps 3 and 4: the test only verifies; a capability never depends on it.
    private void CaptureTest(StackPanel body, SetupStepId id, CaptureTrigger trigger)
    {
        var action = trigger == CaptureTrigger.Selection ? HotkeyAction.CaptureSelection : HotkeyAction.CaptureArea;
        var binding = controller.BindingText(action);
        var result = UiKit.Text("Waiting for a capture…", 13, true);
        if (trigger == CaptureTrigger.Selection)
        {
            body.Children.Add(UiKit.Text($"Select the sample text below in another app (copy it into Notepad first), then press {binding}. {AppInfo.Name} can't capture from its own windows.", 13, false, "TextPrimary", 8));
            var sample = new TextBox { Text = "The quick brown fox jumps over the lazy dog.", IsReadOnly = true, Margin = new Thickness(0, 4, 0, 8) };
            body.Children.Add(sample);
            body.Children.Add(UiKit.Secondary("Apps running as administrator can't be read; use Capture Area for those. The clipboard fallback is " +
                (controller.Settings.ClipboardFallback == true ? "on." : "off, so apps that don't share their selection will report no text.")));
        }
        else
        {
            body.Children.Add(UiKit.Text($"Press {binding}, then drag a rectangle over some text on screen. The image is saved and OCR reads it.", 13, false, "TextPrimary", 8));
        }

        body.Children.Add(result);
        void Observed(CaptureTrigger seen, string detail, bool text)
        {
            if (seen != trigger) { return; }
            dispatcherInvoke(() =>
            {
                if (trigger == CaptureTrigger.Region && !text)
                {
                    result.Text = "The area was captured, but OCR found no text. Try a region with clear text, or check the OCR models.";
                    return;
                }

                result.Text = $"Captured ({detail}).";
                Mark(id, SetupStatus.Passed, detail);
                RenderList();
                status.Text = StatusText(id);
            });
        }

        controller.CaptureObserved += Observed;
        detach = () => controller.CaptureObserved -= Observed;
        if (State.Status(id) == SetupStatus.Passed) { result.Text = "Passed earlier. Run it again any time."; }
        if (!State.ConsentAnswered) { body.Children.Add(UiKit.Text("Answer step 0 first.", 12, false, "Warning")); }
        body.Children.Add(UiKit.Row(UiKit.Button("Check again", () => Go(current)), SkipButton(id)));
    }

    private void dispatcherInvoke(Action action) => Dispatcher.BeginInvoke(action);

    // Step 5.
    private void TrayIcon(StackPanel body)
    {
        body.Children.Add(UiKit.Text("The tray icon is how you reach the menu, Setup and Settings.", 13, false, "TextPrimary", 8));
        body.Children.Add(UiKit.Text("Windows 11 may hide new icons in the overflow. Open Settings → Personalization → Taskbar → Other system tray icons and turn on " + AppInfo.Name + ", or drag the icon from the ^ overflow onto the taskbar.", 13, false, "TextPrimary", 8));
        body.Children.Add(UiKit.Row(UiKit.Button("I can see the icon", () => Finish(SetupStepId.TrayIcon, SetupStatus.Passed), true), SkipButton(SetupStepId.TrayIcon)));
    }

    // Step 6.
    private void StartAtLogin(StackPanel body)
    {
        body.Children.Add(UiKit.Text($"Start {AppInfo.Name} when you sign in, so the shortcuts are always ready. You can also manage this in Windows Settings → Apps → Startup.", 13, false, "TextPrimary", 8));
        var toggle = UiKit.Check("Start at login", controller.Settings.StartAtLogin ?? true);
        body.Children.Add(toggle);
        var message = UiKit.Text("", 12, false, "Warning");
        body.Children.Add(message);
        body.Children.Add(UiKit.Row(UiKit.Button("Apply", () =>
        {
            try
            {
                if (!controller.ApplyStartAtLogin(toggle.IsChecked == true))
                {
                    toggle.IsChecked = controller.Settings.StartAtLogin ?? true;
                    return;
                }

                Finish(SetupStepId.StartAtLogin, SetupStatus.Passed, toggle.IsChecked == true ? null : "Off by choice");
            }
            catch (Exception error) when (error is InvalidOperationException or UnauthorizedAccessException or System.Security.SecurityException or ArgumentException)
            {
                Mark(SetupStepId.StartAtLogin, SetupStatus.Failed, $"Couldn't write the Run key: {error.Message}");
                Go(current);
            }
        }, true), SkipButton(SetupStepId.StartAtLogin)));
    }

    // Step 7.
    private void Updates(StackPanel body)
    {
        body.Children.Add(UiKit.Text("Review how updates are checked. Updates come from github.com and are verified before they are installed.", 13, false, "TextPrimary", 8));
        var auto = UiKit.Radio("Check for updates automatically (daily)", "updates7", controller.Settings.UpdatesChoice != UpdatesChoice.Manual);
        var manual = UiKit.Radio("Only when I ask", "updates7", controller.Settings.UpdatesChoice == UpdatesChoice.Manual);
        body.Children.Add(auto);
        body.Children.Add(manual);
        body.Children.Add(UiKit.Row(UiKit.Button("Looks good", () =>
        {
            if (!controller.ApplyUpdatesChoice(auto.IsChecked == true ? UpdatesChoice.Auto : UpdatesChoice.Manual))
            {
                auto.IsChecked = controller.Settings.UpdatesChoice != UpdatesChoice.Manual;
                manual.IsChecked = controller.Settings.UpdatesChoice == UpdatesChoice.Manual;
                return;
            }

            Finish(SetupStepId.Updates, SetupStatus.Passed);
        }, true), SkipButton(SetupStepId.Updates)));
    }

    // Step 8.
    private void Semantic(StackPanel body)
    {
        body.Children.Add(UiKit.Text("Semantic search finds notes by meaning as well as keywords. It is optional and nothing is downloaded here.", 13, false, "TextPrimary", 8));
        body.Children.Add(UiKit.Text($"To turn it on later, open the tray icon and choose Enable Semantic Search… It downloads about {ModelInstallException.FormatBytes(ModelManifest.Current.TotalDownloadBytes)} from huggingface.co.", 13, false, "TextPrimary", 8));
        var gotIt = UiKit.Button("Got it", () => Finish(SetupStepId.Semantic, SetupStatus.Passed), true);
        gotIt.IsDefault = false;
        body.Children.Add(UiKit.Row(gotIt, SkipButton(SetupStepId.Semantic)));
    }

    internal void RefreshSetupPalette()
    {
        if (SystemParameters.HighContrast)
        {
            Resources["SetupPrimaryFill"] = SystemColors.HighlightBrush;
            Resources["SetupPrimaryText"] = SystemColors.HighlightTextBrush;
            Resources["SetupPrimaryHoverFill"] = SystemColors.HighlightBrush;
            Resources["SetupPrimaryPressedFill"] = SystemColors.HighlightBrush;
            Resources["SetupPrimaryPressedBorder"] = SystemColors.HighlightBrush;
            Resources["SetupSelectionFill"] = SystemColors.HighlightBrush;
            Resources["SetupSelectionText"] = SystemColors.HighlightTextBrush;
            Resources["SetupSelectionSecondary"] = SystemColors.HighlightTextBrush;
            Resources["SetupSelectionAccent"] = SystemColors.HighlightTextBrush;
            Resources["SetupFocusBrush"] = SystemColors.HighlightBrush;
            return;
        }

        var accent = TryFindResource("BrandAccent") as SolidColorBrush;
        var accentColor = accent?.Color ?? Color.FromRgb(0xE5, 0x48, 0x3C);
        Resources["SetupPrimaryFill"] = accent ?? new SolidColorBrush(accentColor);
        Resources["SetupPrimaryText"] = Brush(Color.FromRgb(0x16, 0x06, 0x05));
        Resources["SetupPrimaryHoverFill"] = Brush(Shade(accentColor, 1.06));
        Resources["SetupPrimaryPressedFill"] = accent ?? new SolidColorBrush(accentColor);
        Resources["SetupPrimaryPressedBorder"] = Brush(Shade(accentColor, 0.72));
        Resources["SetupSelectionFill"] = Brush(Color.FromArgb(0x25, accentColor.R, accentColor.G, accentColor.B));
        Resources["SetupSelectionText"] = TryFindResource("TextPrimary") as Brush ?? SystemColors.ControlTextBrush;
        Resources["SetupSelectionSecondary"] = TryFindResource("Secondary") as Brush ?? SystemColors.GrayTextBrush;
        Resources["SetupSelectionAccent"] = accent ?? new SolidColorBrush(accentColor);
        Resources["SetupFocusBrush"] = accent ?? new SolidColorBrush(accentColor);
    }

    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e) => QueuePaletteRefresh();

    private void OnSystemParametersChanged(object? sender, PropertyChangedEventArgs e) => QueuePaletteRefresh();

    private void QueuePaletteRefresh()
    {
        if (closed || Dispatcher.HasShutdownStarted || Dispatcher.HasShutdownFinished) { return; }
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (!closed) { RefreshSetupPalette(); }
        }));
    }

    private static Brush Brush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private static Color Shade(Color color, double factor) => Color.FromRgb(
        (byte)Math.Clamp((int)Math.Round(color.R * factor), 0, 255),
        (byte)Math.Clamp((int)Math.Round(color.G * factor), 0, 255),
        (byte)Math.Clamp((int)Math.Round(color.B * factor), 0, 255));

    private static DynamicResourceExtension Resource(string key) => new(key);

    private static Binding TemplateBindingFor(string path) => new(path)
    {
        RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent)
    };

    private static Style CreateButtonStyle(bool primary, bool promoteDefault)
    {
        var style = new Style(typeof(Button));
        style.Setters.Add(new Setter(Control.BackgroundProperty, Resource(primary ? "SetupPrimaryFill" : "Transparent")));
        style.Setters.Add(new Setter(Control.ForegroundProperty, Resource(primary ? "SetupPrimaryText" : "TextPrimary")));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, Resource(primary ? "SetupPrimaryFill" : "SurfaceBorder")));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(primary ? 0 : 1)));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(15, 8, 15, 8)));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 38d));
        style.Setters.Add(new Setter(Control.TemplateProperty, ButtonTemplate()));

        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Control.BackgroundProperty, Resource(primary ? "SetupPrimaryHoverFill" : "HintFill")));
        style.Triggers.Add(hover);
        var pressed = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
        pressed.Setters.Add(new Setter(Control.BackgroundProperty, Resource(primary ? "SetupPrimaryPressedFill" : "QuickButtonPressedFill")));
        if (primary)
        {
            pressed.Setters.Add(new Setter(Control.BorderBrushProperty, Resource("SetupPrimaryPressedBorder")));
            pressed.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(2)));
        }
        style.Triggers.Add(pressed);

        if (!primary && promoteDefault)
        {
            var defaultButton = new Trigger { Property = Button.IsDefaultProperty, Value = true };
            defaultButton.Setters.Add(new Setter(Control.BackgroundProperty, Resource("SetupPrimaryFill")));
            defaultButton.Setters.Add(new Setter(Control.ForegroundProperty, Resource("SetupPrimaryText")));
            defaultButton.Setters.Add(new Setter(Control.BorderBrushProperty, Resource("SetupPrimaryFill")));
            style.Triggers.Add(defaultButton);

            var defaultHover = new MultiTrigger();
            defaultHover.Conditions.Add(new System.Windows.Condition(UIElement.IsMouseOverProperty, true));
            defaultHover.Conditions.Add(new System.Windows.Condition(Button.IsDefaultProperty, true));
            defaultHover.Setters.Add(new Setter(Control.BackgroundProperty, Resource("SetupPrimaryHoverFill")));
            style.Triggers.Add(defaultHover);

            var defaultPressed = new MultiTrigger();
            defaultPressed.Conditions.Add(new System.Windows.Condition(ButtonBase.IsPressedProperty, true));
            defaultPressed.Conditions.Add(new System.Windows.Condition(Button.IsDefaultProperty, true));
            defaultPressed.Setters.Add(new Setter(Control.BackgroundProperty, Resource("SetupPrimaryPressedFill")));
            defaultPressed.Setters.Add(new Setter(Control.BorderBrushProperty, Resource("SetupPrimaryPressedBorder")));
            defaultPressed.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(2)));
            style.Triggers.Add(defaultPressed);
        }

        var focused = new Trigger { Property = UIElement.IsKeyboardFocusedProperty, Value = true };
        focused.Setters.Add(new Setter(Control.BorderBrushProperty, Resource("SetupFocusBrush")));
        focused.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(2)));
        style.Triggers.Add(focused);
        var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.55));
        style.Triggers.Add(disabled);
        return style;
    }

    private static ControlTemplate ButtonTemplate()
    {
        var template = new ControlTemplate(typeof(Button));
        var chrome = new FrameworkElementFactory(typeof(Border), "ButtonChrome");
        chrome.SetValue(Border.CornerRadiusProperty, new CornerRadius(9));
        chrome.SetBinding(Border.BackgroundProperty, TemplateBindingFor(nameof(Control.Background)));
        chrome.SetBinding(Border.BorderBrushProperty, TemplateBindingFor(nameof(Control.BorderBrush)));
        chrome.SetBinding(Border.BorderThicknessProperty, TemplateBindingFor(nameof(Control.BorderThickness)));

        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.ContentSourceProperty, "Content");
        content.SetValue(ContentPresenter.RecognizesAccessKeyProperty, true);
        content.SetBinding(FrameworkElement.MarginProperty, TemplateBindingFor(nameof(Control.Padding)));
        content.SetBinding(FrameworkElement.HorizontalAlignmentProperty, TemplateBindingFor(nameof(Control.HorizontalContentAlignment)));
        content.SetBinding(FrameworkElement.VerticalAlignmentProperty, TemplateBindingFor(nameof(Control.VerticalContentAlignment)));
        chrome.AppendChild(content);
        template.VisualTree = chrome;
        return template;
    }

    private static Style CreateChoiceStyle(bool radio)
    {
        var style = new Style(radio ? typeof(RadioButton) : typeof(CheckBox));
        style.Setters.Add(new Setter(Control.ForegroundProperty, Resource("TextPrimary")));
        style.Setters.Add(new Setter(Control.BackgroundProperty, Resource("Transparent")));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, Resource("Transparent")));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(5, 4, 5, 4)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Left));
        style.Setters.Add(new Setter(Control.VerticalContentAlignmentProperty, VerticalAlignment.Center));
        style.Setters.Add(new Setter(Control.TemplateProperty, ChoiceTemplate(radio)));
        return style;
    }

    private static ControlTemplate ChoiceTemplate(bool radio)
    {
        var owner = radio ? typeof(RadioButton) : typeof(CheckBox);
        var template = new ControlTemplate(owner);
        var chrome = new FrameworkElementFactory(typeof(Border), "ChoiceChrome");
        chrome.SetValue(Border.CornerRadiusProperty, new CornerRadius(7));
        chrome.SetBinding(Border.BackgroundProperty, TemplateBindingFor(nameof(Control.Background)));
        chrome.SetBinding(Border.BorderBrushProperty, TemplateBindingFor(nameof(Control.BorderBrush)));
        chrome.SetBinding(Border.BorderThicknessProperty, TemplateBindingFor(nameof(Control.BorderThickness)));
        chrome.SetBinding(Border.PaddingProperty, TemplateBindingFor(nameof(Control.Padding)));

        var row = new FrameworkElementFactory(typeof(StackPanel));
        row.SetValue(StackPanel.OrientationProperty, Orientation.Horizontal);
        row.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        FrameworkElementFactory indicator;
        if (radio)
        {
            var radioGrid = new FrameworkElementFactory(typeof(Grid), "ChoiceIndicator");
            radioGrid.SetValue(FrameworkElement.WidthProperty, 18d);
            radioGrid.SetValue(FrameworkElement.HeightProperty, 18d);
            radioGrid.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 0, 9, 0));
            var ring = new FrameworkElementFactory(typeof(Ellipse), "ChoiceRing");
            ring.SetResourceReference(Shape.StrokeProperty, "Secondary");
            ring.SetResourceReference(Shape.FillProperty, "Transparent");
            ring.SetValue(Shape.StrokeThicknessProperty, 1.5d);
            var dot = new FrameworkElementFactory(typeof(Ellipse), "ChoiceDot");
            dot.SetValue(FrameworkElement.WidthProperty, 8d);
            dot.SetValue(FrameworkElement.HeightProperty, 8d);
            dot.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
            dot.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
            dot.SetValue(UIElement.VisibilityProperty, Visibility.Collapsed);
            dot.SetResourceReference(Shape.FillProperty, "SetupPrimaryFill");
            radioGrid.AppendChild(ring);
            radioGrid.AppendChild(dot);
            indicator = radioGrid;
        }
        else
        {
            var checkGrid = new FrameworkElementFactory(typeof(Grid), "ChoiceIndicator");
            checkGrid.SetValue(FrameworkElement.WidthProperty, 18d);
            checkGrid.SetValue(FrameworkElement.HeightProperty, 18d);
            checkGrid.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 0, 9, 0));
            var box = new FrameworkElementFactory(typeof(Border), "ChoiceBox");
            box.SetValue(Border.CornerRadiusProperty, new CornerRadius(4));
            box.SetResourceReference(Border.BackgroundProperty, "Transparent");
            box.SetResourceReference(Border.BorderBrushProperty, "Secondary");
            box.SetValue(Border.BorderThicknessProperty, new Thickness(1.5));
            var mark = new FrameworkElementFactory(typeof(TextBlock), "ChoiceMark");
            mark.SetValue(TextBlock.TextProperty, "✓");
            mark.SetValue(TextBlock.FontFamilyProperty, new FontFamily("Segoe UI Symbol, Segoe UI"));
            mark.SetValue(TextBlock.FontSizeProperty, 12d);
            mark.SetValue(TextBlock.FontWeightProperty, FontWeights.Bold);
            mark.SetValue(TextBlock.HorizontalAlignmentProperty, HorizontalAlignment.Center);
            mark.SetValue(TextBlock.VerticalAlignmentProperty, VerticalAlignment.Center);
            mark.SetValue(UIElement.VisibilityProperty, Visibility.Collapsed);
            mark.SetResourceReference(TextBlock.ForegroundProperty, "SetupPrimaryText");
            checkGrid.AppendChild(box);
            checkGrid.AppendChild(mark);
            indicator = checkGrid;
        }

        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.ContentSourceProperty, "Content");
        content.SetValue(ContentPresenter.RecognizesAccessKeyProperty, true);
        content.SetBinding(FrameworkElement.HorizontalAlignmentProperty, TemplateBindingFor(nameof(Control.HorizontalContentAlignment)));
        content.SetBinding(FrameworkElement.VerticalAlignmentProperty, TemplateBindingFor(nameof(Control.VerticalContentAlignment)));
        row.AppendChild(indicator);
        row.AppendChild(content);
        chrome.AppendChild(row);
        template.VisualTree = chrome;

        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty, Resource("HintFill"), "ChoiceChrome"));
        template.Triggers.Add(hover);
        var focused = new Trigger { Property = UIElement.IsKeyboardFocusedProperty, Value = true };
        focused.Setters.Add(new Setter(Border.BorderBrushProperty, Resource("SetupFocusBrush"), "ChoiceChrome"));
        focused.Setters.Add(new Setter(Border.BorderThicknessProperty, new Thickness(2), "ChoiceChrome"));
        template.Triggers.Add(focused);
        var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.55, "ChoiceChrome"));
        template.Triggers.Add(disabled);

        var checkedTrigger = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
        if (radio)
        {
            checkedTrigger.Setters.Add(new Setter(UIElement.VisibilityProperty, Visibility.Visible, "ChoiceDot"));
            checkedTrigger.Setters.Add(new Setter(Shape.StrokeProperty, Resource("SetupPrimaryFill"), "ChoiceRing"));
        }
        else
        {
            checkedTrigger.Setters.Add(new Setter(Border.BackgroundProperty, Resource("SetupPrimaryFill"), "ChoiceBox"));
            checkedTrigger.Setters.Add(new Setter(Border.BorderBrushProperty, Resource("SetupPrimaryFill"), "ChoiceBox"));
            checkedTrigger.Setters.Add(new Setter(UIElement.VisibilityProperty, Visibility.Visible, "ChoiceMark"));
        }
        template.Triggers.Add(checkedTrigger);
        return template;
    }
}
