using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using Microsoft.Win32;

namespace CaptureApp.App;

internal static class NotesFolderPicker
{
    internal static string? Choose(Window? owner, string initialFolder, bool appliesOnRestart)
    {
        var dialog = new OpenFolderDialog
        {
            Title = appliesOnRestart ? "Choose Notes Folder (used after restart)" : "Choose Notes Folder",
            InitialDirectory = Directory.Exists(initialFolder) ? initialFolder : null,
            Multiselect = false
        };
        var accepted = owner is null ? dialog.ShowDialog() : dialog.ShowDialog(owner);
        return accepted == true ? dialog.FolderName : null;
    }

    internal static bool IsFolderError(Exception error) => error is IOException or UnauthorizedAccessException
        or ArgumentException or NotSupportedException or System.Security.SecurityException or COMException;
}
