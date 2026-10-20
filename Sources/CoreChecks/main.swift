import Core
import Darwin
import Foundation
import SQLite3

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw CheckFailure.failed(message)
    }
}

func runChecks() throws {
    try SearchIndex.probeFullTextSearch()
    print("PASS FTS5 capability probe")
    try require(!SQLiteVersion.string.isEmpty, "System SQLite version is available")

    var database: OpaquePointer?
    let openResult = sqlite3_open(":memory:", &database)
    try require(openResult == SQLITE_OK, "Could not open an in-memory SQLite database")
    guard let database else {
        throw CheckFailure.failed("SQLite returned no database handle")
    }
    defer { sqlite3_close(database) }

    let createResult = sqlite3_exec(
        database,
        "CREATE VIRTUAL TABLE notes USING fts5(title, body); INSERT INTO notes VALUES ('Moon notes', 'The moon orbits Earth'), ('Garden notes', 'Tomatoes grow in summer');",
        nil,
        nil,
        nil
    )
    try require(createResult == SQLITE_OK, "Could not create and populate the FTS5 table")

    var statement: OpaquePointer?
    let prepareResult = "SELECT title FROM notes WHERE notes MATCH 'moon';"
        .withCString { sqlite3_prepare_v2(database, $0, -1, &statement, nil) }
    try require(prepareResult == SQLITE_OK, "Could not prepare the FTS5 MATCH query")
    guard let statement else {
        throw CheckFailure.failed("SQLite returned no query statement")
    }
    defer { sqlite3_finalize(statement) }

    try require(sqlite3_step(statement) == SQLITE_ROW, "The FTS5 query did not return a matching row")
    guard let title = sqlite3_column_text(statement, 0) else {
        throw CheckFailure.failed("The FTS5 query returned a row without a title")
    }
    try require(String(cString: title) == "Moon notes", "The FTS5 query returned the wrong row")
    try require(sqlite3_step(statement) == SQLITE_DONE, "The FTS5 query returned unexpected extra rows")
}

do {
    if CommandLine.arguments.contains("--write-conformance") {
        try await checkConformance(writeExpected: true)
        exit(EXIT_SUCCESS)
    }
    try runChecks()
    print("Core checks passed (SQLite \(SQLiteVersion.string), FTS5 MATCH).")
    try checkCaptureFormat()
    try checkNoteTitle()
    try checkVault()
    try checkRouter()
    try await checkNoteWriter()
    try await checkSessionStore()
    try await checkCaptureService()
    try checkNoteParser()
    try await checkTypedNotes()
    try await checkSearchIndex()
    try await checkSearchIndexPerformance()
    try checkVaultWatcher()
    try await checkExternalNoteRegistry()
    try await checkConformance(writeExpected: false)
} catch {
    fputs("Core checks failed: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
