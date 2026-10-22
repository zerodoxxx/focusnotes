using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Input;
using CaptureApp.App;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Overlay;
using Xunit;

namespace CaptureApp.App.Tests;

// Runs on the existing Setup test's STA/Application, avoiding a second WPF Application instance.
internal static class SessionPickerChecks
{
    internal static void Run(Application app)
    {
        var root = Path.Combine(Path.GetTempPath(), "session-picker-review-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            using var pipeline = CapturePipeline.Open(Path.Combine(root, "vault"), Path.Combine(root, "state"), TimeZoneInfo.Utc);
            using var controller = new AppController(app, pipeline.StateDirectory, pipeline);
            var first = pipeline.Sessions.Start("Standup");
            var second = pipeline.Sessions.Start("archive/Standup");
            pipeline.Sessions.End();
            controller.PresentSessionCandidates(new[] { first, second }
                .Select(s => new SessionCandidate(s.Name, s.NotePath, DateTimeOffset.UtcNow)).ToArray());
            try
            {
                var picker = Assert.IsType<InputPanelController>(controller.InputForChecks);
                picker.HandleInput(Key.Enter, ModifierKeys.Control);
                Assert.Same(picker, controller.InputForChecks);
                Assert.True(picker.IsVisible); // Ctrl+Enter without a highlighted row is ignored.
                picker.HandleInput(Key.Down);
                picker.HandleInput(Key.Down);
                Assert.Equal(second.NotePath, picker.SelectedValueForChecks);
                picker.HandleInput(Key.Enter, ModifierKeys.Control, isRepeat: true);
                Assert.Same(picker, controller.InputForChecks);
                picker.HandleInput(Key.Enter, ModifierKeys.Control);
                Settle();

                var rename = Assert.IsType<InputPanelController>(controller.InputForChecks);
                Assert.NotSame(picker, rename);
                Assert.Equal(second.Name, rename.ViewForChecks!.Field.Text);
                Assert.Equal(second.Name, rename.ViewForChecks.Field.SelectedText);
                rename.HandleInput(Key.Escape);
                Settle();

                var restored = Assert.IsType<InputPanelController>(controller.InputForChecks);
                Assert.NotSame(rename, restored);
                Assert.Equal(second.NotePath, restored.SelectedValueForChecks);
                Assert.Null(pipeline.Sessions.Current());
                restored.HandleInput(Key.Enter, ModifierKeys.Control);
                Settle();
                controller.InputForChecks!.Dismiss(animated: false);
                Settle();
                Assert.Null(controller.InputForChecks); // Programmatic cancel must not restore a picker.
                Assert.True(File.Exists(pipeline.Vault.ManagedUrl(first.NotePath)));
                Assert.True(File.Exists(pipeline.Vault.ManagedUrl(second.NotePath)));

                var occupied = pipeline.Sessions.Start("archive/Taken");
                pipeline.Sessions.End();
                var before = File.ReadAllBytes(pipeline.Vault.ManagedUrl(second.NotePath));
                foreach (var (name, hint) in new[]
                {
                    ("Taken", Strings.RenameSessionNameInUseHint),
                    ("standup", Strings.RenameSessionCaseOnlyHint),
                    ("folder/name", Strings.RenameSessionInvalidNameHint)
                })
                {
                    controller.PresentSessionCandidates([new(second.Name, second.NotePath, DateTimeOffset.UtcNow)], second.NotePath);
                    controller.InputForChecks!.HandleInput(Key.Enter, ModifierKeys.Control);
                    Settle();
                    var attempt = Assert.IsType<InputPanelController>(controller.InputForChecks);
                    attempt.ViewForChecks!.Field.Text = name;
                    attempt.HandleInput(Key.Enter);
                    Settle();
                    var completed = new TaskCompletionSource();
                    controller.Coordinator.Enqueue(_ => { completed.SetResult(); return Task.CompletedTask; });
                    UiWait.Pump(completed.Task, TimeSpan.FromSeconds(5));
                    var retry = Assert.IsType<InputPanelController>(controller.InputForChecks);
                    Assert.NotSame(attempt, retry);
                    Assert.Equal(name, retry.ViewForChecks!.Field.Text);
                    Assert.Equal(name, retry.ViewForChecks.Field.SelectedText);
                    Assert.Equal(hint, AutomationProperties.GetHelpText(retry.ViewForChecks.Field));
                    Assert.Equal(before, File.ReadAllBytes(pipeline.Vault.ManagedUrl(second.NotePath)));
                    Assert.True(File.Exists(pipeline.Vault.ManagedUrl(occupied.NotePath)));
                    Assert.Null(pipeline.Sessions.Current());
                    retry.Dismiss(animated: false);
                }
            }
            finally { controller.InputForChecks?.Dismiss(animated: false); }

            var generic = new InputPanelController();
            var alternate = false;
            generic.Present(new InputRequest("name", _ => [], _ => { }, () => { }, InitialText: "prefilled",
                OnAlternateSubmit: _ => alternate = true));
            try
            {
                generic.HandleInput(Key.Enter, ModifierKeys.Control);
                Assert.True(generic.IsVisible);
                Assert.False(alternate); // Alternate requires a highlighted value even outside SelectionOnly.
            }
            finally { generic.Dismiss(animated: false); }
        }
        finally { Directory.Delete(root, true); }
    }

    private static void Settle() => UiWait.Pump(Task.Delay(350, TestContext.Current.CancellationToken), TimeSpan.FromSeconds(3));
}
