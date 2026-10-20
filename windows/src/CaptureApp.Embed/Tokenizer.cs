using System.Text;
using System.Text.Json;

namespace CaptureApp.Embed;

/// Implements the pinned Gemma tokenizer's literal-space normalizer, Split pre-tokenizer,
/// ranked BPE, byte fallback, added tokens and BOS/EOS template. Immutable after construction.
/// Vocabulary keys are the token's UTF-8 bytes widened to Latin-1 chars, so equality is byte-exact
/// (composed and decomposed accents stay distinct entries).
public sealed class Tokenizer
{
    private readonly record struct Merge(int Rank, long Id);

    private readonly Dictionary<string, long> vocabulary;
    private readonly Dictionary<ulong, Merge> merges;
    private readonly (string Text, long Id)[] special;
    private readonly long[] bytes;

    public Tokenizer(string tokenizerJson)
    {
        var json = File.ReadAllBytes(tokenizerJson);
        List<(string Text, long Id)> specials;
        using (var document = JsonDocument.Parse(json))
        {
            specials = ValidateConfiguration(document.RootElement);
        }

        var reader = new ExactJsonReader(json);
        reader.Field("model");
        reader.Field("vocab");
        vocabulary = reader.Vocabulary();
        var mergeReader = new ExactJsonReader(json);
        mergeReader.Field("model");
        mergeReader.Field("merges");
        var pairs = mergeReader.MergePairs();
        if (!vocabulary.TryGetValue(Latin1("<bos>"), out var bos) || bos != 2 || !vocabulary.TryGetValue(Latin1("<eos>"), out var eos) || eos != 1)
        {
            throw EmbeddingException.Invalid("Invalid BOS/EOS vocabulary IDs");
        }

        merges = new Dictionary<ulong, Merge>(pairs.Count);
        for (var rank = 0; rank < pairs.Count; rank++)
        {
            var (left, right) = pairs[rank];
            if (!vocabulary.TryGetValue(left, out var leftId) || !vocabulary.TryGetValue(right, out var rightId) || !vocabulary.TryGetValue(left + right, out var id))
            {
                throw EmbeddingException.Invalid($"Invalid BPE merge at rank {rank}");
            }

            merges[Pair(leftId, rightId)] = new Merge(rank, id);
        }

        special = [.. specials.OrderByDescending(token => Encoding.UTF8.GetByteCount(token.Text))];
        bytes = new long[256];
        for (var value = 0; value < 256; value++)
        {
            if (!vocabulary.TryGetValue(Latin1($"<0x{value:X2}>"), out bytes[value]))
            {
                throw EmbeddingException.Invalid("Missing byte fallback token");
            }
        }
    }

    private static string Latin1(string ascii) => Encoding.Latin1.GetString(Encoding.UTF8.GetBytes(ascii));

