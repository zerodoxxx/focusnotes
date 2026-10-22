using System.IO;
using System.Windows;
using CaptureApp.App;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using Xunit;

namespace CaptureApp.App.Tests;

// Shares the Setup test's WPF Application and STA thread.
internal static class NotesFolderChecks
{
    internal static void Run(Application app)
    {
        var directory = Path.Combine(Path.GetTempPath(), "notes-folder-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var active = Path.Combine(directory, "active");
            var next = Path.Combine(directory, "next");
            using var pipeline = CapturePipeline.Open(active, Path.Combine(directory, "state"), TimeZoneInfo.Utc);
            using var controller = new AppController(app, pipeline.StateDirectory, pipeline);
            controller.Settings.NotesFolder = active;
            var session = pipeline.Sessions.Start("Keep working");
            var note = pipeline.Vault.ManagedUrl(session.NotePath);
            var before = File.ReadAllBytes(note);

            Assert.True(controller.SaveNotesFolder(next + Path.DirectorySeparatorChar, out var error));
            Assert.Null(error);
            Assert.Equal(next, new SettingsStore(controller.SettingsPath).NotesFolder);
            Assert.True(controller.NotesFolderNeedsRestart);
            Assert.Contains("Restart", controller.NotesFolderChangeMessage);
            Assert.Equal(active, pipeline.Vault.Root);
            Assert.Equal(session, pipeline.Sessions.Current());
            Assert.Equal(before, File.ReadAllBytes(note));
            Assert.Empty(Directory.GetFiles(next));

            // Checking the already saved choice still reflects that the active vault has not changed.
            Assert.True(controller.SaveNotesFolder(next, out _));
            Assert.True(controller.NotesFolderNeedsRestart);

            Assert.False(controller.SaveNotesFolder("relative-folder", out error));
            Assert.NotNull(error);
            Assert.Equal(next, controller.CurrentNotesFolder);
            Assert.False(controller.SaveNotesFolder(note, out error));
            Assert.NotNull(error);
            Assert.Equal(next, controller.CurrentNotesFolder);
            Assert.Equal(before, File.ReadAllBytes(note));

            Assert.True(controller.SaveNotesFolder(active, out _));
            Assert.False(controller.NotesFolderNeedsRestart);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }
}
