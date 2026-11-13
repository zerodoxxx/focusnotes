import Foundation

/// Serializes capture and asset writes. Captures append; SessionStore owns safe heading rewrites during renames.
public actor NoteWriter {
    private let vault: Vault
    private let calendar: Calendar
    private let afterAppend: (@Sendable (URL) -> Void)?
    private let beforeAppend: (@Sendable (URL) -> Void)?
    private var appendCache = NoteFile.AppendCache()

    @_spi(Checks)
    public var appendCacheStatistics: (fullScans: Int, cachedFiles: Int) {
        (appendCache.fullScans, appendCache.fileCount)
    }

    @_spi(Checks)
    public static var appendCacheFileLimit: Int { NoteFile.AppendCache.fileLimit }

    @_spi(Checks)
    public static func sourceGroupingMatchesFullParser(_ contents: String, source: String, calendar: Calendar) -> Bool {
        var state = NoteParser.SourceHeadingState()
        state.consume(contents, calendar: calendar)
        return state.needsHeading(source, calendar: calendar) == NoteParser.needsSourceHeading(source, contents: contents, calendar: calendar)
    }

    public init(vault: Vault, calendar: Calendar) {
        self.vault = vault
        self.calendar = calendar
        afterAppend = nil
        beforeAppend = nil
    }

    /// Deterministic atomic-replacement injection, unavailable to normal clients.
    @_spi(Checks)
    public init(vault: Vault, calendar: Calendar, beforeAppend: (@Sendable (URL) -> Void)? = nil,
                afterAppend: @escaping @Sendable (URL) -> Void) {
        self.vault = vault
        self.calendar = calendar
        self.afterAppend = afterAppend
        self.beforeAppend = beforeAppend
    }

    /// Appends one capture block to `note`. Creates the file with its header when it does not exist.
    public func append(_ capture: Capture, to note: URL, title: String) throws {
        let location = try vault.managedLocation(of: note)
        try prepareParentDirectory(for: location)
        let block = captureBlock(capture, location: location, includeSourceHeading: false)
        let header = headerLine(title: title)

        try NoteFile.append(block: block, header: header, root: location.anchor, relativePath: location.relativePath,
                            to: location.url, cache: &appendCache, identityPrefix: CaptureFormat.identityPrefix(for: capture),
                            sourceHeading: headingSource(capture), equivalentBlocks: legacyBlocks(capture, block: block),
                            calendar: calendar, beforeWrite: beforeAppend, afterWrite: afterAppend)
    }

    /// Retries keep the original marker and asset path, including after journal replay.
    public func appendIfMissing(_ capture: Capture, to destination: Destination, png: Data? = nil, noteMarkerIsIdentity: Bool = false) throws {
        let location = try vault.managedLocation(of: destination.url)
        try prepareParentDirectory(for: location)
        if case .image(let path) = capture.content {
            let assetPath = try checkedAssetPath(path)
            if let png {
                // The stable asset path survives retries. Replace incomplete
                // content atomically after validating its descriptor and link count.
                try NoteFile.ensureAsset(png, in: vault.rootAnchor, relativePath: assetPath)
            }
        }
        let block = captureBlock(capture, location: location, includeSourceHeading: false)
        let marker = CaptureFormat.bareMarker(for: capture)
        let savedNoteMarker = noteMarkerIsIdentity && CaptureFormat.MarkerKind(capture) == .note
            ? String(CaptureFormat.splitMarkerLine(block).markerLine) : nil
        try NoteFile.append(block: block, header: headerLine(title: destination.title),
                            root: location.anchor, relativePath: location.relativePath, to: location.url,
                            cache: &appendCache, identityPrefix: CaptureFormat.identityPrefix(for: capture), unlessMarkerExists: marker,
                            savedNoteMarker: savedNoteMarker, sourceHeading: headingSource(capture),
                            equivalentBlocks: legacyBlocks(capture, block: block), calendar: calendar,
                            beforeWrite: beforeAppend, afterWrite: afterAppend)
    }

    private var beforeMoveRemoval: (@Sendable (URL) throws -> Void)?
    private var beforeMoveSwap: (@Sendable (URL) throws -> Void)?

    @_spi(Checks)
    public func setBeforeCaptureMoveRemoval(_ hook: (@Sendable (URL) throws -> Void)?) {
        beforeMoveRemoval = hook
    }

    /// Runs after the source's final identity check, immediately before its atomic swap.
    @_spi(Checks)
    public func setBeforeCaptureMoveSwap(_ hook: (@Sendable (URL) throws -> Void)?) {
        beforeMoveSwap = hook
    }

    func moveCapture(id: UUID, from source: Destination, to destination: Destination) throws {
        let sourceLocation: VaultManagedLocation
        let snapshot: NoteFile.MoveSnapshot
        do {
            sourceLocation = try vault.managedLocation(of: source.url)
            snapshot = try NoteFile.moveSnapshot(in: sourceLocation.anchor, relativePath: sourceLocation.relativePath)
        } catch let error as POSIXError where error.code == .ENOENT {
            throw CaptureMoveError.notFound(noteTitle: source.title)
        } catch {
            throw CaptureMoveError.writeFailed(noteTitle: source.title)
        }
        guard let block = CaptureMoveBlock(id: id, contents: snapshot.contents) else {
            throw CaptureMoveError.notFound(noteTitle: source.title)
        }
        let text = block.rewritingImages(from: source.url, to: destination.url)
        let target: VaultManagedLocation
        var appended: NoteFile.AppendedBytes?
        do {
            target = try vault.managedLocation(of: destination.url)
            try prepareParentDirectory(for: target)
            // An identical copy completes an interrupted move; a different one must not cost source text.
            func hasIdenticalCopy() throws -> Bool {
                let existing: NoteFile.MoveSnapshot
                do { existing = try NoteFile.moveSnapshot(in: target.anchor, relativePath: target.relativePath) }
                catch let error as POSIXError where error.code == .ENOENT { return false }
                guard let copy = CaptureMoveBlock(id: id, contents: existing.contents) else { return false }
                guard Self.comparable(copy.text) == Self.comparable(text) else {
                    throw CaptureMoveError.conflict(noteTitle: destination.title)
                }
                return true
            }
            if try !hasIdenticalCopy() {
                let identity = CaptureFormat.markerPrefix + id.uuidString.lowercased()
                appended = try NoteFile.append(block: text, header: headerLine(title: destination.title), root: target.anchor,
                                               relativePath: target.relativePath, to: target.url, cache: &appendCache,
                                               identityPrefix: identity, unlessMarkerExists: identity, markerIsIdentity: true,
                                               sourceHeading: block.heading, calendar: calendar)
                // The marker appeared since the check: proceed only if it is an identical copy.
                if appended == nil, try !hasIdenticalCopy() { throw CaptureMoveError.conflict(noteTitle: destination.title) }
            }
        } catch let error as CaptureMoveError { throw error }
        catch { throw CaptureMoveError.writeFailed(noteTitle: destination.title) }
        do {
            try beforeMoveRemoval?(source.url)
            let swapHook = beforeMoveSwap
            try NoteFile.replaceContents(block.remainder, matching: snapshot,
                                         in: sourceLocation.anchor, relativePath: sourceLocation.relativePath,
                                         beforeSwap: swapHook.map { hook in { try hook(source.url) } })
        } catch {
            let failure: CaptureMoveError
            if let posix = error as? POSIXError, (posix.code == .EAGAIN || posix.code == .ENOENT) {
                failure = .sourceChanged(noteTitle: source.title)
            } else { failure = .writeFailed(noteTitle: source.title) }
            if let appended {
                // Only our exact bytes are undone; a destination edited since our append is left alone.
                do { _ = try NoteFile.removeAppended(appended, in: target.anchor, relativePath: target.relativePath) }
                catch { throw CaptureMoveError.writeFailed(noteTitle: destination.title) }
            }
            throw failure
        }
    }

    private static func comparable(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { String($0.reversed().drop(while: { $0.isWhitespace }).reversed()) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prepareParentDirectory(for location: VaultManagedLocation) throws {
        let parent = parentPath(of: location.relativePath)
        if !parent.isEmpty {
            try NoteFile.prepareManagedDirectory(parent, in: location.anchor)
        }
    }

    private func parentPath(of relativePath: String) -> String {
        relativePath.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func captureBlock(_ capture: Capture, location: VaultManagedLocation,
                              includeSourceHeading: Bool) -> String {
        let noteRelativeDir = parentPath(of: location.relativePath)
        let assetPathPrefix = CaptureFormat.relativePath(
            from: location.url.deletingLastPathComponent(), to: vault.root
        )
        return CaptureFormat.block(for: capture, noteRelativeDir: noteRelativeDir, calendar: calendar,
                                   includeSourceHeading: includeSourceHeading, assetPathPrefix: assetPathPrefix)
    }

    private func legacyBlocks(_ capture: Capture, block: String) -> [String] {
        guard CaptureFormat.groupsBySource(capture) else { return [] }
        // An upgrade may replay a job already saved by the old writer.
        let body = CaptureFormat.splitMarkerLine(block).body
        return [CaptureFormat.bareMarker(for: capture) + body]
    }

    private func headerLine(title: String) -> String {
        CaptureFormat.noteHeader(title: title) + "\n"
    }

    private func headingSource(_ capture: Capture) -> String? {
        guard CaptureFormat.groupsBySource(capture) else { return nil }
        return CaptureFormat.sourceHeading(capture.source)
    }

    /// Writes a PNG to `assets/{yyyy-MM-dd-HHmmss}-{4 hex}.png` and returns its vault-relative path.
    public func saveImage(png: Data, createdAt: Date) throws -> String {
        let stamp = CaptureFormat.localStamp(createdAt, pattern: "yyyy-MM-dd-HHmmss", calendar: calendar)

        while true {
            let suffix = String(format: "%04x", Int.random(in: 0...0xFFFF))
            let name = "\(stamp)-\(suffix).png"
            let path = "\(Vault.assetsDirectoryName)/\(name)"
            if try NoteFile.createAsset(png, in: vault.rootAnchor, relativePath: path) { return path }
        }
    }

    private func checkedAssetPath(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == Vault.assetsDirectoryName,
              let name = components.last, name.hasSuffix(".png"), !name.hasPrefix("."),
              !path.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
        return path
    }
}
