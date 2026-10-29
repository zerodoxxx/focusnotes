using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CaptureApp.Overlay;
using ICSharpCode.AvalonEdit.Rendering;

namespace CaptureApp.Gallery;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(app.Dispatcher));
        using var theme = new ThemeManager(app.Resources);
        var exitCode = 0;
        app.Dispatcher.InvokeAsync(async () =>
        {
            try
            {
                if (args is ["--check", var directory])
                {
                    await Check(directory, theme);
                    app.Shutdown();
                }
                else if (args is ["--live", var component]) Live(component, app);
                else throw new ArgumentException("Usage: CaptureApp.Gallery --check <outdir> | --live <toast|success|warning|session|copied|search|input|subheading|session-picker|editor>");
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine(exception); exitCode = 1;
                if (args is ["--check", var directory])
                {
                    Directory.CreateDirectory(directory);
                    await File.WriteAllTextAsync(Path.Combine(directory, "failure.txt"), exception.ToString());
                }
                app.Shutdown(1);
            }
        });
        app.Run();
        return exitCode;
    }
    private static async Task Check(string directory, ThemeManager theme)
    {
        Directory.CreateDirectory(directory);
        CheckGeometry();
        CheckTaskEditing();
        CheckQuickNoteSaveActions();
        CheckFolderQuickNote();
        var files = new List<string>();
        foreach (var dark in new[] { false, true })
        {
            theme.Apply(dark, false);
            foreach (var scale in new[] { Tokens.One, 1.5, (double)Tokens.GalleryScale })
            {
                foreach (var fixture in Fixtures.All())
                {
                    var surface = fixture.Create();
                    try
                    {
                        if (surface is SearchPanelView search) await search.WaitForThumbnailsAsync();
                        var root = OverlaySurface.Frame(surface);
                        VisualTreeHelper.SetRootDpi(root, new DpiScale(scale, scale));
                        var size = new Size(surface.Width + Tokens.ShadowMargin * 2, surface.Height + Tokens.ShadowMargin * 2);
                        root.Measure(size); root.Arrange(new Rect(size)); root.UpdateLayout();
                        // Flush layout callbacks, including the absolute result-row layout, without creating an HWND.
                        await root.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Loaded);
                        root.UpdateLayout();
                        Require(Math.Abs(surface.Width - fixture.Width) < Tokens.LayoutTolerance, fixture.Name + ": visible width");
                        Require(Math.Abs(surface.Height - fixture.Height) < Tokens.LayoutTolerance, fixture.Name + ": visible height");
                        CheckLayout(root, fixture.Name);
                        fixture.Verify?.Invoke(surface);
                        if (surface is QuickNoteView quickNote) CheckQuickNotePalette(quickNote);
                        var name = $"{fixture.Name}-{(dark ? "dark" : "light")}-{scale.ToString("0.##", CultureInfo.InvariantCulture)}x.png";
                        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(size.Width * scale), (int)Math.Ceiling(size.Height * scale), Tokens.RenderDpi * scale, Tokens.RenderDpi * scale, PixelFormats.Pbgra32);
                        bitmap.Render(root);
                        if (fixture.Name is "quick-caret-preview" or "quick-tasks-caret" or "quick-tasks-checked-caret" && surface is QuickNoteView renderedQuickNote)
                            CheckCheckboxRasterBounds(renderedQuickNote, root, bitmap, scale, fixture.Name);
                        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                        using (var output = File.Create(Path.Combine(directory, name))) encoder.Save(output);
                        Require(bitmap.PixelWidth == (int)Math.Ceiling(size.Width * scale) && bitmap.PixelHeight == (int)Math.Ceiling(size.Height * scale), name + ": bitmap scale");
                        files.Add(name);
                    }
                    finally { (surface as IDisposable)?.Dispose(); }
                }
            }
        }
        theme.Apply(false, true);
        var highContrast = new SearchPanelView();
        var hcRoot = OverlaySurface.Frame(highContrast);
        hcRoot.Measure(new Size(hcRoot.Width, hcRoot.Height)); hcRoot.Arrange(new Rect(new Size(hcRoot.Width, hcRoot.Height))); hcRoot.UpdateLayout();
        Require(Equals(highContrast.FindResource("SurfaceTint"), SystemColors.WindowBrush), "High contrast uses system surface");
        Require(highContrast.TryFindResource("SurfaceShadow") is null, "High contrast disables shadow");
        highContrast.Dispose();
        theme.Apply(false, false);
        await File.WriteAllLinesAsync(Path.Combine(directory, "states.txt"), files);
        CheckQuickNoteHighContrast();
        await File.WriteAllTextAsync(Path.Combine(directory, "checks.txt"), $"PASS: {files.Count} PNGs; token geometry, 100%/150%/200% raster size, dark Quick Note palette, typed-note append hints/save escape/destination precedence, active-task typing/toggle/selection/undo/list keys, caret/checkbox alignment, text DesiredSize/bounds, high contrast, and position round trips. No windows created.\nFocus integration gates require the Windows UI harness (§3b-2).\n");
        Console.WriteLine($"Gallery passed: {files.Count} PNGs in {directory}");
    }
    private static void CheckQuickNotePalette(QuickNoteView view)
    {
        Require(view.FindResource("SurfaceTint") is SolidColorBrush { Color: { A: 0xF7, R: 0x16, G: 0x16, B: 0x16 } }, "Quick Note keeps its dark surface when the app theme is light");
        Require(view.FindResource("TextPrimary") is SolidColorBrush { Color: { A: 0xFF, R: 0xFF, G: 0xFF, B: 0xFF } }, "Quick Note keeps light foreground text in its dark theme");
        Require(view.FindResource("Tertiary") is SolidColorBrush { Color: { A: 0x87, R: 0xFF, G: 0xFF, B: 0xFF } }, "Quick Note secondary metadata uses its dark-theme foreground");
    }
    private static void CheckTaskEditing()
    {
        using var editor = new MarkdownEditor { Width = 440, Height = 240 };
        var source = new GalleryInputSource { RootVisual = editor };
        void Layout()
        {
            editor.Measure(new Size(editor.Width, editor.Height));
            editor.Arrange(new Rect(0, 0, editor.Width, editor.Height));
            editor.UpdateLayout();
            editor.Inner.TextArea.TextView.EnsureVisualLines();
        }
        void Press(Key key)
        {
            var input = new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, key) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
            editor.Inner.TextArea.RaiseEvent(input);
            Require(input.Handled, "active task: editor handles " + key);
            Layout();
        }

        editor.SetText("- [ ] first task\n- [ ] ");
        Layout();
        Require(editor.RenderedCheckboxes == 2, "active task: a newly entered marker renders before moving to another line");
        editor.Inner.TextArea.PerformTextInput("second task");
        Layout();
        Require(editor.Text == "- [ ] first task\n- [ ] second task" && editor.CaretOffset == editor.TextLength,
            "active task: typing edits the body and preserves Markdown storage and caret");
        Require(editor.RenderedCheckboxes == 2, "active task: typing keeps the current checkbox visible");

        var caret = editor.CaretOffset;
        var checkbox = editor.Inner.TextArea.TextView.VisualLines.Single(line => line.FirstDocumentLine.LineNumber == 2)
            .Elements.OfType<InlineObjectElement>().Single(element => element.DocumentLength > 0).Element;
        checkbox.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = UIElement.MouseLeftButtonDownEvent });
        Require(editor.Text == "- [ ] first task\n- [x] second task" && editor.CaretOffset == caret,
            "active task: clicking its checkbox toggles Markdown without moving the caret");
        Require(editor.Undo() && editor.Text == "- [ ] first task\n- [ ] second task", "active task: toggle is one undo step");
        Require(editor.Redo() && editor.Text == "- [ ] first task\n- [x] second task", "active task: toggle can be redone");

        editor.Select(editor.LineStart(2) + 6, 6);
        Layout();
        Require(editor.Inner.SelectedText == "second" && editor.RenderedCheckboxes == 2, "active task: selecting its text keeps both checkboxes visible");
        editor.Inner.TextArea.PerformTextInput("current");
        Require(editor.Text == "- [ ] first task\n- [x] current task", "active task: replacing a selection preserves its marker");
        editor.CaretOffset = editor.TextLength;
        Press(Key.Enter);
        Require(editor.Text == "- [ ] first task\n- [x] current task\n- [ ] " && editor.RenderedCheckboxes == 3,
            "active task: Enter continues a checked task as a visible unchecked task");
        Press(Key.Tab);
        Require(editor.Text.EndsWith("\n  - [ ] ", StringComparison.Ordinal) && editor.CaretOffset == editor.TextLength && editor.RenderedCheckboxes == 3,
            "active task: Tab indents the new task and preserves its caret and checkbox");
        Press(Key.Back);
        Require(editor.Text.EndsWith("\n  - ", StringComparison.Ordinal) && editor.RenderedCheckboxes == 2,
            "active task: Backspace at the body start removes the task marker and keeps the bullet");
    }
    private static void CheckQuickNoteSaveActions()
    {
        using var view = new QuickNoteView(null, false, "Trip planning\nBook the train", false)
        {
            ExistingTitleForText = text => text.StartsWith("Trip planning", StringComparison.Ordinal) ? "Trip planning" : null
        };
        var actions = new List<NoteActionId>();
        var saves = 0;
        view.ActionRequested += actions.Add;
        view.SaveRequested += () => saves++;
        string[] Texts() => LogicalDescendants(view).OfType<TextBlock>().Select(text => text.Text).ToArray();
        void CheckEscapeEnabled(bool enabled)
        {
            view.ShowActions();
            var button = LogicalDescendants(view).OfType<Button>()
                .Single(item => System.Windows.Automation.AutomationProperties.GetName(item) == "Save as New Note");
            Require(button.IsEnabled == enabled, "typed note: Save as New Note enabled state");
            view.HideActions();
        }

        Require(view.AppendsToExisting && Texts().Contains("Trip planning") && Texts().Contains("Add to note"),
            "typed note: a matching title shows its append destination and hint");
        CheckEscapeEnabled(true);
        view.Perform(NoteActionId.SaveAsNewNote);
        Require(actions.SequenceEqual([NoteActionId.SaveAsNewNote]) && saves == 0,
            "typed note: Save as New Note requests the escape instead of a default save");

        foreach (var destination in new[] { "Session destination", "Browse destination" })
        {
            view.SetDestination(destination, false);
            Require(!view.AppendsToExisting && Texts().Contains(destination) && Texts().Contains("Add to note"),
                "typed note: an explicit destination overrides the typed match");
            CheckEscapeEnabled(false);
            view.Perform(NoteActionId.SaveAsNewNote);
        }
        Require(saves == 2 && actions.Count == 1, "typed note: explicit destinations keep the default save");

        view.SetDestination(null, false);
        Require(view.AppendsToExisting, "typed note: clearing a Browse destination restores typed matching");
        view.Editor.SetText("An independent note\nBody");
        Require(!view.AppendsToExisting && Texts().Contains("Create note"), "typed note: an unmatched title shows the create hint");
        CheckEscapeEnabled(false);
        view.Perform(NoteActionId.SaveAsNewNote);
        Require(saves == 3 && actions.Count == 1, "typed note: an unmatched escape uses the default save");
    }
    /// <summary>A folder quick note titles its blank editor with the folder, which is not a chosen destination: the typed
    /// name still decides the title, the save hint and Save as New Note within that folder.</summary>
    private static void CheckFolderQuickNote()
    {
        const string folder = "Folder: Work/Research";
        using var view = new QuickNoteView(null, false, "", false, folder)
        {
            ExistingTitleForText = text => text.StartsWith("experiment", StringComparison.Ordinal) ? "Experiment" : null
        };
        var actions = new List<NoteActionId>();
        var saves = 0;
        view.ActionRequested += actions.Add;
        view.SaveRequested += () => saves++;
        string[] Texts() => LogicalDescendants(view).OfType<TextBlock>().Select(text => text.Text).ToArray();
        bool SaveAsNewEnabled()
        {
            view.ShowActions();
            var enabled = LogicalDescendants(view).OfType<Button>()
                .Single(item => System.Windows.Automation.AutomationProperties.GetName(item) == "Save as New Note").IsEnabled;
            view.HideActions();
            return enabled;
        }

        Require(!view.AppendsToExisting && Texts().Contains(folder) && Texts().Contains("Create note") && !SaveAsNewEnabled(),
            "folder note: a blank note shows its folder, the create hint and a disabled Save as New Note");
        view.Editor.SetText("Fresh idea\nBody");
        Require(!view.AppendsToExisting && Texts().Contains("Fresh idea") && !Texts().Contains(folder) && Texts().Contains("Create note") && !SaveAsNewEnabled(),
            "folder note: a name with no note in the folder shows the typed title and the create hint");
        view.Editor.SetText("experiment\nMore");
        Require(view.AppendsToExisting && Texts().Contains("Experiment") && Texts().Contains("Add to note") && SaveAsNewEnabled(),
            "folder note: a name matching a note in the folder shows that note, the append hint and Save as New Note");
        view.Perform(NoteActionId.SaveAsNewNote);
        Require(actions.SequenceEqual([NoteActionId.SaveAsNewNote]) && saves == 0,
            "folder note: Save as New Note requests the escape instead of a default save");
        view.SetDestination("Browse destination", false);
        Require(!view.AppendsToExisting && Texts().Contains("Browse destination") && !SaveAsNewEnabled(),
            "folder note: a Browse destination overrides the typed match");
        view.SetDestination(null, false);
        view.Editor.SetText("");
        Require(!view.AppendsToExisting && Texts().Contains(folder) && Texts().Contains("Create note"),
            "folder note: clearing the text and destination restores the folder title");
    }
    private static IEnumerable<DependencyObject> LogicalDescendants(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            foreach (var descendant in LogicalDescendants(child)) yield return descendant;
    }
    // Routed keyboard events exercise the editor's real input handler without creating a native window.
    private sealed class GalleryInputSource : PresentationSource
    {
        public override Visual RootVisual { get; set; } = null!;
        public override bool IsDisposed => false;
        protected override CompositionTarget GetCompositionTargetCore() => null!;
    }
    private static void CheckCheckboxRasterBounds(QuickNoteView view, FrameworkElement root, RenderTargetBitmap bitmap, double scale, string fixture)
    {
        var expectedBoxes = view.Editor.CheckboxExpectedBoundsForGallery;
        Require(expectedBoxes.Count == 2, fixture + ": both expected checkbox regions are available");
        var editorOrigin = view.Editor.TranslatePoint(new Point(Tokens.Zero, Tokens.Zero), root);
        var stride = bitmap.PixelWidth * 4;
        var pixels = new byte[stride * bitmap.PixelHeight];
        bitmap.CopyPixels(pixels, stride, 0);
        for (var index = 0; index < expectedBoxes.Count; index++)
        {
            var expected = expectedBoxes[index];
            // Locate the actual accent-colored pixels in the raster, independently of the drawing helper's returned top.
            const double padding = 2;
            var minX = Math.Clamp((int)Math.Floor((editorOrigin.X + expected.Left - padding) * scale), 0, bitmap.PixelWidth - 1);
            var maxX = Math.Clamp((int)Math.Ceiling((editorOrigin.X + expected.Right + padding) * scale), 0, bitmap.PixelWidth - 1);
            var minY = Math.Clamp((int)Math.Floor((editorOrigin.Y + expected.Top - padding) * scale), 0, bitmap.PixelHeight - 1);
            var maxY = Math.Clamp((int)Math.Ceiling((editorOrigin.Y + expected.Bottom + padding) * scale), 0, bitmap.PixelHeight - 1);
            var firstX = bitmap.PixelWidth; var lastX = -1; var firstY = bitmap.PixelHeight; var lastY = -1;
            for (var y = minY; y <= maxY; y++)
            for (var x = minX; x <= maxX; x++)
            {
                var offset = y * stride + x * 4;
                var blue = pixels[offset]; var green = pixels[offset + 1]; var red = pixels[offset + 2]; var alpha = pixels[offset + 3];
                if (alpha < 96 || red < 160 || red < green * 1.35 || red < blue * 1.3) continue;
                firstX = Math.Min(firstX, x); lastX = Math.Max(lastX, x);
                firstY = Math.Min(firstY, y); lastY = Math.Max(lastY, y);
            }
            Require(lastX >= firstX && lastY >= firstY, fixture + ": rendered checkbox accent pixels are present");
            var actualCenterX = (firstX + lastX + 1) / (2.0 * scale);
            var actualCenterY = (firstY + lastY + 1) / (2.0 * scale);
            var expectedCenterX = editorOrigin.X + expected.Left + expected.Width / 2;
            var expectedCenterY = editorOrigin.Y + expected.Top + expected.Height / 2;
            Require(Math.Abs(actualCenterX - expectedCenterX) <= 1 && Math.Abs(actualCenterY - expectedCenterY) <= 1,
                $"{fixture}: raster checkbox center ({actualCenterX:0.##}, {actualCenterY:0.##}) aligns with text baseline ({expectedCenterX:0.##}, {expectedCenterY:0.##}) at {scale:0.##}x");
            if (index == 1 && fixture != "quick-tasks-caret")
            {
                var boxLeft = Math.Clamp((int)Math.Ceiling((editorOrigin.X + expected.Left + 1) * scale), 0, bitmap.PixelWidth - 1);
                var boxRight = Math.Clamp((int)Math.Floor((editorOrigin.X + expected.Right - 1) * scale), 0, bitmap.PixelWidth - 1);
                var boxTop = Math.Clamp((int)Math.Ceiling((editorOrigin.Y + expected.Top + 1) * scale), 0, bitmap.PixelHeight - 1);
                var boxBottom = Math.Clamp((int)Math.Floor((editorOrigin.Y + expected.Bottom - 1) * scale), 0, bitmap.PixelHeight - 1);
                var whiteCheckPixels = 0;
                for (var y = boxTop; y <= boxBottom; y++)
                for (var x = boxLeft; x <= boxRight; x++)
                {
                    var offset = y * stride + x * 4;
                    if (pixels[offset + 3] >= 128 && pixels[offset] >= 180 && pixels[offset + 1] >= 180 && pixels[offset + 2] >= 180)
                        whiteCheckPixels++;
                }
                Require(whiteCheckPixels >= 2, $"{fixture}: checked-task tick is rasterized inside its box at {scale:0.##}x");
            }
        }
    }
    private static void CheckQuickNoteHighContrast()
    {
        var resources = new ResourceDictionary();
        using var theme = new ThemeManager(resources, darkOverride: true);
        theme.Apply(highContrast: true);
        var palette = resources.MergedDictionaries[0];
        Require(Equals(palette["SurfaceTint"], SystemColors.WindowBrush), "Quick Note high contrast uses the system surface");
        Require(Equals(palette["TextPrimary"], SystemColors.WindowTextBrush), "Quick Note high contrast uses system text");
        Require(Equals(palette["EditorLink"], SystemColors.HotTrackBrush), "Quick Note high contrast keeps links visible");
        Require(Equals(palette["EditorCheckboxCheck"], SystemColors.WindowBrush), "Quick Note high contrast keeps checkbox marks visible");
        theme.Apply(highContrast: false);
        Require(palette["SurfaceTint"] is SolidColorBrush { Color: { A: 0xF7, R: 0x16, G: 0x16, B: 0x16 } }, "Quick Note returns to dark palette after high contrast");
    }
    private static void CheckLayout(FrameworkElement root, string state)
    {
        foreach (var element in Descendants(root).OfType<FrameworkElement>())
        {
            if (element.Visibility != Visibility.Visible) continue;
            Require(double.IsFinite(element.ActualWidth) && double.IsFinite(element.ActualHeight), state + ": finite layout");
            Require(element.DesiredSize.Width <= element.ActualWidth + element.Margin.Left + element.Margin.Right + Tokens.LayoutTolerance && element.DesiredSize.Height <= element.ActualHeight + element.Margin.Top + element.Margin.Bottom + Tokens.LayoutTolerance, $"{state}: {element.GetType().Name} DesiredSize {element.DesiredSize} exceeds bounds {element.ActualWidth} × {element.ActualHeight}");
            if (element is not TextBlock text || string.IsNullOrEmpty(text.Text)) continue;
            var trimmed = text.Tag is QuickNoteView.TrimmedTag && text.TextTrimming != TextTrimming.None; // Intentional ellipsis: only the height must fit.
            var natural = new TextBlock
            {
                Text = text.Text, FontFamily = text.FontFamily, FontSize = text.FontSize, FontWeight = text.FontWeight,
                FontStyle = text.FontStyle, FontStretch = text.FontStretch, LineHeight = text.LineHeight,
                LineStackingStrategy = text.LineStackingStrategy, TextWrapping = TextWrapping.NoWrap
            };
            VisualTreeHelper.SetRootDpi(natural, VisualTreeHelper.GetDpi(root));
            natural.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Require((trimmed || natural.DesiredSize.Width <= text.ActualWidth + Tokens.LayoutTolerance) && natural.DesiredSize.Height <= text.ActualHeight + Tokens.LayoutTolerance, $"{state}: text '{text.Text}' needs {natural.DesiredSize}, has {text.ActualWidth} × {text.ActualHeight}");
        }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        if (root is FrameworkElement { Visibility: not Visibility.Visible }) yield break;
        yield return root;
        if (root is MarkdownEditor) yield break; // The editor control owns its internal layout.
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    private static void CheckGeometry()
    {
        // Negative origins and different work-area sizes exercise persistence independently of a desktop.
        foreach (var work in new[] { new Rect(-1920, 40, 1920, 1040), new Rect(0, 0, 1280, 720), new Rect(2560, -300, 1920, 1080) })
        {
            var size = new Size(Tokens.InputWidth, Tokens.InputFieldHeight + Tokens.Padding * 2);
            var rect = PanelGeometry.Default(size, work, true);
            Require(Math.Abs(rect.Top - (work.Top + work.Height * Tokens.PanelTopFraction)) < Tokens.LayoutTolerance, "Panel top fraction");
            var point = PanelGeometry.TopCenter(rect, work);
            Require(Math.Abs(point.Y - (Tokens.One - Tokens.PanelTopFraction)) < Tokens.LayoutTolerance, "Stored Y is measured from work-area bottom");
            var restored = PanelGeometry.FromPosition(point, size, work);
            Require(Math.Abs(restored.X - rect.X) < Tokens.LayoutTolerance && Math.Abs(restored.Y - rect.Y) < Tokens.LayoutTolerance && restored.Size == rect.Size, "Position round trip");
            var toast = PanelGeometry.Default(new Size(Tokens.ToastMinWidth, Tokens.ToastHeight), work, false);
            Require(Math.Abs(work.Bottom - toast.Bottom - Tokens.ToastBottomOffset) < Tokens.LayoutTolerance, "Toast bottom offset");
            var resized = PanelGeometry.Resize(rect, new Size(Tokens.SearchWidth, size.Height), work);
            Require(resized.Top == rect.Top && Math.Abs(resized.Left + resized.Width / 2 - (rect.Left + rect.Width / 2)) < Tokens.LayoutTolerance, "Resize keeps top and center");
        }
        var store = new MemoryPanelPositionStore();
        store.Save(PanelGeometry.NotePositionKey, new PanelPosition(Tokens.Center, Tokens.PanelTopFraction));
        Require(store.Load(PanelGeometry.NotePositionKey) == new PanelPosition(Tokens.Center, Tokens.PanelTopFraction), "Position store contract");
        Require(new Toast(ToastStyle.Warning, "Warning").DurationSeconds == Tokens.WarningToastDuration && new Toast(ToastStyle.Success, "Saved").DurationSeconds == Tokens.DefaultToastDuration, "Toast durations");
    }
    private static object? liveController;
    private static void Live(string component, Application app)
    {
        void Finish() { liveController = null; app.Shutdown(); }
        switch (component)
        {
            case "toast": case "success": case "warning": case "session": case "copied":
                var toast = new ToastController { OnExpire = Finish }; liveController = toast;
                var style = Enum.TryParse<ToastStyle>(component, true, out var parsed) ? parsed : ToastStyle.Success;
                toast.Show(new Toast(style, "Capture saved", "Added to System Design", new ToastHint("Alt+Shift+Q", "name"))); break;
            case "search":
                var search = new SearchPanelController(); liveController = search;
                search.Present((text, _) => Task.FromResult<IReadOnlyList<SearchSection>>(text.Length == 0 ? Fixtures.Recent : Fixtures.Matches.Where(s => s.Rows.Any(r => r.Title.Contains(text, StringComparison.OrdinalIgnoreCase))).ToArray()),
                    new SearchActions(_ => Finish(), _ => Finish(), _ => Finish(), Finish)); break;
            case "input": case "subheading":
                var input = new InputPanelController(); liveController = input;
                input.Present(new InputRequest(component == "subheading" ? "Subheading" : "Name this session", text => Fixtures.Suggestions.Where(s => s.Title.StartsWith(text, StringComparison.OrdinalIgnoreCase)).ToArray(), _ => Finish(), Finish,
                    Title: component == "subheading" ? "Add subheading" : null, Secondary: component == "subheading" ? "In System Design" : null)); break;
            case "session-picker":
                var picker = new SessionPickerController(); liveController = picker; picker.Present(Fixtures.Sessions, _ => Finish(), Finish); break;
            case "editor":
                var quick = new QuickNoteController { PositionStore = new MemoryPanelPositionStore() }; liveController = quick;
                quick.Present(null, false, Fixtures.MarkdownSample, new QuickNoteHandlers(_ => { }, _ => Finish(), _ => Finish(), _ => Finish(), () => Fixtures.BrowseItems, (_, _) => Finish(),
                    () => true, Finish, exception => Console.Error.WriteLine(exception))); break;
            default: throw new ArgumentException("Unknown component: " + component);
        }
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
