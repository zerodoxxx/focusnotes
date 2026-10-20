using System.Runtime.InteropServices;

namespace CaptureApp.Platform.Shell;

public static class KnownFolders
{
    private static readonly Guid DocumentsFolderId = new("FDD39AD0-238F-46AF-ADB4-6C85480369C7");

    public static string Documents
    {
        get
        {
            var result = KnownFolderNativeMethods.SHGetKnownFolderPath(in DocumentsFolderId, 0, IntPtr.Zero, out var pathPointer);
            if (result < 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }

            try
            {
                return Marshal.PtrToStringUni(pathPointer) ?? throw new InvalidOperationException("Windows returned an empty Documents folder path.");
            }
            finally
            {
                KnownFolderNativeMethods.CoTaskMemFree(pathPointer);
            }
        }
    }
}

internal static partial class KnownFolderNativeMethods
{
    [LibraryImport("shell32.dll", EntryPoint = "SHGetKnownFolderPath", SetLastError = true)]
    internal static partial int SHGetKnownFolderPath(in Guid folderId, uint flags, IntPtr token, out IntPtr path);

    [LibraryImport("ole32.dll", EntryPoint = "CoTaskMemFree")]
    internal static partial void CoTaskMemFree(IntPtr memory);
}
