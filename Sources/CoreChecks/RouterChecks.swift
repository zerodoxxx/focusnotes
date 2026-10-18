import Core
import Foundation

func checkRouter() throws {
    let base = try checkMakeDirectory("router")
    defer { checkRemoveDirectory(base) }
    let root = base.appendingPathComponent("Vault", isDirectory: true)
    let home = base.appendingPathComponent("Home", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let vault = Vault(root: root, homeDirectoryURL: home)
    try vault.prepare()
    // Foo.md has a title that differs from its file name; a filename collision still appends.
    try checkWrite("# Something Else\n", to: root.appendingPathComponent("Foo.md"))
    try checkWrite("# Bar\n", to: root.appendingPathComponent("Bar.md"))
    let nestedDirectory = root.appendingPathComponent("Science/Math", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try checkWrite("# Existing nested note\n", to: nestedDirectory.appendingPathComponent("Trigonometry.md"))
    try checkWrite("# 2026-10-13 Design\n", to: vault.sessionsURL.appendingPathComponent("2026-10-13 Design.md"))
    try checkWrite("# Standup\n", to: vault.sessionsURL.appendingPathComponent("2026-10-13 Standup.md"))
    let notes = try vault.listNotes()
    let standup = Session(
        name: "Standup",
        notePath: "Sessions/2026-10-13 Standup.md",
        startedAt: checkDate(2026, 10, 13, 9, 0)
    )

    func route(_ noteTitle: String?, _ session: Session?) throws -> Destination {
        try Router.destination(noteTitle: noteTitle, activeSession: session, notes: notes, vault: vault)
    }

    func expect(
        _ destination: Destination,
        path: String,
        title: String,
        kind: NoteKind,
        _ label: String
    ) throws {
        let expectedPath = root.resolvingSymlinksInPath().path + "/" + path
        try require(destination.url.resolvingSymlinksInPath().path == expectedPath, "\(label): url was \(destination.url.path)")
        try require(destination.title == title, "\(label): title was \(destination.title)")
        try require(destination.kind == kind, "\(label): kind was \(checkKindName(destination.kind))")
    }

    try expect(try route("Bar", nil), path: "Bar.md", title: "Bar", kind: .note,
               "heading matches a root note")
    try expect(try route("  bar  ", nil), path: "Bar.md", title: "Bar", kind: .note,
               "heading match ignores case and extra spaces")
    try expect(try route("Something Else", nil), path: "Foo.md", title: "Something Else", kind: .note,
               "heading matches a note by its title, not its file name")
    try expect(try route("Foo", nil), path: "Foo.md", title: "Foo", kind: .note,
               "unmatched heading appends to an existing filename rather than replacing it")
    try expect(try route("New Thing", nil), path: "New Thing.md", title: "New Thing", kind: .note,
               "unknown heading targets a new root note")
    try expect(try route("2026-10-13 Design", nil), path: "Sessions/2026-10-13 Design.md",
               title: "2026-10-13 Design", kind: .session,
               "heading matches a session note")
    try expect(try route("2026-10-13 Design", standup), path: "Sessions/2026-10-13 Design.md",
               title: "2026-10-13 Design", kind: .session,
               "heading beats the active session")
    try expect(try route("inbox", nil), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "heading inbox matches Inbox.md")
    try expect(try route("  INBOX ", standup), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "heading Inbox beats the active session")
    try expect(try route(nil, standup), path: "Sessions/2026-10-13 Standup.md", title: "Standup", kind: .session,
               "no heading uses the active session note")
    try expect(try route("   ", standup), path: "Sessions/2026-10-13 Standup.md", title: "Standup", kind: .session,
               "blank heading uses the active session note")
    try expect(try route(nil, nil), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "no heading and no session goes to Inbox")
    try expect(try route("", nil), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "empty heading and no session goes to Inbox")

    try expect(try route("science/math/trigonometry", nil), path: "Science/Math/Trigonometry.md",
               title: "trigonometry", kind: .note, "path heading reuses folders and file case-insensitively")
    try expect(try route("science/math/new branch", nil), path: "Science/Math/new branch.md",
               title: "new branch", kind: .note, "unmatched nested heading resolves beneath existing folders")
    do {
        _ = try route("science/../escape", nil)
        throw CheckFailure.failed("path traversal heading was accepted")
    } catch is NotePathNameError {}
    let homeHeading = "/CodexRouter-\(UUID().uuidString)/science/math/trigonometry"
    let homeDestination = try route(homeHeading, nil)
    try require(homeDestination.url.path.hasPrefix(home.path + "/CodexRouter-"),
                "leading slash heading should resolve under the user's home directory")
    try require(homeDestination.title == "trigonometry", "home-relative destination title should use its final path component")
    print("Router checks passed.")
}
