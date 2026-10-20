using System.Runtime.InteropServices;

namespace CaptureApp.Platform.Selection;

internal static class ElevationCheck
{
    internal static bool MustRefuse(uint? ownIntegrity, uint? targetIntegrity) =>
        ownIntegrity is null || targetIntegrity is null || targetIntegrity > ownIntegrity;

    internal static bool MustRefuse(uint targetPid) => MustRefuse(ReadIntegrity((uint)Environment.ProcessId), ReadIntegrity(targetPid));

    internal static uint? ReadIntegrity(uint pid)
    {
        var process = NativeMethods.OpenProcess(0x1000, false, pid);
        if (process == 0) return null;
        nint token = 0;
        nint buffer = 0;
        try
        {
            if (!NativeMethods.OpenProcessToken(process, 0x0008, out token)) return null;
            _ = NativeMethods.GetTokenInformation(token, 25, 0, 0, out var size);
            if (size == 0 || size > 1024 * 1024) return null;
            buffer = Marshal.AllocHGlobal((int)size);
            if (!NativeMethods.GetTokenInformation(token, 25, buffer, size, out _)) return null;
            var sid = Marshal.ReadIntPtr(buffer);
            var count = Marshal.ReadByte(NativeMethods.GetSidSubAuthorityCount(sid));
            return count == 0 ? null : unchecked((uint)Marshal.ReadInt32(NativeMethods.GetSidSubAuthority(sid, (uint)count - 1)));
        }
        finally
        {
            if (buffer != 0) Marshal.FreeHGlobal(buffer);
            if (token != 0) _ = NativeMethods.CloseHandle(token);
            _ = NativeMethods.CloseHandle(process);
        }
    }
}
