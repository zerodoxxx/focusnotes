using System.Runtime.InteropServices;

namespace CaptureApp.Platform.Hotkeys;

/// <summary>Detects Ctrl+Alt+Shift+letter combinations that type a character via installed AltGr layouts.</summary>
public static class AltGrGuard
{
    // Stable fallback priority after the seven defaults Q, G, F, A, W, H, E.
    public const string FallbackOrder = "DJKLNPRTUVXYZBCIOSM";

    private const uint MapVirtualKeyToScanCode = 0;
    private const uint ToUnicodeNoStateChange = 0x0004;
    private const uint LoadKeyboardLayoutNoShell = 0x00000080;

    public static IReadOnlyList<IntPtr> GetInstalledLayouts()
    {
        var count = AltGrNativeMethods.GetKeyboardLayoutList(0, IntPtr.Zero);
        if (count <= 0)
        {
            var currentLayout = AltGrNativeMethods.GetKeyboardLayout(0);
            return currentLayout == IntPtr.Zero ? Array.Empty<IntPtr>() : [currentLayout];
        }

        var buffer = Marshal.AllocHGlobal(count * IntPtr.Size);
        try
        {
            var copied = AltGrNativeMethods.GetKeyboardLayoutList(count, buffer);
            var layouts = new List<IntPtr>(copied);
            for (var index = 0; index < copied; index++)
            {
                var layout = Marshal.ReadIntPtr(buffer, index * IntPtr.Size);
                if (layout != IntPtr.Zero && !layouts.Contains(layout))
                {
                    layouts.Add(layout);
                }
            }

            return layouts;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static IReadOnlyList<IntPtr> GetConflictingLayouts(KeyChord chord)
    {
        if (!IsAltGrCandidate(chord))
        {
            return Array.Empty<IntPtr>();
        }

        var conflicts = new List<IntPtr>();
        foreach (var layout in GetInstalledLayouts())
        {
            if (ProducesCharacter(chord.VirtualKey, layout))
            {
                conflicts.Add(layout);
            }
        }

        return conflicts;
    }

    public static bool IsSafe(KeyChord chord) => GetConflictingLayouts(chord).Count == 0;

    /// <summary>Returns the first unused Ctrl+Alt+Shift letter in <see cref="FallbackOrder"/> that is safe in every layout.</summary>
    public static KeyChord? FindNextFreeLetter(IEnumerable<KeyChord>? occupied = null)
    {
        var unavailable = occupied is null ? new HashSet<KeyChord>() : new HashSet<KeyChord>(occupied);
        foreach (var letter in FallbackOrder)
        {
            var candidate = new KeyChord(HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift, letter);
            if (!unavailable.Contains(candidate) && IsSafe(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    public static IntPtr LoadLayoutForTesting(string klid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(klid);
        return AltGrNativeMethods.LoadKeyboardLayout(klid, LoadKeyboardLayoutNoShell);
    }

    public static bool UnloadLayoutForTesting(IntPtr layout) =>
        layout != IntPtr.Zero && AltGrNativeMethods.UnloadKeyboardLayout(layout);

    private static bool IsAltGrCandidate(KeyChord chord) => chord.IsLetter &&
        chord.Modifiers == (HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Shift);

    private static bool ProducesCharacter(int virtualKey, IntPtr layout)
    {
        var scanCode = AltGrNativeMethods.MapVirtualKeyEx((uint)virtualKey, MapVirtualKeyToScanCode, layout);
        if (scanCode == 0)
        {
            return false;
        }

        var keyboardState = Marshal.AllocHGlobal(256);
        var output = Marshal.AllocHGlobal(sizeof(short) * 4);
        try
        {
            Marshal.Copy(new byte[256], 0, keyboardState, 256);
            Marshal.WriteByte(keyboardState, 0x10, 0x80); // VK_SHIFT
            Marshal.WriteByte(keyboardState, 0x11, 0x80); // VK_CONTROL
            Marshal.WriteByte(keyboardState, 0x12, 0x80); // VK_MENU (AltGr is Ctrl+Alt)
            Marshal.WriteByte(keyboardState, virtualKey, 0x80);
            for (var index = 0; index < 4; index++)
            {
                Marshal.WriteInt16(output, index * sizeof(short), 0);
            }

            // Flag 0x4 asks Windows not to mutate the keyboard dead-key state.
            var translatedCount = AltGrNativeMethods.ToUnicodeEx((uint)virtualKey, scanCode, keyboardState,
                output, 4, ToUnicodeNoStateChange, layout);
            return translatedCount != 0 && Marshal.ReadInt16(output) != 0;
        }
        finally
        {
            Marshal.FreeHGlobal(output);
            Marshal.FreeHGlobal(keyboardState);
        }
    }
}

internal static partial class AltGrNativeMethods
{
    [LibraryImport("user32.dll", EntryPoint = "GetKeyboardLayoutList", SetLastError = true)]
    internal static partial int GetKeyboardLayoutList(int count, IntPtr layouts);

    [LibraryImport("user32.dll", EntryPoint = "GetKeyboardLayout")]
    internal static partial IntPtr GetKeyboardLayout(uint threadId);

    [LibraryImport("user32.dll", EntryPoint = "MapVirtualKeyExW")]
    internal static partial uint MapVirtualKeyEx(uint code, uint mapType, IntPtr layout);

    [LibraryImport("user32.dll", EntryPoint = "ToUnicodeEx", SetLastError = true)]
    internal static partial int ToUnicodeEx(uint virtualKey, uint scanCode, IntPtr keyboardState,
        IntPtr buffer, int bufferSize, uint flags, IntPtr layout);

    [LibraryImport("user32.dll", EntryPoint = "LoadKeyboardLayoutW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    internal static partial IntPtr LoadKeyboardLayout(string klid, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "UnloadKeyboardLayout", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnloadKeyboardLayout(IntPtr layout);
}
