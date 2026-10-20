using System.Runtime.InteropServices;

namespace CaptureApp.Platform.Selection;

internal static partial class NativeMethods
{
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool SetForegroundWindow(nint window);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool AllowSetForegroundWindow(uint pid);
    [LibraryImport("user32.dll")] internal static partial nint GetForegroundWindow();
    [LibraryImport("user32.dll")] internal static partial uint GetWindowThreadProcessId(nint window, out uint pid);
    [LibraryImport("user32.dll", EntryPoint = "GetWindowTextW")] internal static partial int GetWindowText(nint window, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.U2, SizeParamIndex = 2)] char[] text, int maximum);
    [LibraryImport("kernel32.dll", SetLastError = true)] internal static partial nint OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint pid);
    [LibraryImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool QueryFullProcessImageName(nint process, uint flags, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.U2, SizeParamIndex = 3)] char[] path, ref uint size);
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool CloseHandle(nint handle);
    [LibraryImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool OpenProcessToken(nint process, uint access, out nint token);
    [LibraryImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool GetTokenInformation(nint token, int kind, nint buffer, uint size, out uint required);
    [LibraryImport("advapi32.dll")] internal static partial nint GetSidSubAuthorityCount(nint sid);
    [LibraryImport("advapi32.dll")] internal static partial nint GetSidSubAuthority(nint sid, uint index);
    [LibraryImport("user32.dll")] internal static partial short GetAsyncKeyState(int key);
    [LibraryImport("user32.dll", SetLastError = true)] internal static partial uint SendInput(uint count, [In] Input[] input, int size);
    [LibraryImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool OpenClipboard(nint owner);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool CloseClipboard();
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool EmptyClipboard();
    [LibraryImport("user32.dll")] internal static partial uint GetClipboardSequenceNumber();
    [LibraryImport("user32.dll")] internal static partial nint GetClipboardOwner();
    [LibraryImport("user32.dll", SetLastError = true)] internal static partial uint EnumClipboardFormats(uint format);
    [LibraryImport("user32.dll", SetLastError = true)] internal static partial nint GetClipboardData(uint format);
    [LibraryImport("user32.dll", SetLastError = true)] internal static partial nint SetClipboardData(uint format, nint data);
    [LibraryImport("user32.dll", EntryPoint = "RegisterClipboardFormatW", StringMarshalling = StringMarshalling.Utf16)] internal static partial uint RegisterClipboardFormat(string name);
    [LibraryImport("kernel32.dll", SetLastError = true)] internal static partial nuint GlobalSize(nint handle);
    [LibraryImport("kernel32.dll", SetLastError = true)] internal static partial nint GlobalLock(nint handle);
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool GlobalUnlock(nint handle);
    [LibraryImport("kernel32.dll", SetLastError = true)] internal static partial nint GlobalAlloc(uint flags, nuint bytes);
    [LibraryImport("kernel32.dll")] internal static partial nint GlobalFree(nint handle);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool AddClipboardFormatListener(nint window);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool RemoveClipboardFormatListener(nint window);
    [LibraryImport("user32.dll", EntryPoint = "CreateWindowExW", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint CreateWindowEx(uint extended, string className, string name, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [LibraryImport("user32.dll", EntryPoint = "GetMessageW")] internal static partial int GetMessage(out Message message, nint window, uint min, uint max);
    [LibraryImport("user32.dll", EntryPoint = "DispatchMessageW")] internal static partial nint DispatchMessage(in Message message);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool TranslateMessage(in Message message);
    [LibraryImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool PostMessage(nint window, uint message, nuint wparam, nint lparam);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool DestroyWindow(nint window);
    [LibraryImport("user32.dll")] internal static partial nint CopyImage(nint image, uint type, int width, int height, uint flags);
    [LibraryImport("gdi32.dll", EntryPoint = "GetObjectW")] internal static partial int GetObject(nint handle, int size, out Bitmap bitmap);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool DeleteObject(nint handle);
    [LibraryImport("gdi32.dll", EntryPoint = "CopyEnhMetaFileW")] internal static partial nint CopyEnhMetaFile(nint handle, nint filename);
    [LibraryImport("gdi32.dll")] internal static partial uint GetEnhMetaFileBits(nint handle, uint size, nint buffer);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool DeleteEnhMetaFile(nint handle);
    [LibraryImport("gdi32.dll", EntryPoint = "CopyMetaFileW")] internal static partial nint CopyMetaFile(nint handle, nint filename);
    [LibraryImport("gdi32.dll")] internal static partial uint GetMetaFileBitsEx(nint handle, uint size, nint buffer);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static partial bool DeleteMetaFile(nint handle);
    [LibraryImport("gdi32.dll")] internal static partial uint GetPaletteEntries(nint palette, uint start, uint count, [Out] byte[]? entries);
    [LibraryImport("gdi32.dll")] internal static partial nint CreatePalette([In] byte[] palette);

    [StructLayout(LayoutKind.Sequential)] internal struct Message
    {
        internal nint Window; internal uint Id; internal nuint WParam; internal nint LParam;
        internal uint Time; internal int X; internal int Y; internal uint Private;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct Bitmap
    {
        internal int Type, Width, Height, WidthBytes; internal ushort Planes, BitsPixel; internal nint Bits;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct MetafilePicture
    {
        internal int MappingMode, XExtent, YExtent; internal nint Metafile;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct Input { internal uint Type; internal InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)] internal struct InputUnion
    {
        [FieldOffset(0)] internal KeyboardInput Keyboard;
        [FieldOffset(0)] internal MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardInput
    {
        internal ushort Key, Scan; internal uint Flags, Time; internal nuint Extra;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct MouseInput
    {
        internal int X, Y; internal uint Data, Flags, Time; internal nuint Extra;
    }
}
