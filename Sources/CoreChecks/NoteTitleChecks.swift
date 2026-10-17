import Core
import Foundation

func checkNoteTitle() throws {
    try require(
        NoteTitle.cleanTitle("  Rate   Limiting \n") == "Rate Limiting",
        "cleanTitle should trim and collapse whitespace"
    )
    try require(
        NoteTitle.matchKey("  Rate   Limiting ") == NoteTitle.matchKey("rate limiting"),
        "matchKey should ignore case and extra whitespace"
    )
    try require(
        NoteTitle.matchKey("Caf\u{00E9}") == NoteTitle.matchKey("cafe"),
        "matchKey should ignore diacritics"
    )
    try require(
        NoteTitle.matchKey("Caf\u{0065}\u{0301}") == NoteTitle.matchKey("CAFE"),
        "matchKey should treat decomposed accents the same as composed ones"
    )
    try require(
        NoteTitle.matchKey("Foo") != NoteTitle.matchKey("Foo 2"),
        "matchKey should keep distinct titles distinct"
    )
    try require(NoteTitle.fileStem(for: "a/b:c") == "a-b-c", "fileStem should replace / and :")
    try require(NoteTitle.fileStem(for: "a\\b") == "a-b", "fileStem should replace backslash")
    try require(NoteTitle.fileStem(for: "Plan\u{0007}X") == "Plan-X", "fileStem should replace control characters")
    try require(NoteTitle.fileStem(for: ".hidden") == "hidden", "fileStem should strip leading dots")
    try require(NoteTitle.fileStem(for: "   ") == "Untitled", "a blank title should become Untitled")
    try require(NoteTitle.fileStem(for: "..") == "Untitled", "a dots-only title should become Untitled")
    let longStem = NoteTitle.fileStem(for: String(repeating: "a", count: 200))
    try require(longStem.count == 120, "fileStem should truncate to 120 characters, got \(longStem.count)")
    let root = try checkMakeDirectory("unicode-titles")
    defer { checkRemoveDirectory(root) }
    let vault = Vault(root: root)
    let acceptedCluster = "a" + String(repeating: "\u{0301}", count: 31)
    let rejectedCluster = "a" + String(repeating: "\u{0301}", count: 32)
    let expandingCluster = "a" + String(repeating: "\u{0344}", count: 16)
    try require(NoteTitle.fileStem(for: acceptedCluster) == acceptedCluster, "a representable combining cluster should remain intact")
    try require(NoteTitle.fileStem(for: rejectedCluster) == "Untitled", "an unrepresentable combining cluster should use a safe fallback")
    try require(NoteTitle.fileStem(for: expandingCluster) == "Untitled", "normalization expansion must count toward the combining limit")
    for title in [String(repeating: "👨‍👩‍👧‍👦", count: 40), "a" + String(repeating: "\u{0301}", count: 500), acceptedCluster, rejectedCluster, expandingCluster] {
        let stem = NoteTitle.fileStem(for: title)
        try require(!stem.isEmpty && stem.utf8.count <= 220, "Unicode filename should fit the byte budget")
        let first = vault.uniqueNoteURL(forTitle: title)
        try checkWrite("# Unicode\n", to: first)
        let second = vault.uniqueNoteURL(forTitle: title)
        try require(first != second && second.lastPathComponent.utf8.count <= 255, "Unicode title should allow collision suffixes")
        try checkWrite("# Unicode 2\n", to: second)
    }
    try require(NoteTitle.names("Rate  Limiting", title: "rate limiting", stem: "other"),
                "names should match a title ignoring case and extra spaces")
    try require(NoteTitle.names("foo", title: "Bar", stem: "Foo"), "names should match a file name ignoring case")
    try require(NoteTitle.names("Foo: bar", title: "x", stem: "Foo- bar"),
                "names should match the file name that a title produces")
    try require(!NoteTitle.names("   ", title: "", stem: ""), "a blank query should name nothing")
    print("NoteTitle checks passed.")
}
