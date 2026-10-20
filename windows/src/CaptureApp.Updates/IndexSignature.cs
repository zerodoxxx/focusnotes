using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;

namespace CaptureApp.Updates;

public enum IndexRejection
{
    MissingSignature,
    MalformedSignature,
    UnsupportedFormat,
    UnknownKey,
    ChannelMismatch,
    InvalidSignature,
}

public sealed class IndexVerificationException(IndexRejection reason, string message) : Exception(message)
{
    public IndexRejection Reason { get; } = reason;
}

/// <summary>
/// The signed update index contract: <c>releases.win-&lt;arch&gt;.json.sig</c> is
/// <c>{format, keyId, channel, signature}</c>; the Ed25519 signature covers
/// <c>captureapp-update-index-v1\n&lt;channel&gt;\n</c> followed by the exact index bytes.
/// </summary>
public static class IndexSignature
{
    public const int Format = 1;
    private const string Domain = "captureapp-update-index-v1\n";

    public static string Sign(ReadOnlySpan<byte> index, string channel, string keyId, ReadOnlySpan<byte> privateSeed)
    {
        var signer = new Ed25519Signer();
        signer.Init(true, new Ed25519PrivateKeyParameters(privateSeed.ToArray(), 0));
        var message = Message(index, channel);
        signer.BlockUpdate(message, 0, message.Length);
        return JsonSerializer.Serialize(new SignatureFile(Format, keyId, channel, Convert.ToBase64String(signer.GenerateSignature())));
    }

    /// <summary>Throws <see cref="IndexVerificationException"/> unless the index is validly signed for <paramref name="channel"/> by a trusted key.</summary>
    public static void Verify(ReadOnlySpan<byte> index, string? signatureJson, string channel, TrustedKeys trusted)
    {
        if (string.IsNullOrWhiteSpace(signatureJson))
        {
            throw new IndexVerificationException(IndexRejection.MissingSignature, "The update index has no signature.");
        }

        SignatureFile file;
        byte[] signature;
        try
        {
            file = JsonSerializer.Deserialize<SignatureFile>(signatureJson) ?? throw new JsonException("null");
            if (string.IsNullOrEmpty(file.KeyId) || string.IsNullOrEmpty(file.Channel) || string.IsNullOrEmpty(file.Signature))
            {
                throw new JsonException("missing field");
            }

            signature = Convert.FromBase64String(file.Signature);
        }
        catch (Exception error) when (error is JsonException or FormatException)
        {
            throw new IndexVerificationException(IndexRejection.MalformedSignature, "The update index signature is malformed.");
        }

        if (file.Format != Format)
        {
            throw new IndexVerificationException(IndexRejection.UnsupportedFormat, $"Unsupported update signature format {file.Format}.");
        }

        if (!trusted.TryGet(file.KeyId, out var publicKey))
        {
            throw new IndexVerificationException(IndexRejection.UnknownKey, $"The update index is signed with an untrusted key '{file.KeyId}'.");
        }

        if (!string.Equals(file.Channel, channel, StringComparison.Ordinal))
        {
            throw new IndexVerificationException(IndexRejection.ChannelMismatch, $"The update index is for channel '{file.Channel}', not '{channel}'.");
        }

        var valid = false;
        try
        {
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(publicKey, 0));
            var message = Message(index, channel);
            verifier.BlockUpdate(message, 0, message.Length);
            valid = verifier.VerifySignature(signature);
        }
        catch (Exception error) when (error is CryptographicException or InvalidOperationException or ArgumentException or Org.BouncyCastle.Crypto.CryptoException)
        {
            valid = false;
        }

        if (!valid)
        {
            throw new IndexVerificationException(IndexRejection.InvalidSignature, "The update index signature is invalid.");
        }
    }

    /// <summary>Generates a new key pair: raw 32-byte seed and public key.</summary>
    public static (byte[] Seed, byte[] PublicKey) GenerateKeyPair()
    {
        var generated = new Ed25519PrivateKeyParameters(new SecureRandom());
        return (generated.GetEncoded(), generated.GeneratePublicKey().GetEncoded());
    }

    /// <summary>Stable short id derived from the public key.</summary>
    public static string KeyIdFor(ReadOnlySpan<byte> publicKey) =>
        "k" + Convert.ToHexString(SHA256.HashData(publicKey))[..8].ToLowerInvariant();

    private static byte[] Message(ReadOnlySpan<byte> index, string channel)
    {
        var prefix = Encoding.UTF8.GetBytes(Domain + channel + "\n");
        var message = new byte[prefix.Length + index.Length];
        prefix.CopyTo(message, 0);
        index.CopyTo(message.AsSpan(prefix.Length));
        return message;
    }

    private sealed record SignatureFile(
        [property: System.Text.Json.Serialization.JsonPropertyName("format")] int Format,
        [property: System.Text.Json.Serialization.JsonPropertyName("keyId")] string KeyId,
        [property: System.Text.Json.Serialization.JsonPropertyName("channel")] string Channel,
        [property: System.Text.Json.Serialization.JsonPropertyName("signature")] string Signature);
}
