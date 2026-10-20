using System.Globalization;

namespace CaptureApp.ModelInstall;

public enum ModelInstallErrorKind
{
    InsufficientDiskSpace,
    Network,
    HttpStatus,
    InsecureRedirect,
    ChecksumMismatch,
    MissingBundledResource,
    Io,

    /// A guard refused the request right now (another operation is running, or the state is unknown).
    Unavailable,
    Cancelled
}

/// Errors from the opt-in semantic-model download. Messages are shown to the user as written.
public sealed class ModelInstallException : Exception
{
    private ModelInstallException(ModelInstallErrorKind kind, string message, int? statusCode = null, long required = 0, long available = 0)
        : base(message)
    {
        Kind = kind;
        StatusCode = statusCode;
        Required = required;
        Available = available;
    }

    public ModelInstallErrorKind Kind { get; }

    public int? StatusCode { get; }

    public long Required { get; }

    public long Available { get; }

    public static ModelInstallException InsufficientDiskSpace(long required, long available) => new(
        ModelInstallErrorKind.InsufficientDiskSpace,
        $"Not enough free disk space. Semantic search needs about {FormatBytes(required)} free; {FormatBytes(available)} is available.",
        required: required,
        available: available);

    public static ModelInstallException Network(string detail) => new(
        ModelInstallErrorKind.Network, $"The download failed: {detail}. Check your connection and try again; it resumes where it stopped.");

    public static ModelInstallException HttpStatus(int code, string host) => new(
        ModelInstallErrorKind.HttpStatus, $"The server {host} returned HTTP {code}.", code);

    public static ModelInstallException InsecureRedirect() => new(
        ModelInstallErrorKind.InsecureRedirect, "The download was redirected to an insecure address and was stopped.");

    public static ModelInstallException ChecksumMismatch(string file) => new(
        ModelInstallErrorKind.ChecksumMismatch, $"{file} failed its integrity check and was discarded. Try again later.");

    public static ModelInstallException MissingBundledResource(string name) => new(
        ModelInstallErrorKind.MissingBundledResource, $"The app is missing {name}. Reinstall the app.");

    public static ModelInstallException Io(string detail) => new(ModelInstallErrorKind.Io, $"Couldn't write the model files: {detail}.");

    public static ModelInstallException Unavailable(string message) => new(ModelInstallErrorKind.Unavailable, message);

    public static ModelInstallException Cancelled() => new(ModelInstallErrorKind.Cancelled, "The download was cancelled.");

    /// Decimal units, as in Finder and Explorer's file sizes.
    public static string FormatBytes(long bytes) => bytes switch
    {
        >= 1_000_000_000 => (bytes / 1e9).ToString("0.##", CultureInfo.InvariantCulture) + " GB",
        >= 1_000_000 => (bytes / 1e6).ToString("0.#", CultureInfo.InvariantCulture) + " MB",
        >= 1_000 => (bytes / 1e3).ToString("0", CultureInfo.InvariantCulture) + " KB",
        _ => bytes.ToString(CultureInfo.InvariantCulture) + " bytes"
    };
}
