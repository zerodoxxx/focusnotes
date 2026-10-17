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
    let relativeName = try NoteTitle.pathName(for: " science / math / trigonometry ")
    try require(relativeName.scope == .vault && relativeName.components == ["science", "math", "trigonometry"],
                "relative note names should preserve their path components")
    try require(relativeName.displayTitle == "trigonometry", "path note display title should use its final component")
    let homeName = try NoteTitle.pathName(for: "/Desktop/science/math/trigonometry")
    try require(homeName.scope == .home && homeName.relativePath == "Desktop/science/math/trigonometry",
                "leading slash should select a home-relative path")
    let sanitizedName = try NoteTitle.pathName(for: "science/math:trig")
    try require(sanitizedName.components == ["science", "math-trig"], "path components should retain filename sanitization")
    let longDisplayName = try NoteTitle.pathName(for: "folder/" + String(repeating: "word ", count: 15))
    try require(longDisplayName.displayTitle.count <= 61 && longDisplayName.displayTitle.hasSuffix("…"),
                "path display titles should keep the existing 60-character cap")
    for invalid in ["", "/", "science/", "science//math", "./math", "science/../math", "math\u{0000}x", "science/~$draft"] {
        try require((try? NoteTitle.pathName(for: invalid)) == nil, "unsafe note path should be rejected: \(invalid.debugDescription)")
    }
    let excessiveDepth = Array(repeating: "x", count: 33).joined(separator: "/")
    try require((try? NoteTitle.pathName(for: excessiveDepth)) == nil, "note path depth should be bounded")
    let longComponent = String(repeating: "x", count: 120)
    let excessiveLength = Array(repeating: longComponent, count: 8).joined(separator: "/")
    try require((try? NoteTitle.pathName(for: excessiveLength)) == nil, "total note path length should be bounded")
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
    print("NoteTitle checks passed.")
}