    private static List<(string Text, long Id)> ValidateConfiguration(JsonElement root)
    {
        static bool Is(JsonElement element, string name, string expected) =>
            element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() == expected;
        static bool IsBool(JsonElement element, string name, bool expected) =>
            element.TryGetProperty(name, out var value) && value.ValueKind == (expected ? JsonValueKind.True : JsonValueKind.False);
        static bool IsNull(JsonElement element, string name) =>
            element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Null;
        static bool PatternIsSpace(JsonElement element) =>
            element.TryGetProperty("pattern", out var pattern) && pattern.ValueKind == JsonValueKind.Object && Is(pattern, "String", " ");

        const string Unsupported = "Unsupported tokenizer configuration; expected pinned Gemma BPE";
        if (!root.TryGetProperty("model", out var model) || !Is(model, "type", "BPE") || !IsBool(model, "byte_fallback", true)
            || !IsBool(model, "ignore_merges", false) || !IsNull(model, "dropout") || !IsNull(model, "continuing_subword_prefix")
            || !IsNull(model, "end_of_word_suffix")
            || !root.TryGetProperty("normalizer", out var normalizer) || !Is(normalizer, "type", "Replace") || !Is(normalizer, "content", "▁")
            || !PatternIsSpace(normalizer)
            || !root.TryGetProperty("pre_tokenizer", out var pre) || !Is(pre, "type", "Split") || !PatternIsSpace(pre)
            || !Is(pre, "behavior", "MergedWithPrevious") || !IsBool(pre, "invert", false)
            || !root.TryGetProperty("post_processor", out var post) || !Is(post, "type", "TemplateProcessing")
            || !post.TryGetProperty("single", out var template) || template.ValueKind != JsonValueKind.Array || template.GetArrayLength() != 3
            || !template[0].TryGetProperty("SpecialToken", out var first) || !Is(first, "id", "<bos>")
            || !template[2].TryGetProperty("SpecialToken", out var last) || !Is(last, "id", "<eos>")
            || !root.TryGetProperty("added_tokens", out var added) || added.ValueKind != JsonValueKind.Array)
        {
            throw EmbeddingException.Invalid(Unsupported);
        }

        var specials = new List<(string, long)>();
        foreach (var token in added.EnumerateArray())
        {
            if (!token.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.String
                || !token.TryGetProperty("id", out var id) || !id.TryGetInt64(out var tokenId)
                || !IsBool(token, "single_word", false) || !IsBool(token, "lstrip", false) || !IsBool(token, "rstrip", false)
                || !IsBool(token, "normalized", false))
            {
                throw EmbeddingException.Invalid("Unsupported added token");
            }

            specials.Add((content.GetString()!, tokenId));
        }

        return specials;
    }

    /// maxLength includes BOS/EOS; truncation always retains both template tokens.
    public long[] Encode(string text, int maxLength = 2048)
    {
        if (maxLength < 2)
        {
            throw EmbeddingException.Invalid("maxLength must be at least two");
        }

        var ids = new List<long> { 2 };
        var position = 0;
        while (position < text.Length)
        {
            var earliest = -1;
            long found = 0;
            var length = 0;
            foreach (var token in special)
            {
                var index = text.IndexOf(token.Text, position, StringComparison.Ordinal);
                if (index >= 0 && (earliest < 0 || index < earliest))
                {
                    earliest = index;
                    found = token.Id;
                    length = token.Text.Length;
                }
            }

            if (earliest >= 0)
            {
                ids.AddRange(Bpe(text.AsSpan(position, earliest - position)));
                ids.Add(found);
                position = earliest + length;
            }
            else
            {
                ids.AddRange(Bpe(text.AsSpan(position)));
                break;
            }

            if (ids.Count >= maxLength - 1)
            {
                break;
            }
        }

        var result = new long[Math.Min(ids.Count, maxLength - 1) + 1];
        ids.CopyTo(0, result, 0, result.Length - 1);
        result[^1] = 1;
        return result;
    }

    private static ulong Pair(long a, long b) => (ulong)a << 32 | (ulong)b;

