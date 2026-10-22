using System.IO;
using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CaptureApp.App;
using CaptureApp.Overlay;
using Xunit;
using Ellipse = System.Windows.Shapes.Ellipse;

namespace CaptureApp.App.Tests;

public sealed class SetupWindowTests
{
    [Fact]
    public void NavigationHasVisibleEndpointsAndUsesTheQuickNoteFeatureName()
    {
        OnSta(() =>
        {
            var directory = Path.Combine(Path.GetTempPath(), "focusnotes-setup-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            using var theme = new ThemeManager(app.Resources);
            var controller = new AppController(app, directory, firstRun: false);
            var window = new SetupWindow(controller, manual: true);
            try
            {
                var root = (DependencyObject)window.Content;
                var back = FindButton(root, "setup-back");
                var next = FindButton(root, "setup-next");
                var close = FindButton(root, "setup-close");
                Assert.Equal(Visibility.Collapsed, back.Visibility);
                Assert.Equal(Visibility.Visible, next.Visibility);
                Assert.Equal(Visibility.Visible, close.Visibility);
                Assert.False(close.IsDefault);
                Assert.False(next.IsDefault);
                Assert.Contains(Texts(root), text => text.StartsWith("STEP 1 OF 9", StringComparison.Ordinal));

                Click(next);
                Click(next);
                Assert.Contains("Quick Note", Texts(root));
                Assert.DoesNotContain("Write a Note", Texts(root));

                NavigateToLastStep(next);
                Assert.Contains(Texts(root), text => text.StartsWith("STEP 9 OF 9", StringComparison.Ordinal));
                Assert.Equal(Visibility.Visible, back.Visibility);
                Assert.Equal(Visibility.Collapsed, next.Visibility);
                Assert.Equal(Visibility.Visible, close.Visibility);
                Assert.True(close.IsDefault);
                Assert.False(next.IsDefault);
                Assert.Equal(0, close.Margin.Right);
                SessionPickerChecks.Run(app);
                WiringTests.OutsideCaptureEscapeUsesTitlePickerCancellation(app);
                NotesFolderChecks.Run(app);

                var gallery = Environment.GetEnvironmentVariable("FOCUSNOTES_SETUP_GALLERY_OUT");
                if (!string.IsNullOrWhiteSpace(gallery))
                {
                    Directory.CreateDirectory(gallery);
                    foreach (var dark in new[] { false, true })
                    {
                        theme.Apply(dark, highContrast: false);
                        window.RefreshSetupPalette();
                        NavigateToFirstStep(back);
                        Render(root, window.Width, window.Height - 32, Path.Combine(gallery, $"setup-first-{(dark ? "dark" : "light")}.png"));
                        var radios = CheckDisclosureChoices(root);
                        Render(root, window.Width, window.Height - 32, Path.Combine(gallery, $"setup-choices-{(dark ? "dark" : "light")}.png"));
                        AssertCenteredRadioIndicators(radios);

                        NavigateForward(next, 6);
                        var startAtLogin = Descendants(root).OfType<CheckBox>().Single();
                        startAtLogin.IsChecked = true;
                        Render(root, window.Width, window.Height - 32, Path.Combine(gallery, $"setup-checkbox-{(dark ? "dark" : "light")}.png"));
                        AssertCheckedCheckbox(startAtLogin);

                        NavigateToLastStep(next);
                        Render(root, window.Width, window.Height - 32, Path.Combine(gallery, $"setup-last-{(dark ? "dark" : "light")}.png"));
                    }
                }
            }
            finally
            {
                window.Close();
                controller.Dispose();
                app.Shutdown();
                Directory.Delete(directory, recursive: true);
            }
        });
    }

    private static void NavigateToFirstStep(Button back)
    {
        for (var i = 0; back.Visibility == Visibility.Visible && i < 10; i++) { Click(back); }
        Assert.Equal(Visibility.Collapsed, back.Visibility);
    }

    private static void NavigateToLastStep(Button next)
    {
        for (var i = 0; next.Visibility == Visibility.Visible && i < 10; i++) { Click(next); }
        Assert.Equal(Visibility.Collapsed, next.Visibility);
    }

    private static void NavigateForward(Button next, int count)
    {
        for (var i = 0; i < count; i++)
        {
            Assert.Equal(Visibility.Visible, next.Visibility);
            Click(next);
        }
    }

    private static RadioButton[] CheckDisclosureChoices(DependencyObject root)
    {
        var radios = Descendants(root).OfType<RadioButton>().ToArray();
        Assert.Equal(4, radios.Length);
        radios[0].IsChecked = true;
        radios[2].IsChecked = true;
        return radios.Where(radio => radio.IsChecked == true).ToArray();
    }

    private static void AssertCenteredRadioIndicators(IEnumerable<RadioButton> radios)
    {
        foreach (var radio in radios)
        {
            radio.ApplyTemplate();
            var indicator = Assert.IsType<Grid>(radio.Template.FindName("ChoiceIndicator", radio));
            var dot = Assert.IsType<Ellipse>(radio.Template.FindName("ChoiceDot", radio));
            Assert.Equal(Visibility.Visible, dot.Visibility);
            var center = dot.TranslatePoint(new Point(dot.ActualWidth / 2, dot.ActualHeight / 2), indicator);
            Assert.InRange(Math.Abs(center.X - indicator.ActualWidth / 2), 0, 0.5);
            Assert.InRange(Math.Abs(center.Y - indicator.ActualHeight / 2), 0, 0.5);
        }
    }

    private static void AssertCheckedCheckbox(CheckBox checkBox)
    {
        checkBox.ApplyTemplate();
        var box = Assert.IsType<Border>(checkBox.Template.FindName("ChoiceBox", checkBox));
        var mark = Assert.IsType<TextBlock>(checkBox.Template.FindName("ChoiceMark", checkBox));
        Assert.Equal(Visibility.Visible, mark.Visibility);
        Assert.True(box.ActualWidth > 0 && box.ActualHeight > 0);
    }

    private static void Render(DependencyObject root, double width, double height, string path)
    {
        var visual = (FrameworkElement)root;
        VisualTreeHelper.SetRootDpi(visual, new DpiScale(1, 1));
        visual.Measure(new Size(width, height));
        visual.Arrange(new Rect(0, 0, width, height));
        visual.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(width), (int)Math.Ceiling(height), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = File.Create(path);
        encoder.Save(output);
    }

    private static Button FindButton(DependencyObject root, string id) => Descendants(root)
        .OfType<Button>()
        .Single(button => AutomationProperties.GetAutomationId(button) == id);

    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

    private static string[] Texts(DependencyObject root) => Descendants(root)
        .OfType<TextBlock>()
        .Select(block => block.Text)
        .ToArray();

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            foreach (var descendant in Descendants(child)) { yield return descendant; }
        }
    }

    private static void OnSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { action(); }
            catch (Exception error) { failure = error; }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "Setup UI test dispatcher did not finish within 30 seconds.");
        if (failure is not null) { ExceptionDispatchInfo.Capture(failure).Throw(); }
    }
}
