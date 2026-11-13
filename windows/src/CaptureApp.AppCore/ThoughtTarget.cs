using CaptureApp.Core;

namespace CaptureApp.AppCore;

public sealed record ThoughtTarget(Guid CaptureId, string SourceTitle, string? SourceDetail,
    string? ExcerptText, byte[]? ExcerptImagePng, Task<SavedCapture>? Commit);
