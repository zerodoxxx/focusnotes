import Core
import Foundation

/// JSON values stay language-neutral; no encoded Swift enum representation enters fixtures.
private enum FixtureValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case array([FixtureValue]), object([String: FixtureValue])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([FixtureValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: FixtureValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .string(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        }
    }

    var text: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? { if case .number(let value) = self { Int(exactly: value) } else { nil } }
    var flag: Bool? { if case .bool(let value) = self { value } else { nil } }
}

private struct ConformanceScenario: Codable {
    let id: String
    let area: String
    let description: String
    let input: Input
    var expected: Expected?

    struct Input: Codable {
        let clock: String
        let timeZone: String
        let files: [String: String]
        let ops: [[String: FixtureValue]]
    }

    struct Expected: Codable, Equatable {
        let files: [String: String]
        let results: [FixtureValue]
    }
}

private extension Dictionary where Key == String, Value == FixtureValue {
    func string(_ key: String) throws -> String {
        guard let value = self[key]?.text else { throw CheckFailure.failed("Missing string argument: \(key)") }
        return value
    }
}

private let conformanceOperations: [String: Set<String>] = [
    "notetitle": ["cleanTitle", "matchKey", "fileStem", "pathName"],
    "router": ["route"],
    "captureformat": ["block", "sourceHeading", "noteHeader", "noteBody", "cleanSubheading"],
    "notewriter": ["append", "appendIfMissing"],
    "vault-naming": ["pathName", "resolve", "unique", "list"],
    "sessionstore": ["start", "current", "end", "reload", "persisted", "writeState", "resume"],
    "noteparser": ["parse"],
    "searchindex": ["sync", "query", "reindex"],
    "capturedestination": ["startSession", "resolve", "existingTitle"]
]
private let commonConformanceOperations: Set<String> = ["prepare", "write", "read", "remove"]

private func fixtureDate(_ value: String) throws -> Date {
    guard value.hasSuffix("Z"), let date = ISO8601DateFormatter().date(from: value) else {
        throw CheckFailure.failed("Expected a whole-second ISO-8601 UTC instant: \(value)")
    }
    return date
}

private func fixtureString(_ value: String?) -> FixtureValue { value.map(FixtureValue.string) ?? .null }
private func fixtureStamp(_ value: Date?) -> FixtureValue {
    fixtureString(value.map { ISO8601DateFormatter().string(from: $0) })
}

private func fixtureSession(_ session: Session?) -> FixtureValue {
    guard let session else { return .null }
    return .object([
        "name": .string(session.name), "notePath": .string(session.notePath),
        "startedAt": fixtureStamp(session.startedAt), "resumed": session.resumed.map(FixtureValue.bool) ?? .null
    ])
}

/// Unknown errors fail the harness. Only known Core error kinds become portable results.
private func fixtureError(_ error: any Error) throws -> FixtureValue {
    let kind: String
    switch error {
    case let error as NotePathNameError:
        kind = switch error {
        case .emptyPath: "emptyPath"
        case .invalidComponent: "invalidComponent"
        case .tooDeep: "tooDeep"
        case .tooLong: "tooLong"
        }
    case let error as SessionStoreError:
        kind = switch error {
        case .ambiguous: "ambiguousSession"
        case .candidateNoLongerExists: "candidateNoLongerExists"
        case .invalidRename, .renameConflict, .caseOnlyRename: throw error
        }
    case let error as CocoaError where error.code == .fileWriteInvalidFileName:
        kind = "invalidFileName"
    default: throw error
    }
    return .object(["error": .string(kind)])
}

/// Every fixture gets isolated vault, fake HOME, state, and disposable index directories.
private final class ConformanceExecution {
    let base: URL
    let root: URL
    let home: URL
    let state: URL
    let vault: Vault
    let calendar: Calendar
    let clock: Date
    let writer: NoteWriter
    var sessions: SessionStore
    var index: SearchIndex?
    var service: CaptureService?

