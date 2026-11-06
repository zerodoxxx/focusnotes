import Foundation
import Accelerate
import SQLite3
import os

/// A separate SQLite database, scoped by model revision/quantization and dims.
/// Normalizes vectors on insert and after Float16 decoding so nearest scores
/// are cosine similarities. Serialized access and a reusable row-major cache.
public final class VectorStore: @unchecked Sendable {
    public let modelID: String
    public let dimensions: Int
    private let db: OpaquePointer
    private let lock = NSLock()
    private var cache: (keys: [String], vectors: [Float])?
    private var dataVersion: Int64 = -1
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let logger = Logger(subsystem: "VectorStore", category: "identity")

    /// Pass the text and vision ONNX graph/data files to stamp the store against their identities.
    /// Omitting them retains an existing file-size stamp while still validating model ID and dimensions.
    public init(url: URL, modelID: String = Embedder.modelID, dimensions: Int = 256, modelFiles: [URL]? = nil) throws {
        guard EmbedProtocol.supportedDimensions.contains(dimensions), !modelID.isEmpty, !modelID.contains("\0") else {
            throw EmbeddingError.invalid("Invalid vector store configuration")
        }
        let requestedIdentity = try modelFiles.map { try Self.identity(modelID: modelID, dimensions: dimensions, modelFiles: $0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard code == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open vector database"
            if let connection { sqlite3_close(connection) }
            throw EmbeddingError.database(message)
        }
        self.db = connection; self.modelID = modelID; self.dimensions = dimensions
        do {
            try check(sqlite3_busy_timeout(db, 5000))
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            try exec("""
                CREATE TABLE IF NOT EXISTS embeddings (
                    key TEXT PRIMARY KEY NOT NULL,
                    model_id TEXT NOT NULL,
                    dims INTEGER NOT NULL CHECK(dims IN (128,256,512,768)),
                    vector BLOB NOT NULL CHECK(length(vector) = dims * 2),
                    fingerprint TEXT
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                """)
            var hasFingerprint = false
            do {
                let columns = try prepare("PRAGMA table_info(embeddings)")
                defer { sqlite3_finalize(columns) }
                while true {
                    let code = sqlite3_step(columns)
                    if code == SQLITE_DONE { break }
                    try check(code, expecting: SQLITE_ROW)
                    if let name = sqlite3_column_text(columns, 1), String(cString: name) == "fingerprint" {
                        hasFingerprint = true
                    }
                }
            }
            if !hasFingerprint { try exec("ALTER TABLE embeddings ADD COLUMN fingerprint TEXT") }

            let storedIdentity = try readModelIdentity()
            let hasVectors = try containsVectors()
            let identity = requestedIdentity ?? Self.identity(modelID: modelID, dimensions: dimensions, storedIdentity: storedIdentity)
            let identityChanged = storedIdentity.map { $0 != identity } ?? false
            let missingIdentityWithVectors = storedIdentity == nil && hasVectors
            if identityChanged || missingIdentityWithVectors {
                try exec("BEGIN IMMEDIATE")
                do {
                    try exec("DELETE FROM embeddings")
                    try writeModelIdentity(identity)
                    try exec("COMMIT")
                } catch {
                    try? exec("ROLLBACK")
                    throw error
                }
                logger.notice("Vector store model identity changed; cleared existing vectors")
            } else if storedIdentity == nil {
                try writeModelIdentity(identity)
            }
        } catch { sqlite3_close(db); throw error }
    }

    deinit { sqlite3_close(db) }

    public func upsert(key: String, vector: [Float], fingerprint: String? = nil) throws {
        guard !key.isEmpty, !key.contains("\0"), vector.count == dimensions,
              fingerprint?.contains("\0") != true else {
            throw EmbeddingError.invalid("Invalid vector key or dimensions")
        }
        let data = try Float16Vectors.encode(normalized(vector))
        try lock.withLock {
            let statement = try prepare("INSERT INTO embeddings(key,model_id,dims,vector,fingerprint) VALUES(?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET model_id=excluded.model_id,dims=excluded.dims,vector=excluded.vector,fingerprint=excluded.fingerprint")
            defer { sqlite3_finalize(statement) }
            try bind(key, to: statement, at: 1)
            try bind(modelID, to: statement, at: 2)
            try check(sqlite3_bind_int(statement, 3, Int32(dimensions)))
            try data.withUnsafeBytes {
                try check(sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient))
            }
            if let fingerprint { try bind(fingerprint, to: statement, at: 5) }
            else { try check(sqlite3_bind_null(statement, 5)) }
            try check(sqlite3_step(statement), expecting: SQLITE_DONE)
            cache = nil
        }
    }

    public func remove(keys: [String]) throws {
        guard keys.allSatisfy({ !$0.contains("\0") }) else { throw EmbeddingError.invalid("Invalid key") }
        try lock.withLock {
            guard !keys.isEmpty else { return }
            try exec("BEGIN IMMEDIATE")
            do {
                let statement = try prepare("DELETE FROM embeddings WHERE key=?")
                defer { sqlite3_finalize(statement) }
                for key in keys {
                    try check(sqlite3_reset(statement))
                    try bind(key, to: statement, at: 1)
                    try check(sqlite3_step(statement), expecting: SQLITE_DONE)
                }
                try exec("COMMIT")
                cache = nil
            } catch { try? exec("ROLLBACK"); cache = nil; throw error }
        }
    }

    public func keys() throws -> [String] { try lock.withLock { try loadCache(); return cache!.keys } }

