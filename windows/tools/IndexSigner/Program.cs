using System.Text;
using CaptureApp.Updates;

namespace CaptureApp.IndexSigner;

internal static class Program
{
    private const string Usage = """
        Usage:
          IndexSigner keygen --out <private-key-file>
          IndexSigner sign (--key-file <file> | --key-env <VAR>) --key-id <id> --channel <channel> <index.json>
          IndexSigner verify --keys "<keyId:base64,...>" --channel <channel> <index.json>
        """;

    private static int Main(string[] args)
    {
        try
        {
            var options = Parse(args.Skip(1).ToArray());
            return args.FirstOrDefault() switch
            {
                "keygen" => KeyGen(options),
                "sign" => Sign(options),
                "verify" => Verify(options),
                _ => Fail(Usage, 2),
            };
        }
        catch (IndexVerificationException error)
        {
            Console.Error.WriteLine($"REFUSED ({error.Reason}): {error.Message}");
            return 1;
        }
        catch (Exception error) when (error is ArgumentException or IOException or FormatException or InvalidOperationException)
        {
            Console.Error.WriteLine($"ERROR: {error.Message}");
            return 2;
        }
    }

    private static int KeyGen(Options options)
    {
        var path = options.Require("--out");
        if (File.Exists(path) || Directory.Exists(path))
        {
            throw new IOException($"{path} already exists; not overwriting.");
        }

        var (seed, publicKey) = IndexSignature.GenerateKeyPair();
        var create = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows())
        {
            create.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        }

        var stream = new FileStream(path, create);
        using (stream)
        {
            stream.Write(Encoding.ASCII.GetBytes(Convert.ToBase64String(seed) + "\n"));
        }

        // Only the public half goes to stdout, ready for WINDOWS_UPDATE_ED_KEYS in Config/app.env.
        Console.WriteLine($"{IndexSignature.KeyIdFor(publicKey)}:{Convert.ToBase64String(publicKey)}");
        return 0;
    }

    private static int Sign(Options options)
    {
        var encoded = options.Get("--key-file") is { } file
            ? File.ReadAllText(file)
            : Environment.GetEnvironmentVariable(options.Require("--key-env"))
              ?? throw new ArgumentException($"Environment variable {options.Get("--key-env")} is not set.");
        var seed = Convert.FromBase64String(encoded.Trim());
        var index = options.Index();
        var signature = IndexSignature.Sign(File.ReadAllBytes(index), options.Require("--channel"), options.Require("--key-id"), seed);
        File.WriteAllText(index + ".sig", signature);
        Console.WriteLine($"Wrote {index}.sig");
        return 0;
    }

    private static int Verify(Options options)
    {
        var index = options.Index();
        var signaturePath = index + ".sig";
        IndexSignature.Verify(
            File.ReadAllBytes(index),
            File.Exists(signaturePath) ? File.ReadAllText(signaturePath) : null,
            options.Require("--channel"),
            TrustedKeys.Parse(options.Require("--keys")));
        Console.WriteLine("OK");
        return 0;
    }

    private static int Fail(string message, int code)
    {
        Console.Error.WriteLine(message);
        return code;
    }

    private static Options Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        string? positional = null;
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i].StartsWith("--", StringComparison.Ordinal))
            {
                values[args[i]] = i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{args[i]} needs a value.");
            }
            else
            {
                positional = args[i];
            }
        }

        return new Options(values, positional);
    }

    private sealed record Options(Dictionary<string, string> Values, string? Positional)
    {
        public string? Get(string name) => Values.GetValueOrDefault(name);

        public string Require(string name) => Get(name) ?? throw new ArgumentException($"Missing {name}.\n{Usage}");

        public string Index() => Positional ?? throw new ArgumentException($"Missing index file.\n{Usage}");
    }
}