    init(input: ConformanceScenario.Input) throws {
        clock = try fixtureDate(input.clock)
        guard let timeZone = TimeZone(identifier: input.timeZone) else {
            throw CheckFailure.failed("Unknown IANA time zone: \(input.timeZone)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        base = try checkMakeDirectory("conformance")
        root = base.appendingPathComponent("vault", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        state = base.appendingPathComponent("state", isDirectory: true)
        vault = Vault(root: root, homeDirectoryURL: home)
        writer = NoteWriter(vault: vault, calendar: calendar)
        let fixedClock = clock
        sessions = SessionStore(stateDirectory: state, vault: vault, calendar: calendar, now: { fixedClock })
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for path in input.files.keys.sorted() {
                guard !path.hasPrefix("/") else { throw CheckFailure.failed("Input files must be vault-relative") }
                try write(input.files[path]!, path: path)
            }
        } catch {
            checkRemoveDirectory(base)
            throw error
        }
    }

    deinit { checkRemoveDirectory(base) }

    /// A leading slash in operation paths denotes the isolated fake HOME, never the host root.
    func url(_ path: String) throws -> URL {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !path.contains("\\"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CheckFailure.failed("Unsafe fixture file path: \(path.debugDescription)")
        }
        return (path.hasPrefix("/") ? home : root).appendingPathComponent(relative)
    }

    func write(_ text: String, path: String) throws {
        let target = try url(path)
        try checkWrite(text, to: target)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: target.path)
    }

    func path(_ url: URL) throws -> String {
        let standardized = url.standardizedFileURL.path
        for (base, prefix) in [(root, ""), (home, "/")] {
            let basePath = base.standardizedFileURL.path + "/"
            if standardized.hasPrefix(basePath) { return prefix + String(standardized.dropFirst(basePath.count)) }
        }
        throw CheckFailure.failed("Core returned a path outside the fixture sandbox")
    }

    func capture(_ op: [String: FixtureValue]) throws -> Capture {
        let idText = op["id"]?.text ?? "00000000-0000-4000-8000-000000000001"
        guard let id = UUID(uuidString: idText) else { throw CheckFailure.failed("Invalid capture UUID") }
        let value = op["text"]?.text ?? ""
        let content: CaptureContent
        switch op["content"]?.text ?? "text" {
        case "text": content = .text(value)
        case "note": content = .note(value)
        case "subheading": content = .subheading(value)
        case "image": content = .image(assetPath: try op.string("assetPath"))
        default: throw CheckFailure.failed("Unknown capture content")
        }
        return Capture(id: id, createdAt: try op["at"]?.text.map(fixtureDate) ?? clock, content: content,
                       source: CaptureSource(appName: op["app"]?.text, windowTitle: op["window"]?.text))
    }

    func searchIndex() throws -> SearchIndex {
        if let index { return index }
        let created = try SearchIndex(vault: vault, databaseURL: base.appendingPathComponent("index/cache.sqlite"), calendar: calendar)
        index = created
        return created
    }

    func captureService() -> CaptureService {
        if let service { return service }
        let fixedClock = clock
        let created = CaptureService(vault: vault, sessions: sessions, writer: writer, now: { fixedClock })
        service = created
        return created
    }

    func intent(_ op: [String: FixtureValue]) throws -> CaptureIntent {
        guard op["title"] == nil || op["pick"] == nil else { throw CheckFailure.failed("title and pick are mutually exclusive") }
        let target: CaptureIntent.Target
        if let title = op["title"]?.text { target = .title(title) }
        else if let pick = op["pick"]?.text {
            let kind: NoteKind
            switch op["pickKind"]?.text ?? "note" {
            case "note": kind = .note
            case "session": kind = .session
            case "inbox": kind = .inbox
            default: throw CheckFailure.failed("Unknown pickKind")
            }
            target = .pick(NotePick(noteID: pick, title: URL(fileURLWithPath: pick).deletingPathExtension().lastPathComponent, kind: kind))
        } else { target = .automatic }
        return CaptureIntent(target, outsideSession: op["outsideSession"]?.flag ?? false,
                             folder: try op["folder"]?.text.map { try NoteFolder(rawValue: $0) }, newNote: op["newNote"]?.flag ?? false)
    }

    func execute(_ op: [String: FixtureValue], area: String) async throws -> FixtureValue {
        let name = try op.string("op")
        guard commonConformanceOperations.contains(name) || conformanceOperations[area]?.contains(name) == true else {
            throw CheckFailure.failed("Unknown operation \(area)/\(name)")
        }
        do { return try await perform(name, op: op, area: area) }
        catch { return try fixtureError(error) }
    }

    private func perform(_ name: String, op: [String: FixtureValue], area: String) async throws -> FixtureValue {
        if area == "capturedestination" {
            switch name {
            case "startSession": _ = try await sessions.start(name: op.string("name")); return .null
            case "resolve":
                let intent = try intent(op)
                let prepared: PreparedCapture
                do { prepared = try await captureService().resolve(capture(op), intent: intent, calendar: calendar) }
                catch let error as CocoaError where error.code == .fileNoSuchFile && op["pick"] != nil {
                    // A picked note that no longer exists; elsewhere this error fails the harness.
                    return .object(["error": .string("noteNotFound")])
                }
                return .object(["path": .string(try path(prepared.destination.url)), "title": .string(prepared.destination.title),
                                "kind": .string(checkKindName(prepared.destination.kind)),
                                "createsNote": .bool(prepared.createsNote == true)])
            case "existingTitle":
                return fixtureString(captureService().existingTitle(forTypedNote: try op.string("text"), intent: try intent(op),
                                                                    calendar: calendar))
            default: break
            }
        }
        switch name {
        case "prepare": try vault.prepare(); return .null
        case "write": try write(op.string("text"), path: op.string("path")); return .null
        case "read": return .string(try checkRead(url(op.string("path"))))
        case "remove": try FileManager.default.removeItem(at: url(op.string("path"))); return .null
        case "cleanTitle": return .string(NoteTitle.cleanTitle(try op.string("text")))
        case "matchKey": return .string(NoteTitle.matchKey(try op.string("text")))
        case "fileStem": return .string(NoteTitle.fileStem(for: try op.string("text")))
        case "pathName":
            let result = try NoteTitle.pathName(for: op.string("text"))
            return .object(["scope": .string(result.scope.rawValue),
                            "components": .array(result.components.map(FixtureValue.string)),
                            "relativePath": .string(result.relativePath), "displayTitle": .string(result.displayTitle)])
        case "resolve":
            let result = try vault.resolveNoteName(op.string("text"))
            return .object(["scope": .string(result.scope.rawValue), "relativePath": .string(result.relativePath)])
        case "unique": return .string(try path(vault.uniqueNoteURL(forTitle: op.string("text"))))
        case "list":
            return .array(try vault.listNotes().map { note in
                .object(["path": .string(try path(note.url)), "title": .string(note.title),
                         "kind": .string(checkKindName(note.kind))])
            })
        case "route":
            var active: Session?
            if let sessionPath = op["sessionPath"]?.text {
                active = Session(name: op["sessionName"]?.text ?? "Session", notePath: sessionPath, startedAt: clock)
            }
            let result = try Router.destination(noteTitle: op["title"]?.text, activeSession: active,
                                                notes: vault.listNotes(), vault: vault)
            return .object(["path": .string(try path(result.url)), "title": .string(result.title),
                            "kind": .string(checkKindName(result.kind))])
        case "noteHeader": return .string(CaptureFormat.noteHeader(title: try op.string("text")))
        case "noteBody": return .string(CaptureFormat.noteBody(try op.string("text")))
        case "cleanSubheading": return .string(CaptureFormat.cleanSubheading(try op.string("text")))
        case "sourceHeading": return .string(CaptureFormat.sourceHeading(try capture(op).source))
        case "block":
            return .string(CaptureFormat.block(for: try capture(op), noteRelativeDir: op["dir"]?.text ?? "",
                                               calendar: calendar, includeSourceHeading: op["includeSourceHeading"]?.flag ?? true,
                                               assetPathPrefix: op["assetPathPrefix"]?.text))
        case "append", "appendIfMissing":
            let destination = Destination(url: try url(op.string("path")), title: try op.string("title"), kind: .note)
            if name == "append" {
                try await writer.append(capture(op), to: destination.url, title: destination.title)
            } else {
                try await writer.appendIfMissing(capture(op), to: destination,
                                                 noteMarkerIsIdentity: op["noteMarkerIsIdentity"]?.flag ?? false)
            }
            return .null
        case "start": return fixtureSession(try await sessions.start(name: op.string("name")))
        case "current": return fixtureSession(await sessions.current())
        case "end": try await sessions.end(); return .null
        case "reload":
            let fixedClock = clock
            sessions = SessionStore(stateDirectory: state, vault: vault, calendar: calendar, now: { fixedClock })
            return fixtureSession(await sessions.current())
        case "persisted":
            let data = try Data(contentsOf: state.appendingPathComponent("session.json"))
            return try JSONDecoder().decode(FixtureValue.self, from: data)
        case "writeState":
            try checkWrite(op.string("text"), to: state.appendingPathComponent("session.json")); return .null
        case "resume":
            return fixtureSession(try await sessions.resume(SessionCandidate(name: try op.string("name"),
                                               notePath: try op.string("path"), modifiedAt: clock)))
        case "parse":
            let notePath = op["path"]?.text ?? "Note.md"
            let contents = try op["text"]?.text ?? checkRead(url(notePath))
            let parsed = NoteParser.parse(contents: contents, notePath: notePath,
                                          titleFallback: op["fallback"]?.text ?? "Fallback", calendar: calendar)
            return .object(["title": .string(parsed.title), "blocks": .array(parsed.blocks.map { block in
                .object(["id": fixtureString(block.captureID?.uuidString.lowercased()), "kind": .string(block.kind.rawValue),
                         "createdAt": fixtureStamp(block.createdAt), "sourceApp": fixtureString(block.sourceApp),
                         "windowTitle": fixtureString(block.windowTitle), "body": .string(block.body),
                         "assetPath": fixtureString(block.assetPath)])
            })])
        case "sync":
            let stats = try await searchIndex().sync()
            return .object(["added": .number(Double(stats.added)), "updated": .number(Double(stats.updated)),
                            "removed": .number(Double(stats.removed)), "unchanged": .number(Double(stats.unchanged))])
        case "query":
            let hits = try await searchIndex().search(op.string("text"), limit: op["limit"]?.integer ?? 40)
            return .array(hits.map { .object(["id": .string($0.embeddingKey), "title": .string($0.noteTitle)]) })
        case "reindex": try await searchIndex().reindex(note: url(op.string("path"))); return .null
        default: throw CheckFailure.failed("Unimplemented fixture operation: \(name)")
        }
    }

    func files() throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CheckFailure.failed("Could not enumerate the fixture vault")
        }
        var files: [String: String] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[try path(url)] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return files
    }
}

