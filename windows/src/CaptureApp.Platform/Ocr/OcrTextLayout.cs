using System.Text;

namespace CaptureApp.Platform.Ocr;

/// <summary>Reading order and paragraph joining shared by OCR results from all recognizers.</summary>
public static class OcrTextLayout
{
    public static IReadOnlyList<OcrLine> ReadingOrder(IEnumerable<OcrLine> source)
    {
        var vertical = source.OrderByDescending(line => line.MidY).ThenBy(line => line.MinX).ToList();
        var rows = new List<List<OcrLine>>();
        foreach (var line in vertical)
        {
            if (rows.Count > 0)
            {
                var anchor = rows[^1][0];
                if (Math.Abs(anchor.MidY - line.MidY) <= Math.Min(anchor.Height, line.Height) * 0.5)
                {
                    rows[^1].Add(line);
                    continue;
                }
            }

            rows.Add([line]);
        }

        return rows.SelectMany(row => row.OrderBy(line => line.MinX)).ToArray();
    }

    public static string JoinText(IReadOnlyList<OcrLine> lines)
    {
        if (lines.Count == 0)
        {
            return string.Empty;
        }

        var heights = lines.Select(line => line.Height).Order().ToArray();
        var typicalHeight = heights[heights.Length / 2];
        var output = new StringBuilder();
        for (var index = 0; index < lines.Count; index++)
        {
            if (index > 0)
            {
                var previous = lines[index - 1];
                var current = lines[index];
                var verticalGap = previous.MinY - current.MaxY;
                output.Append(verticalGap > typicalHeight * 1.3 ? "\n\n" : "\n");
            }

            output.Append(lines[index].Text);
        }

        return output.ToString();
    }
}
