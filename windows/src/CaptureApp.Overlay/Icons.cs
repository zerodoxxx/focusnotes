namespace CaptureApp.Overlay;

public static class Icons
{
    // SF Symbol                              Segoe Fluent / MDL2 glyph
    // magnifyingglass                        E721 Search
    // text.alignleft                         E8E4 AlignLeft
    // doc.text                               E8A5 Document
    // checkmark.circle.fill                  E73E Completed
    // exclamationmark.triangle.fill           E7BA Warning
    // record.circle                          E7C8 Record
    // doc.on.doc.fill                         E8C8 Copy
    // xmark                                  E711 Cancel
    // arrow.up.left.and.arrow.down.right      E740 FullScreen
    // rectangle.on.rectangle.angled           E8FD ViewAll
    // square.on.square                       E8FD ViewAll
    // plus                                   E710 Add
    // ellipsis                               E712 More
    // pin.fill / pin.slash                    E718 Pin / E77A UnPin
    // trash                                  E74D Delete
    // folder                                 E8B7 Folder
    // arrow.up.right.square                  E8A7 OpenInNewWindow
    // photo                                  EB9F Photo
    // arrow.triangle.2.circlepath             E72C Refresh (loading)
    public static IReadOnlyDictionary<string, string> Map { get; } = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["magnifyingglass"] = "\uE721", ["text.alignleft"] = "\uE8E4", ["doc.text"] = "\uE8A5",
        ["checkmark.circle.fill"] = "\uE73E", ["exclamationmark.triangle.fill"] = "\uE7BA",
        ["record.circle"] = "\uE7C8", ["doc.on.doc.fill"] = "\uE8C8", ["xmark"] = "\uE711",
        ["arrow.up.left.and.arrow.down.right"] = "\uE740", ["rectangle.on.rectangle.angled"] = "\uE8FD",
        ["square.on.square"] = "\uE8FD", ["plus"] = "\uE710", ["ellipsis"] = "\uE712",
        ["pin.fill"] = "\uE718", ["pin"] = "\uE718", ["doc.on.doc"] = "\uE8C8", ["pin.slash"] = "\uE77A", ["trash"] = "\uE74D",
        ["folder"] = "\uE8B7", ["arrow.up.right.square"] = "\uE8A7", ["photo"] = "\uEB9F",
        ["arrow.triangle.2.circlepath"] = "\uE72C"
    };
    public static string Glyph(string symbol) => Map.TryGetValue(symbol, out var glyph) ? glyph : Map["doc.text"];
}
