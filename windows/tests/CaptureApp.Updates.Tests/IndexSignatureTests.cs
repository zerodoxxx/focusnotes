using System.Text;
using CaptureApp.Updates;
using Xunit;

namespace CaptureApp.Updates.Tests;

public sealed class IndexSignatureTests
{
    private const string Channel = "win-x64";
    private static readonly byte[] Index = Encoding.UTF8.GetBytes("{\"Assets\":[{\"PackageId\":\"x\"}]}");

    private static (byte[] Seed, string Entry, string Id) NewKey()
    {
        var (seed, publicKey) = IndexSignature.GenerateKeyPair();
        var id = IndexSignature.KeyIdFor(publicKey);
        return (seed, $"{id}:{Convert.ToBase64String(publicKey)}", id);
    }

    private static IndexRejection Rejection(Action action) =>
        Assert.Throws<IndexVerificationException>(action).Reason;

    [Fact]
    public void RoundTripVerifies()
    {
        var k1 = NewKey();
        var signature = IndexSignature.Sign(Index, Channel, k1.Id, k1.Seed);
        IndexSignature.Verify(Index, signature, Channel, TrustedKeys.Parse(k1.Entry));
    }

    [Fact]
    public void SignatureFileHasTheContractFields()
    {
        var k1 = NewKey();
        using var json = System.Text.Json.JsonDocument.Parse(IndexSignature.Sign(Index, Channel, k1.Id, k1.Seed));
        Assert.Equal(1, json.RootElement.GetProperty("format").GetInt32());
        Assert.Equal(k1.Id, json.RootElement.GetProperty("keyId").GetString());
        Assert.Equal(Channel, json.RootElement.GetProperty("channel").GetString());
        Assert.Equal(64, Convert.FromBase64String(json.RootElement.GetProperty("signature").GetString()!).Length);
    }

    [Fact]
    public void TamperedByteIsRefused()
    {
        var k1 = NewKey();
        var signature = IndexSignature.Sign(Index, Channel, k1.Id, k1.Seed);
        var tampered = (byte[])Index.Clone();
        tampered[5] ^= 1;
        Assert.Equal(IndexRejection.InvalidSignature, Rejection(() => IndexSignature.Verify(tampered, signature, Channel, TrustedKeys.Parse(k1.Entry))));
    }

    [Fact]
    public void UnknownKeyIsRefused()
    {
        var k1 = NewKey();
        var stranger = NewKey();
        var signature = IndexSignature.Sign(Index, Channel, stranger.Id, stranger.Seed);
        Assert.Equal(IndexRejection.UnknownKey, Rejection(() => IndexSignature.Verify(Index, signature, Channel, TrustedKeys.Parse(k1.Entry))));
    }

    [Fact]
    public void KeyIdClaimingATrustedKeyWithAnotherSignerIsInvalid()
    {
        var k1 = NewKey();
        var stranger = NewKey();
        var signature = IndexSignature.Sign(Index, Channel, k1.Id, stranger.Seed);
        Assert.Equal(IndexRejection.InvalidSignature, Rejection(() => IndexSignature.Verify(Index, signature, Channel, TrustedKeys.Parse(k1.Entry))));
    }

    [Fact]
    public void RotationAcceptsEitherKeyAndRefusesADroppedOne()
    {
        var k1 = NewKey();
        var k2 = NewKey();
        var both = TrustedKeys.Parse($"{k1.Entry},{k2.Entry}");
        IndexSignature.Verify(Index, IndexSignature.Sign(Index, Channel, k1.Id, k1.Seed), Channel, both);
        IndexSignature.Verify(Index, IndexSignature.Sign(Index, Channel, k2.Id, k2.Seed), Channel, both);

        var onlyK2 = TrustedKeys.Parse(k2.Entry);
        Assert.Equal(IndexRejection.UnknownKey, Rejection(() => IndexSignature.Verify(Index, IndexSignature.Sign(Index, Channel, k1.Id, k1.Seed), Channel, onlyK2)));
    }

    [Fact]
    public void ChannelMismatchIsRefused()
    {
        var k1 = NewKey();
        var signature = IndexSignature.Sign(Index, "win-arm64", k1.Id, k1.Seed);
        Assert.Equal(IndexRejection.ChannelMismatch, Rejection(() => IndexSignature.Verify(Index, signature, Channel, TrustedKeys.Parse(k1.Entry))));
    }

    [Fact]
    public void RelabelledChannelFailsTheSignature()
    {
        var k1 = NewKey();
        var signature = IndexSignature.Sign(Index, "win-arm64", k1.Id, k1.Seed).Replace("win-arm64", Channel, StringComparison.Ordinal);
        Assert.Equal(IndexRejection.InvalidSignature, Rejection(() => IndexSignature.Verify(Index, signature, Channel, TrustedKeys.Parse(k1.Entry))));
    }

    [Theory]
    [InlineData(null, IndexRejection.MissingSignature)]
    [InlineData("", IndexRejection.MissingSignature)]
    [InlineData("not json", IndexRejection.MalformedSignature)]
    [InlineData("{\"format\":1,\"keyId\":\"a\",\"channel\":\"win-x64\",\"signature\":\"!!\"}", IndexRejection.MalformedSignature)]
    [InlineData("{\"format\":2,\"keyId\":\"a\",\"channel\":\"win-x64\",\"signature\":\"AAAA\"}", IndexRejection.UnsupportedFormat)]
    public void BadSignatureFilesAreRefused(string? signature, IndexRejection expected)
    {
        var k1 = NewKey();
        Assert.Equal(expected, Rejection(() => IndexSignature.Verify(Index, signature, Channel, TrustedKeys.Parse(k1.Entry))));
    }

    [Fact]
    public void EmptyKeySetMeansNothingIsTrusted()
    {
        Assert.True(TrustedKeys.Parse("  ").IsEmpty);
        Assert.True(TrustedKeys.Parse(null).IsEmpty);
        var k1 = NewKey();
        Assert.Equal(IndexRejection.UnknownKey, Rejection(() => IndexSignature.Verify(Index, IndexSignature.Sign(Index, Channel, k1.Id, k1.Seed), Channel, TrustedKeys.Empty)));
    }

    [Fact]
    public void DuplicateKeyIdThrows()
    {
        var a = NewKey();
        var b = NewKey();
        Assert.Throws<FormatException>(() => TrustedKeys.Parse($"{a.Entry},{a.Id}:{b.Entry[(b.Entry.IndexOf(':') + 1)..]}"));
    }

    [Theory]
    [InlineData("nocolon")]
    [InlineData("id:***")]
    [InlineData("id:AAAA")]
    public void MalformedKeyListThrows(string list) => Assert.Throws<FormatException>(() => TrustedKeys.Parse(list));
}