    private long[] Bpe(ReadOnlySpan<char> text)
    {
        // Normalization removes every literal space, so Split(" ") is a no-op.
        var ids = new List<long>(text.Length);
        Span<byte> scratch = stackalloc byte[4];
        Span<char> key = stackalloc char[4];
        foreach (var rune in text.EnumerateRunes())
        {
            var encoded = (rune.Value == 32 ? new Rune(0x2581) : rune).EncodeToUtf8(scratch);
            for (var i = 0; i < encoded; i++)
            {
                key[i] = (char)scratch[i];
            }

            if (vocabulary.TryGetValue(new string(key[..encoded]), out var id))
            {
                ids.Add(id);
            }
            else
            {
                for (var i = 0; i < encoded; i++)
                {
                    ids.Add(bytes[scratch[i]]);
                }
            }
        }

        if (ids.Count <= 1)
        {
            return [.. ids];
        }

        var count = ids.Count;
        var tokens = ids.ToArray();
        var next = new int[count];
        var previous = new int[count];
        var generations = new int[count];
        for (var i = 0; i < count; i++)
        {
            next[i] = i + 1;
            previous[i] = i - 1;
        }

        var heap = new PriorityQueue<Candidate, (int Rank, int Index)>();
        void Offer(int i)
        {
            if (i < 0 || next[i] >= count || tokens[i] < 0 || tokens[next[i]] < 0 || !merges.TryGetValue(Pair(tokens[i], tokens[next[i]]), out var merge))
            {
                return;
            }

            heap.Enqueue(new Candidate(i, next[i], generations[i], generations[next[i]], merge.Id), (merge.Rank, i));
        }

        for (var i = 0; i < count - 1; i++)
        {
            Offer(i);
        }

        while (heap.TryDequeue(out var candidate, out _))
        {
            var i = candidate.Index;
            var j = candidate.Right;
            if (tokens[i] < 0 || tokens[j] < 0 || next[i] != j || generations[i] != candidate.Generation || generations[j] != candidate.RightGeneration)
            {
                continue;
            }

            tokens[i] = candidate.Id;
            tokens[j] = -1;
            generations[i]++;
            generations[j]++;
            next[i] = next[j];
            if (next[j] < count)
            {
                previous[next[j]] = i;
            }

            Offer(previous[i]);
            Offer(i);
        }

        return [.. tokens.Where(id => id >= 0)];
    }

    private readonly record struct Candidate(int Index, int Right, int Generation, int RightGeneration, long Id);

    /// Reads one object's UTF-8 bytes directly so JSON keys are never canonicalized.
    private sealed class ExactJsonReader(byte[] data)
    {
        private int index;

        private void Whitespace()
        {
            while (index < data.Length && data[index] is 9 or 10 or 13 or 32)
            {
                index++;
            }
        }

        private void Expect(byte value)
        {
            Whitespace();
            if (index >= data.Length || data[index] != value)
            {
                throw EmbeddingException.Invalid("Invalid tokenizer JSON");
            }

            index++;
        }

        public void Field(string name)
        {
            Expect((byte)'{');
            while (true)
            {
                Whitespace();
                if (index >= data.Length || data[index] == '}')
                {
                    throw EmbeddingException.Invalid($"Missing JSON field {name}");
                }

                var key = ReadString();
                Expect((byte)':');
                if (key == Latin1(name))
                {
                    return;
                }

                Skip();
                Whitespace();
                if (index < data.Length && data[index] == ',')
                {
                    index++;
                }
                else
                {
                    throw EmbeddingException.Invalid($"Missing JSON field {name}");
                }
            }
        }

        public List<(string, string)> MergePairs()
        {
            Expect((byte)'[');
            var pairs = new List<(string, string)>(515_000);
            while (true)
            {
                Whitespace();
                if (index < data.Length && data[index] == ']')
                {
                    index++;
                    return pairs;
                }

                Expect((byte)'[');
                var left = ReadString();
                Expect((byte)',');
                var right = ReadString();
                Expect((byte)']');
                pairs.Add((left, right));
                Whitespace();
                if (index < data.Length && data[index] == ',')
                {
                    index++;
                }
                else if (index >= data.Length || data[index] != ']')
                {
                    throw EmbeddingException.Invalid("Invalid merges delimiter");
                }
            }
        }

