using System.Diagnostics;
using System.Globalization;
using System.Text;
using CaptureApp.Embed;

namespace CaptureApp.EmbedHelper;

internal static class Program
{
    private const string Usage = "Usage: EmbedHelper --models <dir> [--idle-seconds 60] [--parent-pid <pid>] | --self-test";

    private static async Task<int> Main(string[] args)
    {
        try
        {
            return await RunAsync(args).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"EmbedHelper: {error.Message}");
            return 1;
        }
    }

    private static async Task<int> RunAsync(string[] args)
    {
        string? directory = null;
        var idle = 60.0;
        int? parentPid = null;
        var selfTest = false;
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--models":
                    directory = ++i < args.Length ? args[i] : throw EmbeddingException.Invalid("--models requires a directory");
                    break;
                case "--idle-seconds":
                    if (++i >= args.Length || !double.TryParse(args[i], NumberStyles.Float, CultureInfo.InvariantCulture, out idle)
                        || !double.IsFinite(idle) || idle <= 0 || idle > 86_400)
                    {
                        throw EmbeddingException.Invalid("Invalid idle timeout");
                    }

                    break;
                case "--parent-pid":
                    if (++i >= args.Length || !int.TryParse(args[i], NumberStyles.None, CultureInfo.InvariantCulture, out var pid) || pid <= 1)
                    {
                        throw EmbeddingException.Invalid("Invalid parent PID");
                    }

                    parentPid = pid;
                    break;
                case "--self-test":
                    selfTest = true;
                    break;
                default:
                    throw EmbeddingException.Invalid($"Unknown argument: {args[i]}");
            }
        }

        var background = BackgroundMode.Apply();
        if (selfTest)
        {
            return SelfTest(background);
        }

        if (directory is null)
        {
            throw EmbeddingException.Invalid(Usage);
        }

        // Unlike stdin EOF, parent exit is observed even while the request loop is blocked in model work.
        if (parentPid is { } parent && !WatchParent(parent))
        {
            return 0;
        }

        await ServeAsync(directory, idle, background).ConfigureAwait(false);
        return 0;
    }

    /// Windows asserts all three background controls took effect; elsewhere there is nothing to assert.
    private static int SelfTest(BackgroundMode.Status? background)
    {
        var report = EmbedResponse.Create("self-test", 256, ecoQos: background?.EcoQos, belowNormal: background?.BelowNormal, backgroundMode: background?.BackgroundMode);
        using var stdout = Console.OpenStandardOutput();
        stdout.Write(EmbedProtocol.EncodeLine(report));
        stdout.Flush();
        if (!OperatingSystem.IsWindows())
        {
            return 0;
        }

        return background is { EcoQos: true, BelowNormal: true, BackgroundMode: true } ? 0 : 1;
    }

    private static bool WatchParent(int pid)
    {
        try
        {
            var parent = Process.GetProcessById(pid);
            parent.EnableRaisingEvents = true;
            parent.Exited += (_, _) => Environment.Exit(0);
            // Close the race between starting up and installing the handler.
            return !parent.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static async Task ServeAsync(string directory, double idle, BackgroundMode.Status? background)
    {
        var embedders = new Dictionary<int, Embedder>();
        try
        {
            using var stdin = Console.OpenStandardInput();
            using var stdout = Console.OpenStandardOutput();
            var pending = new MemoryStream();
            var buffer = new byte[16_384];
            var maybeLine = false;
            var deadline = Stopwatch.GetTimestamp() + (long)(idle * Stopwatch.Frequency);
            var read = stdin.ReadAsync(buffer).AsTask();
            while (true)
            {
                var line = maybeLine ? TakeLine(pending) : null;
                if (line is not null)
                {
                    var response = Handle(line, directory, embedders, background);
                    stdout.Write(EmbedProtocol.EncodeLine(response));
                    stdout.Flush();
                    deadline = Stopwatch.GetTimestamp() + (long)(idle * Stopwatch.Frequency);
                    continue;
                }

                maybeLine = false;

                var remaining = TimeSpan.FromSeconds((double)(deadline - Stopwatch.GetTimestamp()) / Stopwatch.Frequency);
                if (remaining <= TimeSpan.Zero)
                {
                    return;
                }

                if (await Task.WhenAny(read, Task.Delay(remaining)).ConfigureAwait(false) != read)
                {
                    continue;
                }

                var count = await read.ConfigureAwait(false);
                if (count <= 0)
                {
                    return;
                }

                pending.Write(buffer, 0, count);
                maybeLine = buffer.AsSpan(0, count).Contains((byte)10);
                if (pending.Length > EmbedProtocol.MaxLineBytes)
                {
                    throw EmbeddingException.Invalid("Request exceeds 64 MiB");
                }

                read = stdin.ReadAsync(buffer).AsTask();
            }
        }
        finally
        {
            foreach (var embedder in embedders.Values)
            {
                embedder.Dispose();
            }
        }
    }

    private static byte[]? TakeLine(MemoryStream pending)
    {
        var bytes = pending.GetBuffer().AsSpan(0, (int)pending.Length);
        var newline = bytes.IndexOf((byte)10);
        if (newline < 0)
        {
            return null;
        }

        var line = bytes[..newline].ToArray();
        var rest = bytes[(newline + 1)..].ToArray();
        pending.SetLength(0);
        pending.Write(rest);
        return line;
    }

    private static EmbedResponse Handle(byte[] line, string directory, Dictionary<int, Embedder> embedders, BackgroundMode.Status? background)
    {
        EmbedRequest? request = null;
        try
        {
            request = EmbedProtocol.DecodeLine<EmbedRequest>(line);
            if (!EmbedRequest.SupportedDimensions.Contains(request.Dimensions))
            {
                throw EmbeddingException.Invalid("Unsupported dimensions");
            }

            if (!embedders.TryGetValue(request.Dimensions, out var embedder))
            {
                embedder = new Embedder(directory, request.Dimensions);
                embedders[request.Dimensions] = embedder;
            }

            IReadOnlyList<float[]>? vectors;
            switch (request.Operation)
            {
                case "ping" or "status":
                    vectors = null;
                    break;
                case "embedQuery":
                    vectors = embedder.Embed([request.Text ?? throw EmbeddingException.Invalid("embedQuery needs text")], EmbeddingKind.Query);
                    break;
                case "embedDocuments":
                    if (request.Texts is not { Count: <= 1024 } texts)
                    {
                        throw EmbeddingException.Invalid("embedDocuments needs at most 1024 texts");
                    }

                    vectors = embedder.Embed(texts, EmbeddingKind.Document(request.Title));
                    break;
                case "embedImage":
                    byte[] image;
                    try
                    {
                        image = Convert.FromBase64String(request.ImagePng ?? "");
                    }
                    catch (FormatException)
                    {
                        throw EmbeddingException.Invalid("embedImage needs base64 imagePNG");
                    }

                    vectors = [embedder.Embed(image)];
                    break;
                default:
                    throw EmbeddingException.Invalid($"Unknown operation: {request.Operation}");
            }

            var isStatus = request.Operation == "status";
            return EmbedResponse.Create(request.Id, request.Dimensions, vectors, visionLoaded: embedder.VisionLoaded,
                ecoQos: isStatus ? background?.EcoQos : null, belowNormal: isStatus ? background?.BelowNormal : null,
                backgroundMode: isStatus ? background?.BackgroundMode : null);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            return EmbedResponse.Create(request?.Id ?? "", request?.Dimensions ?? 256, error: error.Message,
                visionLoaded: embedders.Values.Any(embedder => embedder.VisionLoaded));
        }
    }
}
