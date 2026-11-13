using CaptureApp.Overlay;
using Xunit;

namespace CaptureApp.App.Tests;

// Runs on the existing Setup test's STA/Application, avoiding a second WPF Application instance.
internal static class ThoughtEditorChecks
{
    internal static void Run()
    {
        SaveCompletionKeepsNewerText();
        AnotherPanelKeepsTheDraftOpen();
    }

    private static void SaveCompletionKeepsNewerText()
    {
        var editor = new ThoughtEditorPanel();
        var capture = Guid.NewGuid();
        var content = new ThoughtEditorContent("Biology", null, "Cell respiration", null, "Saved");
        editor.Present(capture, content, _ => { }, _ => { });
        try
        {
            editor.ViewForChecks!.Editor.Text = "Saved and more";
            editor.SaveSucceeded("Saved");
            Assert.True(editor.IsVisible); // Text typed while the save was pending stays open.
            Assert.Equal("Saved and more", editor.CurrentText);
            editor.SaveSucceeded("Saved and more");
            Assert.Null(editor.CaptureId);

            // A reopened panel for the same capture is a new instance, so an older save cannot dismiss it.
            editor.Present(capture, content, _ => { }, _ => { });
            var stale = editor.InstanceId;
            editor.Dismiss();
            editor.Present(capture, content, _ => { }, _ => { });
            Assert.Equal(capture, editor.CaptureId);
            Assert.NotEqual(stale, editor.InstanceId);
        }
        finally { editor.Dismiss(); }
    }

    private static void AnotherPanelKeepsTheDraftOpen()
    {
        var editor = new ThoughtEditorPanel();
        var capture = Guid.NewGuid();
        var content = new ThoughtEditorContent("Biology", null, "Cell respiration", null, "Draft");
        editor.Present(capture, content, _ => { }, _ => { });
        var other = new OverlayWindow(ThoughtEditorPanel.Preview(content));
        try
        {
            editor.ViewForChecks!.Editor.Text = "Mid-thought";
            other.Present(); // Stands in for the session prompt: an interactive panel taking focus.
            Assert.True(editor.IsVisible);
            Assert.Equal(capture, editor.CaptureId);
            Assert.Equal("Mid-thought", editor.CurrentText);
        }
        finally
        {
            other.Dismiss(animated: false);
            editor.Dismiss();
        }
    }
}
