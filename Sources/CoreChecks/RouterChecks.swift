import Core
import Foundation

func checkRouter() throws {
    let root = try checkMakeDirectory("router")
    defer { checkRemoveDirectory(root) }
    let vault = Vault(root: root)
    try vault.prepare()
    // Foo.md is titled "Something Else", so "Something Else" matches it by title and "Foo" by file name.
    try checkWrite("# Something Else\n", to: root.appendingPathComponent("Foo.md"))
    try checkWrite("# Bar\n", to: root.appendingPathComponent("Bar.md"))
    // Zed.md is titled "Qux" and Qux.md is titled "Other": "Qux" must match Zed.md by title, not Qux.md by file name.
    try checkWrite("# Qux\n", to: root.appendingPathComponent("Zed.md"))
    try checkWrite("# Other\n", to: root.appendingPathComponent("Qux.md"))
    try checkWrite("# 2026-10-13 Design\n", to: vault.sessionsURL.appendingPathComponent("2026-10-13 Design.md"))
    try checkWrite("# Standup\n", to: vault.sessionsURL.appendingPathComponent("2026-10-13 Standup.md"))
    let notes = try vault.listNotes()
    let standup = Session(
        name: "Standup",
        notePath: "Sessions/2026-10-13 Standup.md",
        startedAt: checkDate(2026, 10, 13, 9, 0)
    )

    func route(_ heading: String?, _ session: Session?) -> Destination {
        Router.destination(heading: heading, activeSession: session, notes: notes, vault: vault)
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

    try expect(route("Bar", nil), path: "Bar.md", title: "Bar", kind: .note,
               "heading matches a root note")
    try expect(route("  bar  ", nil), path: "Bar.md", title: "Bar", kind: .note,
               "heading match ignores case and extra spaces")
    try expect(route("Something Else", nil), path: "Foo.md", title: "Something Else", kind: .note,
               "heading matches a note by its title, not its file name")
    try expect(route("Foo", nil), path: "Foo.md", title: "Something Else", kind: .note,
               "heading matches a note by its file name")
    try expect(route("Qux", nil), path: "Zed.md", title: "Qux", kind: .note,
               "a title match beats a file-name match")
    try expect(route("New Thing", nil), path: "New Thing.md", title: "New Thing", kind: .note,
               "unknown heading targets a new root note")
    try expect(route("2026-10-13 Design", nil), path: "Sessions/2026-10-13 Design.md",
               title: "2026-10-13 Design", kind: .session,
               "heading matches a session note")
    try expect(route("2026-10-13 Design", standup), path: "Sessions/2026-10-13 Design.md",
               title: "2026-10-13 Design", kind: .session,
               "heading beats the active session")
    try expect(route("inbox", nil), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "heading inbox matches Inbox.md")
    try expect(route("  INBOX ", standup), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "heading Inbox beats the active session")
    try expect(route(nil, standup), path: "Sessions/2026-10-13 Standup.md", title: "Standup", kind: .session,
               "no heading uses the active session note")
    try expect(route("   ", standup), path: "Sessions/2026-10-13 Standup.md", title: "Standup", kind: .session,
               "blank heading uses the active session note")
    try expect(route(nil, nil), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "no heading and no session goes to Inbox")
    try expect(route("", nil), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "empty heading and no session goes to Inbox")
    print("Router checks passed.")
}
