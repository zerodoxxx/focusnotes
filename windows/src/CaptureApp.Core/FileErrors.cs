namespace CaptureApp.Core;

public static class FileErrors
{
    public static int Code(Exception e) => e.HResult & 0xFFFF;

    public static bool IsSharingCode(int c) => c is 11 or 32 or 33;

    public static bool IsAbsentCode(int c) => OperatingSystem.IsWindows() ? c is 2 or 3 : c is 2 or 20;

    public static bool IsUnavailableCode(int c) => OperatingSystem.IsWindows() ? c is 21 or 55 or 1117 or 1167 : c is 5 or 6 or 19;

    public static bool IsSharingViolation(Exception e) => e is IOException && IsSharingCode(Code(e));
}
