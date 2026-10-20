using System.Globalization;

namespace CaptureApp.Updates;

/// <summary>The pinned Ed25519 public keys (key id to raw 32-byte key), parsed from <c>keyId:base64,keyId:base64</c>.</summary>
public sealed class TrustedKeys
{
    private readonly Dictionary<string, byte[]> keys;

    private TrustedKeys(Dictionary<string, byte[]> keys) => this.keys = keys;

    public static TrustedKeys Empty { get; } = new([]);

    public bool IsEmpty => keys.Count == 0;

    public IReadOnlyCollection<string> KeyIds => keys.Keys;

    /// <summary>Blank input gives an empty set (updates disabled); malformed entries throw.</summary>
    public static TrustedKeys Parse(string? list)
    {
        var parsed = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var raw in (list ?? "").Split([',', ';', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var separator = raw.IndexOf(':');
            if (separator <= 0 || separator == raw.Length - 1)
            {
                throw new FormatException($"Update key entry must be <keyId>:<base64 public key>: '{raw}'.");
            }

            var id = raw[..separator].Trim();
            byte[] key;
            try
            {
                key = Convert.FromBase64String(raw[(separator + 1)..].Trim());
            }
            catch (FormatException)
            {
                throw new FormatException(string.Create(CultureInfo.InvariantCulture, $"Update key '{id}' is not valid base64."));
            }

            if (key.Length != 32)
            {
                throw new FormatException($"Update key '{id}' is not a 32-byte Ed25519 public key.");
            }

            if (!parsed.TryAdd(id, key))
            {
                throw new FormatException($"Update key id '{id}' appears more than once.");
            }
        }

        return new TrustedKeys(parsed);
    }

    public bool TryGet(string keyId, out byte[] publicKey)
    {
        if (keys.TryGetValue(keyId, out var found))
        {
            publicKey = found;
            return true;
        }

        publicKey = [];
        return false;
    }
}