        public Dictionary<string, long> Vocabulary()
        {
            Expect((byte)'{');
            var result = new Dictionary<string, long>(262_144);
            while (true)
            {
                Whitespace();
                if (index < data.Length && data[index] == '}')
                {
                    index++;
                    return result;
                }

                var key = ReadString();
                Expect((byte)':');
                Whitespace();
                var start = index;
                while (index < data.Length && data[index] is >= (byte)'0' and <= (byte)'9')
                {
                    index++;
                }

                if (!long.TryParse(Encoding.ASCII.GetString(data, start, index - start), out var id))
                {
                    throw EmbeddingException.Invalid("Invalid vocabulary token ID");
                }

                result[key] = id;
                Whitespace();
                if (index >= data.Length)
                {
                    throw EmbeddingException.Invalid("Incomplete vocabulary");
                }

                if (data[index] == ',')
                {
                    index++;
                }
                else if (data[index] != '}')
                {
                    throw EmbeddingException.Invalid("Invalid vocabulary delimiter");
                }
            }
        }

        /// Returns the string's UTF-8 bytes widened to Latin-1 chars.
        private string ReadString()
        {
            Expect((byte)'"');
            var output = new List<byte>(16);
            while (index < data.Length)
            {
                var value = data[index++];
                if (value == '"')
                {
                    return Encoding.Latin1.GetString([.. output]);
                }

                if (value != '\\')
                {
                    output.Add(value);
                    continue;
                }

                if (index >= data.Length)
                {
                    break;
                }

                var escape = data[index++];
                switch (escape)
                {
                    case (byte)'"' or (byte)'/' or (byte)'\\': output.Add(escape); break;
                    case (byte)'b': output.Add(8); break;
                    case (byte)'f': output.Add(12); break;
                    case (byte)'n': output.Add(10); break;
                    case (byte)'r': output.Add(13); break;
                    case (byte)'t': output.Add(9); break;
                    case (byte)'u':
                        var code = Hex();
                        if (code is >= 0xD800 and <= 0xDBFF)
                        {
                            if (index + 1 >= data.Length || data[index] != '\\' || data[index + 1] != 'u')
                            {
                                throw EmbeddingException.Invalid("Invalid JSON surrogate pair");
                            }

                            index += 2;
                            var low = Hex();
                            if (low is < 0xDC00 or > 0xDFFF)
                            {
                                throw EmbeddingException.Invalid("Invalid JSON surrogate");
                            }

                            code = 0x10000 + ((code - 0xD800) << 10) + low - 0xDC00;
                        }

                        if (!Rune.IsValid(code))
                        {
                            throw EmbeddingException.Invalid("Invalid JSON Unicode");
                        }

                        output.AddRange(Encoding.UTF8.GetBytes(new Rune(code).ToString()));
                        break;
                    default:
                        throw EmbeddingException.Invalid("Invalid JSON escape");
                }
            }

            throw EmbeddingException.Invalid("Unterminated JSON string");
        }

        private static string Latin1(string ascii) => Encoding.Latin1.GetString(Encoding.UTF8.GetBytes(ascii));

        private int Hex()
        {
            if (index + 4 > data.Length || !int.TryParse(Encoding.ASCII.GetString(data, index, 4), System.Globalization.NumberStyles.AllowHexSpecifier, null, out var value))
            {
                throw EmbeddingException.Invalid("Invalid JSON hex escape");
            }

            index += 4;
            return value;
        }

        private void Skip()
        {
            Whitespace();
            if (index >= data.Length)
            {
                throw EmbeddingException.Invalid("Incomplete JSON value");
            }

            if (data[index] == '"')
            {
                ReadString();
                return;
            }

            if (data[index] is (byte)'{' or (byte)'[')
            {
                var end = data[index] == '{' ? (byte)'}' : (byte)']';
                index++;
                while (true)
                {
                    Whitespace();
                    if (index >= data.Length)
                    {
                        throw EmbeddingException.Invalid("Incomplete JSON container");
                    }

                    if (data[index] == end)
                    {
                        index++;
                        return;
                    }

                    if (data[index] is (byte)',' or (byte)':')
                    {
                        index++;
                    }
                    else
                    {
                        Skip();
                    }
                }
            }

            while (index < data.Length && data[index] is not (9 or 10 or 13 or 32 or (byte)',' or (byte)']' or (byte)'}'))
            {
                index++;
            }
        }
    }
}
