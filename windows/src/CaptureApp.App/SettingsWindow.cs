using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;

namespace CaptureApp.App;

/// Settings: Shortcuts, General and Updates. Shortcut changes re-register live.
internal sealed class SettingsWindow : Window
{
    private readonly AppController controller;
    private readonly TabControl tabs = new() { Margin = new Thickness(12) };

    public SettingsWindow(AppController controller, int tab)
    {
        this.controller = controller;
        Title = $"{AppInfo.Name} Settings";
        Width = 760;
        Height = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        UiKit.Themed(this);
        tabs.Items.Add(new TabItem { Header = "Shortcuts", Content = Scroll(ShortcutsTab()) });
        tabs.Items.Add(new TabItem { Header = "General", Content = Scroll(GeneralTab()) });
        tabs.Items.Add(new TabItem { Header = "Updates", Content = Scroll(UpdatesTab()) });
        Content = tabs;
        SelectTab(tab);
    }

    public void SelectTab(int index) => tabs.SelectedIndex = Math.Clamp(index, 0, tabs.Items.Count - 1);

    private static ScrollViewer Scroll(UIElement content) => new() { Content = content, Padding = new Thickness(16) };

    private StackPanel ShortcutsTab()
    {
        var panel = new StackPanel();
        panel.Children.Add(UiKit.Text("Click Change… and press the new combination. It is checked against Windows and your keyboard layouts before it is saved.", 13, false, "TextPrimary", 10));
        panel.Children.Add(new ShortcutsPanel(controller, controller.OnSetupChanged));
        return panel;
    }

    private StackPanel GeneralTab()
    {
        var panel = new StackPanel();
        var login = UiKit.Check("Start at login", controller.Settings.StartAtLogin ?? controller.LoginItem.IsEnabled);
        var loginMessage = UiKit.Text("", 12, false, "Warning");
        login.Click += (_, _) =>
        {
            try
            {
                loginMessage.Text = "";
                if (!controller.ApplyStartAtLogin(login.IsChecked == true)) { login.IsChecked = controller.LoginItem.IsEnabled; }
            }
            catch (Exception error) when (error is InvalidOperationException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                loginMessage.Text = $"Couldn't update start at login: {error.Message}";
                login.IsChecked = controller.LoginItem.IsEnabled;
            }
        };
        panel.Children.Add(login);
        panel.Children.Add(loginMessage);
        panel.Children.Add(UiKit.Rule());

        var fallback = UiKit.Check("Use the clipboard fallback for Capture Selection", controller.Settings.ClipboardFallback == true);
        fallback.Click += (_, _) =>
        {
            if (!controller.ApplyClipboardFallback(fallback.IsChecked == true)) { fallback.IsChecked = controller.Settings.ClipboardFallback == true; }
        };
        panel.Children.Add(fallback);
        panel.Children.Add(UiKit.Secondary("When an app doesn't share its selection, the fallback briefly sends Ctrl+C to it and then restores your clipboard. The app's own copy may appear in Windows clipboard history."));
        panel.Children.Add(UiKit.Rule());

        panel.Children.Add(UiKit.Text("Notes folder", 13, true));
        var folder = new TextBox { Text = controller.CurrentNotesFolder, MinWidth = 380, Margin = new Thickness(0, 4, 8, 4) };
        var folderMessage = UiKit.Secondary(controller.NotesFolderNeedsRestart
            ? controller.NotesFolderChangeMessage
            : "Changes are applied on restart. Existing notes stay in their current folder.");
        void Apply()
        {
            var value = folder.Text.Trim();
            if (!controller.SaveNotesFolder(value, out var error)) { folderMessage.Text = error; return; }
            folder.Text = controller.CurrentNotesFolder;
            folderMessage.Text = controller.NotesFolderChangeMessage;
        }

        panel.Children.Add(folder);
        panel.Children.Add(UiKit.Row(
            UiKit.Button("Choose…", () =>
            {
                var selected = controller.PickNotesFolder(this, folder.Text, out var error);
                if (selected is not null) { folder.Text = selected; Apply(); }
                else if (error is not null) { folderMessage.Text = error; }
            }),
            UiKit.Button("Save", Apply)));
        panel.Children.Add(folderMessage);
        return panel;
    }

    private StackPanel UpdatesTab()
    {
        var panel = new StackPanel();
        var auto = UiKit.Radio("Check for updates automatically (daily)", "settingsUpdates", controller.Settings.UpdatesChoice != UpdatesChoice.Manual);
        var manual = UiKit.Radio("Only when I ask", "settingsUpdates", controller.Settings.UpdatesChoice == UpdatesChoice.Manual);
        var message = UiKit.Secondary(controller.Settings.UpdatesChoice is null ? "Choose an option in Setup to confirm it." : "Automatic checks take effect on the next launch.");
        void Choose(UpdatesChoice choice)
        {
            if (controller.ApplyUpdatesChoice(choice)) { return; }
            // Show the value that is actually saved.
            auto.IsChecked = controller.Settings.UpdatesChoice != UpdatesChoice.Manual;
            manual.IsChecked = controller.Settings.UpdatesChoice == UpdatesChoice.Manual;
        }

        auto.Click += (_, _) => Choose(UpdatesChoice.Auto);
        manual.Click += (_, _) => Choose(UpdatesChoice.Manual);
        panel.Children.Add(auto);
        panel.Children.Add(manual);
        panel.Children.Add(message);
        panel.Children.Add(UiKit.Row(UiKit.Button("Check now", () =>
        {
            if (controller.UpdateService is not { IsEnabled: true }) { message.Text = "Updates aren't available in this install."; return; }
            controller.CheckForUpdates();
            message.Text = "Checking… the result appears as a notification.";
        })));
        panel.Children.Add(UiKit.Rule());
        var channel = "win-" + RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
        panel.Children.Add(UiKit.Text($"Version {AppInfo.Version} · channel {channel}", 13));
        return panel;
    }
}
