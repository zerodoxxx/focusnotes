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
    let archive = root.appendingPathComponent("Archive", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try checkWrite("# Standup\n", to: archive.appendingPathComponent("Old.md"))
    try checkWrite("# Twin\n", to: root.appendingPathComponent("Twin A.md"))
    try checkWrite("# Twin\n", to: root.appendingPathComponent("Twin B.md"))
    try checkWrite("# Twin\n", to: vault.sessionsURL.appendingPathComponent("Twin Session.md"))
    try checkWrite("# Repeated session\n", to: vault.sessionsURL.appendingPathComponent("Repeated A.md"))
    try checkWrite("# Repeated session\n", to: vault.sessionsURL.appendingPathComponent("archive/Repeated B.md"))
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
    try expect(try route("Standup", nil), path: "Sessions/2026-10-13 Standup.md", title: "Standup", kind: .session,
               "a nested note heading must not hijack a bare capture title")
    try expect(try route("Old", nil), path: "Old.md", title: "Old", kind: .note,
               "a nested note filename must not match a bare capture title")
    try expect(try route("pros / cons", nil), path: "pros - cons.md", title: "pros / cons", kind: .note,
               "capture names with legacy flat slashes should match typed-note filenames")
    let externalMatch = home.appendingPathComponent("Remote.md")
    try checkWrite("# Remote\n", to: externalMatch)
    let externalRef = NoteRef(url: externalMatch, title: "Remote", kind: .note)
    let remoteRoute = try Router.destination(noteTitle: "Remote", activeSession: nil,
                                             notes: notes + [externalRef], vault: vault)
    try require(remoteRoute.url == root.appendingPathComponent("Remote.md") && remoteRoute.kind == .note,
                "an external HOME note heading must not match a bare capture title")
    for (title, expectedPaths, expectedKind) in [
        ("Twin", ["Twin A.md", "Twin B.md"], NoteKind.note),
        ("Repeated session", ["Sessions/Repeated A.md", "Sessions/archive/Repeated B.md"], NoteKind.session)
    ] {
        do {
            _ = try route(title, nil)
            throw CheckFailure.failed("duplicate \(expectedKind) headings must request an explicit choice")
        } catch RouterError.ambiguous(let candidates) {
            let paths = candidates.map { $0.url.path.replacingOccurrences(of: root.path + "/", with: "") }
            try require(candidates.allSatisfy { $0.kind == expectedKind }, "ambiguous \(expectedKind) headings returned another destination kind")
            try require(paths == expectedPaths.sorted(), "ambiguous headings must have stable path order: \(paths)")
        }
    }
    try expect(try route("Foo", nil), path: "Foo.md", title: "Foo", kind: .note,
               "unmatched heading appends to an existing filename rather than replacing it")
    try expect(try route("New Thing", nil), path: "New Thing.md", title: "New Thing", kind: .note,
               "unknown heading targets a new root note")
    try expect(try route("Biology", standup), path: "Biology.md", title: "Biology", kind: .note,
               "outside-session capture can create a named note while a session is active")
    try expect(try route("Bar", standup), path: "Bar.md", title: "Bar", kind: .note,
               "outside-session capture can append to an existing note while a session is active")
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
    try expect(try route("science/math/Biology", standup), path: "Science/Math/Biology.md",
               title: "Biology", kind: .note, "outside-session capture preserves a chosen folder path")
    do {
        _ = try route("science/../escape", nil)
        throw CheckFailure.failed("path traversal heading was accepted")
    } catch is NotePathNameError {}
    let homeHeading = "/CodexRouter-\(UUID().uuidString)/science/math/trigonometry"
    let homeDestination = try route(homeHeading, standup)
    try require(homeDestination.url.path.hasPrefix(home.path + "/CodexRouter-"),
                "leading slash heading should resolve under the user's home directory")
    try require(homeDestination.title == "trigonometry", "home-relative destination title should use its final path component")
    print("Router checks passed.")
}
