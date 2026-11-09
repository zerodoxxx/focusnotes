namespace CaptureApp.Core;

public static class CloudRecall
{
    // Cloud placeholder attributes; sweeps and restores skip files carrying them so they never trigger a recall.
    public const FileAttributes Mask = (FileAttributes)(0x400000 | 0x40000);
}