private func conformanceRoot() throws -> URL {
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
        let parent = directory.deletingLastPathComponent()
        guard parent != directory else { throw CheckFailure.failed("Cannot find Package.swift above the current directory") }
        directory = parent
    }
    return directory.appendingPathComponent("conformance/scenarios", isDirectory: true)
}

func checkConformance(writeExpected: Bool) async throws {
    let root = try conformanceRoot()
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        throw CheckFailure.failed("Cannot find conformance/scenarios")
    }
    let paths = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    try require(paths.count >= 60, "Conformance suite must have at least 60 scenarios")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var counts: [String: Int] = [:]
    for url in paths {
        var scenario = try JSONDecoder().decode(ConformanceScenario.self, from: Data(contentsOf: url))
        let label = "\(scenario.area)/\(scenario.id)"
        try require(conformanceOperations[scenario.area] != nil, "Unknown fixture area: \(label)")
        try require(url.deletingLastPathComponent().lastPathComponent == scenario.area &&
                    url.deletingPathExtension().lastPathComponent == scenario.id, "Fixture identity must match its path: \(label)")
        try require(!scenario.description.isEmpty && !scenario.input.ops.isEmpty, "Empty fixture: \(label)")
        let execution = try ConformanceExecution(input: scenario.input)
        var results: [FixtureValue] = []
        for op in scenario.input.ops { results.append(try await execution.execute(op, area: scenario.area)) }
        let actual = ConformanceScenario.Expected(files: try execution.files(), results: results)
        if writeExpected {
            scenario.expected = actual
            var data = try encoder.encode(scenario)
            data.append(0x0A)
            try data.write(to: url, options: .atomic)
        } else {
            guard let expected = scenario.expected else { throw CheckFailure.failed("Missing expected output: \(label)") }
            // Encoded bytes preserve Unicode distinctions that Swift String equality folds.
            let expectedData = try encoder.encode(expected)
            let actualData = try encoder.encode(actual)
            if actualData != expectedData {
                let expectedJSON = String(decoding: expectedData, as: UTF8.self)
                let actualJSON = String(decoding: actualData, as: UTF8.self)
                throw CheckFailure.failed("Conformance mismatch \(label)\nExpected: \(expectedJSON)\nActual: \(actualJSON)")
            }
        }
        counts[scenario.area, default: 0] += 1
        print("PASS conformance \(label)")
    }
    for area in conformanceOperations.keys { try require(counts[area, default: 0] >= 5, "Area \(area) needs at least five fixtures") }
}
