@_spi(Checks) import Core
import Foundation

func checkCaptureMoveParsing() async throws {
    func verify(_ value: Bool, _ message: String) throws { try require(value, message) }
    let base = try checkMakeDirectory("capture-move-parsing")
    defer { checkRemoveDirectory(base) }
    let vault = Vault(root: base.appendingPathComponent("Vault"))
    let calendar = checkCalendar()
    let now = checkDate(2026, 10, 13, 10, 0)
    let writer = NoteWriter(vault: vault, calendar: calendar)
    let sessions = SessionStore(stateDirectory: base.appendingPathComponent("State"), vault: vault,
                                calendar: calendar, now: { now })
    let service = CaptureService(vault: vault, sessions: sessions, writer: writer, now: { now })
    func note(_ path: String) -> Destination {
        Destination(url: vault.root.appendingPathComponent(path + ".md"), title: path, kind: .note)
    }
    func save(_ id: UUID, _ body: String, to destination: Destination) async throws {
        let capture = Capture(id: id, createdAt: now, content: .text(body), source: CaptureSource(appName: "Safari"))
        _ = try await service.save(PreparedCapture(capture: capture, destination: destination))
    }

    // Fenced code is text: a `# comment` inside the fence neither ends the block nor counts as a heading.
    let fenced = note("Fenced"), fencedTarget = note("Fenced target")
    let fencedID = UUID(), followingID = UUID()
    try await save(fencedID, "```swift\n# comment\n## not a heading\n```\nafter fence", to: fenced)
    try await save(followingID, "following capture", to: fenced)
    _ = try await service.moveCapture(id: fencedID, from: fenced, to: fencedTarget)
    let fencedRemaining = try checkRead(fenced.url), fencedMoved = try checkRead(fencedTarget.url)
    try verify(fencedMoved.contains("```swift\n# comment\n## not a heading\n```\nafter fence"), "moved block keeps the whole fenced code")
    try verify(!fencedRemaining.contains("# comment") && !fencedRemaining.contains("after fence") && fencedRemaining.contains("following capture"), "source keeps only the capture after the fence")

    // A heading-looking line inside a fence must not be taken as the governing source heading.
    let headed = note("Headed"), headedTarget = note("Headed target")
    let headedID = UUID()
    try checkWrite("### Real\n```md\n### fake\n```\n\(checkCaptureMarker(headedID)) -->\nheaded body\n", to: headed.url)
    _ = try await service.moveCapture(id: headedID, from: headed, to: headedTarget)
    let headedMoved = try checkRead(headedTarget.url)
    try verify(headedMoved.contains("### Real") && !headedMoved.contains("### fake"), "heading lookup skips fenced headings")

    // A failed append leaves a marker-only fragment before the complete occurrence; the complete body moves.
    let replay = note("Replay"), replayTarget = note("Replay target")
    let replayID = UUID()
    let replayMarker = checkCaptureMarker(replayID) + " -->"
    try checkWrite("### Safari\n\(replayMarker)\n\(replayMarker)\nreplayed body\n", to: replay.url)
    _ = try await service.moveCapture(id: replayID, from: replay, to: replayTarget)
    let replayRemaining = try checkRead(replay.url), replayMoved = try checkRead(replayTarget.url)
    try verify(replayMoved.contains("replayed body") && checkCount(replayMarker, in: replayMoved) == 1, "moved block is the complete occurrence")
    try verify(checkCount(replayMarker, in: replayRemaining) == 1 && !replayRemaining.contains("replayed body"), "fragment stays in the source")

    // A suffix-less marker is a fragment, not an occurrence, even when a body line follows it.
    let partial = note("Partial"), partialTarget = note("Partial target")
    let partialID = UUID()
    let partialMarker = checkCaptureMarker(partialID)
    try checkWrite("### Safari\n\(partialMarker) -->\ncomplete body\n\(partialMarker) --\nfragment body\n", to: partial.url)
    _ = try await service.moveCapture(id: partialID, from: partial, to: partialTarget)
    let partialRemaining = try checkRead(partial.url), partialMoved = try checkRead(partialTarget.url)
    try verify(partialMoved.contains("complete body") && !partialMoved.contains("fragment body"), "destination gets the complete occurrence")
    try verify(partialRemaining.contains("\(partialMarker) --\nfragment body"), "suffix-less fragment stays in the source")

    // Titled image links rewrite only the path; the title and alt text are kept byte-for-byte.
    let titled = note("Titled"), titledTarget = note("Sessions/Target")
    let titledID = UUID()
    try await save(titledID, "![one](assets/a.png \"Diagram\") ![two](<assets/b c.png> \"Second\") ![three](assets/c.png 'Single') ![four](assets/d.png (Paren))", to: titled)
    _ = try await service.moveCapture(id: titledID, from: titled, to: titledTarget)
    let titledMoved = try checkRead(titledTarget.url)
    try verify(titledMoved.contains("![one](../assets/a.png \"Diagram\")") && titledMoved.contains("![two](<../assets/b%20c.png> \"Second\")")
        && titledMoved.contains("![three](../assets/c.png 'Single')") && titledMoved.contains("![four](../assets/d.png (Paren))"), "titled image links keep their titles and rewrite only the path")
    print("Capture move parsing checks passed.")
}
