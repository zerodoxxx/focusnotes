namespace CaptureApp.Core;

public static class FileRetry
{
    public const int LockedRetryBudgetMs = 10000;
    public const int LockedRetryPollMs = 2;
    public const int SectionedJsonRetries = 4;
    public const int SectionedJsonDelayMs = 20;
    public const int MoveFallbackAttempts = 3;
    public const int MoveFallbackDelayMs = 75;
}
