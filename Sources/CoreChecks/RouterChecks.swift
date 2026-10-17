import Core
import Foundation

func checkRouter() throws {
    let root = try checkMakeDirectory("router")
    defer { checkRemoveDirectory(root) }
    let vault = Vault(root: root)
    try vault.prepare()
    // Foo.md has a title that differs from its file name, so "Foo" is not a title match.
    try checkWrite("# Something Else\n", to: root.appendingPathComponent("Foo.md"))
    try checkWrite("# Bar\n", to: root.appendingPathComponent("Bar.md"))
    try checkWrite("# 2026-10-13 Design\n", to: vault.sessionsURL.appendingPathComponent("2026-10-13 Design.md"))
    try checkWrite("# Standup\n", to: vault.sessionsURL.appendingPathComponent("2026-10-13 Standup.md"))
    let notes = try vault.listNotes()
    let standup = Session(
        name: "Standup",
        notePath: "Sessions/2026-10-13 Standup.md",
        startedAt: checkDate(2026, 10, 13, 9, 0)
    )

    func route(_ title: String?, _ session: Session?) -> Destination {
        Router.destination(noteTitle: title, activeSession: session, notes: notes, vault: vault)
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
               "title matches a root note")
    try expect(route("  bar  ", nil), path: "Bar.md", title: "Bar", kind: .note,
               "title match ignores case and extra spaces")
    try expect(route("Something Else", nil), path: "Foo.md", title: "Something Else", kind: .note,
               "title matches a note by its title, not its file name")
    try expect(route("Foo", nil), path: "Foo 2.md", title: "Foo", kind: .note,
               "title with no match targets a new root note, avoiding Foo.md")
    try expect(route("New Thing", nil), path: "New Thing.md", title: "New Thing", kind: .note,
               "unknown title targets a new root note")
    try expect(route("2026-10-13 Design", nil), path: "Sessions/2026-10-13 Design.md",
               title: "2026-10-13 Design", kind: .session,
               "title matches a session note")
    try expect(route("2026-10-13 Design", standup), path: "Sessions/2026-10-13 Design.md",
               title: "2026-10-13 Design", kind: .session,
               "title beats the active session")
    try expect(route("inbox", nil), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "title Inbox matches Inbox.md")
    try expect(route("  INBOX ", standup), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "title Inbox beats the active session")
    try expect(route(nil, standup), path: "Sessions/2026-10-13 Standup.md", title: "Standup", kind: .session,
               "no title uses the active session note")
    try expect(route("   ", standup), path: "Sessions/2026-10-13 Standup.md", title: "Standup", kind: .session,
               "blank title uses the active session note")
    try expect(route(nil, nil), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "no title and no session goes to Inbox")
    try expect(route("", nil), path: "Inbox.md", title: "Inbox", kind: .inbox,
               "empty title and no session goes to Inbox")
    print("Router checks passed.")
}