    /// Missing fingerprints are deliberately omitted: old vectors remain usable
    /// for search until reconciliation replaces them with a known input.
    public func fingerprints() throws -> [String: String] {
        try lock.withLock {
            let statement = try prepare("SELECT key,fingerprint FROM embeddings WHERE model_id=? AND dims=? AND fingerprint IS NOT NULL")
            defer { sqlite3_finalize(statement) }
            try bind(modelID, to: statement, at: 1)
            try check(sqlite3_bind_int(statement, 2, Int32(dimensions)))
            var result: [String: String] = [:]
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                try check(code, expecting: SQLITE_ROW)
                guard let key = sqlite3_column_text(statement, 0), let fingerprint = sqlite3_column_text(statement, 1) else {
                    throw EmbeddingError.database("Corrupt fingerprint row")
                }
                result[String(cString: key)] = String(cString: fingerprint)
            }
        }
    }

    public func nearest(to query: [Float], limit: Int) throws -> [(key: String, score: Float)] {
        guard query.count == dimensions else { throw EmbeddingError.invalid("Query dimensions do not match store") }
        let query = try normalized(query)
        return try lock.withLock {
            try Task.checkCancellation()
            guard limit > 0 else { return [] }
            try loadCache()
            let cached = cache!
            guard !cached.keys.isEmpty else { return [] }
            guard cached.keys.count <= Int(Int32.max) else { throw EmbeddingError.database("Too many vectors") }
            var scores = [Float](repeating: 0, count: cached.keys.count)
            vDSP_mmul(cached.vectors, 1, query, 1, &scores, 1,
                      vDSP_Length(cached.keys.count), 1, vDSP_Length(dimensions))
            // Stable key order resolves ties reproducibly.
            return scores.indices.sorted {
                scores[$0] == scores[$1] ? cached.keys[$0] < cached.keys[$1] : scores[$0] > scores[$1]
            }.prefix(limit).map { (cached.keys[$0], max(-1, min(1, scores[$0]))) }
        }
    }

    private func loadCache() throws {
        let versionStatement = try prepare("PRAGMA data_version")
        defer { sqlite3_finalize(versionStatement) }
        try check(sqlite3_step(versionStatement), expecting: SQLITE_ROW)
        let version = sqlite3_column_int64(versionStatement, 0)
        if cache != nil && version == dataVersion { return }
        let statement = try prepare("SELECT key,vector FROM embeddings WHERE model_id=? AND dims=? ORDER BY key")
        defer { sqlite3_finalize(statement) }
        try bind(modelID, to: statement, at: 1)
        try check(sqlite3_bind_int(statement, 2, Int32(dimensions)))
        var keys: [String] = [], vectors: [Float] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            try check(result, expecting: SQLITE_ROW)
            guard let key = sqlite3_column_text(statement, 0),
                  let blob = sqlite3_column_blob(statement, 1), sqlite3_column_bytes(statement, 1) == dimensions * 2 else {
                throw EmbeddingError.database("Corrupt vector row")
            }
            keys.append(String(cString: key))
            let vector = try Float16Vectors.decode(Data(bytes: blob, count: dimensions * 2), dimensions: dimensions)
            vectors += try normalized(vector)
        }
        cache = (keys, vectors); dataVersion = version
    }

    private func check(_ code: Int32, expecting expected: Int32 = SQLITE_OK) throws {
        guard code == expected else { throw EmbeddingError.database(String(cString: sqlite3_errmsg(db))) }
    }

    private func readModelIdentity() throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key='model_identity'")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        try check(result, expecting: SQLITE_ROW)
        guard let value = sqlite3_column_text(statement, 0) else {
            throw EmbeddingError.database("Corrupt vector model identity")
        }
        return String(cString: value)
    }

    private func containsVectors() throws -> Bool {
        let statement = try prepare("SELECT EXISTS(SELECT 1 FROM embeddings LIMIT 1)")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), expecting: SQLITE_ROW)
        return sqlite3_column_int(statement, 0) != 0
    }

    private func writeModelIdentity(_ identity: String) throws {
        let statement = try prepare("INSERT INTO meta(key,value) VALUES('model_identity',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(statement) }
        try bind(identity, to: statement, at: 1)
        try check(sqlite3_step(statement), expecting: SQLITE_DONE)
    }

    private static func identity(modelID: String, dimensions: Int, modelFiles: [URL]) throws -> String {
        let fileIdentities = try modelFiles.map { url -> String in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw EmbeddingError.database("Could not read model file size: \(url.lastPathComponent)")
            }
            return "\(url.lastPathComponent)=\(size.int64Value)"
        }.sorted()
        return "model=\(modelID);dimensions=\(dimensions);files=\(fileIdentities.joined(separator: ","))"
    }

    private static func identity(modelID: String, dimensions: Int, storedIdentity: String?) -> String {
        let fileIdentity: String
        if let storedIdentity, let range = storedIdentity.range(of: ";files=") {
            fileIdentity = String(storedIdentity[range.upperBound...])
        } else {
            fileIdentity = ""
        }
        return "model=\(modelID);dimensions=\(dimensions);files=\(fileIdentity)"
    }

    private func exec(_ sql: String) throws { try check(sqlite3_exec(db, sql, nil, nil, nil)) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement else { throw EmbeddingError.database("Empty SQL statement") }
        return statement
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        try check(sqlite3_bind_text(statement, index, value, -1, transient))
    }
}
