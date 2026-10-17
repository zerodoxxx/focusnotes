import CoreServices
import Foundation

public struct VaultChange: Sendable, Equatable {
    public let notesChanged: Set<String>
    public let assetsChanged: Set<String>
    public let needsFullSync: Bool

    public init(notesChanged: Set<String>, assetsChanged: Set<String>, needsFullSync: Bool) {
        self.notesChanged = notesChanged
        self.assetsChanged = assetsChanged
        self.needsFullSync = needsFullSync
    }
}

/// Watches vault changes. Consumers can skip unchanged files using index fingerprints.
public final class VaultWatcher: @unchecked Sendable {
    private let vault: Vault
    private let latency: TimeInterval
    private let onChange: @Sendable (VaultChange) -> Void
    private let queue = DispatchQueue(label: "vault-watcher")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?

    public init(
        vault: Vault,
        latency: TimeInterval = 1.0,
        onChange: @escaping @Sendable (VaultChange) -> Void
    ) {
        self.vault = vault
        self.latency = max(0, latency)
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        stop()
    }

    /// A failed stream creation/start leaves this false, allowing callers to fall back to sync.
    public var isRunning: Bool {
        var running = false
        performOnQueue { running = self.stream != nil }
        return running
    }

    public func start() {
        performOnQueue { self.startOnQueue() }
    }

    public func stop() {
        performOnQueue { self.stopOnQueue() }
    }

    /// Rebuilds the stream after an explicitly registered external note creates
    /// missing parent directories. The new roots remain bounded to those notes.
    public func refreshExternalRoots() {
        performOnQueue {
            guard self.stream != nil else { return }
            self.stopOnQueue()
            self.startOnQueue()
        }
    }

    private func startOnQueue() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let externalPaths = (try? vault.externalNoteWatchURLs())?.map(\.path) ?? []
        let paths = Array(Set([vault.root.path] + externalPaths)).sorted() as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            vaultWatcherCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func stopOnQueue() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func performOnQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    fileprivate func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        guard stream != nil else { return }

        var notesChanged = Set<String>()
        var assetsChanged = Set<String>()
        var needsFullSync = false
        let externalLocations = (try? vault.externalNoteLocations()) ?? []
        let externalByPath = Dictionary(uniqueKeysWithValues: externalLocations.map { ($0.url.standardizedFileURL.path, $0) })
        let externalRoots = Set(((try? vault.externalNoteWatchURLs()) ?? []).map { $0.standardizedFileURL.path })
        let homeRootPath = vault.homeRoot.standardizedFileURL.path

        for event in events {
            let flags = event.flags
            if hasFlag(flags, kFSEventStreamEventFlagMustScanSubDirs)
                || hasFlag(flags, kFSEventStreamEventFlagRootChanged)
                || hasFlag(flags, kFSEventStreamEventFlagUserDropped)
                || hasFlag(flags, kFSEventStreamEventFlagKernelDropped) {
                needsFullSync = true
            }

            let eventURL = URL(fileURLWithPath: event.path).standardizedFileURL
            guard let relativePath = vault.relativePath(of: eventURL) else {
                let externalPath = eventURL.path
                if let location = externalByPath[externalPath] {
                    let components = location.relativePath.split(separator: "/").map(String.init)
                    if let name = components.last, isReportablePath(components), !isDirectory(flags), isMarkdown(name) {
                        notesChanged.insert(location.id)
                    }
                } else if externalRoots.contains(externalPath), externalPath != homeRootPath, isDirectory(flags) {
                    // A selected external parent was renamed or removed. A full
                    // sync checks only registry entries, never unrelated files.
                    needsFullSync = true
                }
                continue
            }
            let components = relativePath.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }

            if isDirectory(flags),
               hasFlag(flags, kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved) {
                needsFullSync = true
            }

            guard isReportablePath(components) else {
                continue
            }

            if components[0] == Vault.assetsDirectoryName {
                assetsChanged.insert(relativePath)
            } else if isMarkdown(name), !isDirectory(flags) {
                notesChanged.insert(relativePath)
            }
        }

        guard needsFullSync || !notesChanged.isEmpty || !assetsChanged.isEmpty else { return }
        onChange(VaultChange(
            notesChanged: notesChanged,
            assetsChanged: assetsChanged,
            needsFullSync: needsFullSync
        ))
    }

    private func isReportablePath(_ components: [String]) -> Bool {
        guard !components.isEmpty,
              !components.contains(where: { $0.hasPrefix(".") }),
              let name = components.last,
              !name.hasPrefix(".~"),
              !name.hasPrefix("~$"),
              name != ".DS_Store",
              !name.lowercased().hasSuffix(".swp"),
              !name.lowercased().hasSuffix(".icloud") else {
            return false
        }

        if components[0] == Vault.assetsDirectoryName {
            return components.count >= 2
        }
        return isMarkdown(name)
    }

    private func isMarkdown(_ name: String) -> Bool {
        URL(fileURLWithPath: name).pathExtension.lowercased() == "md"
    }

    private func isDirectory(_ flags: FSEventStreamEventFlags) -> Bool {
        hasFlag(flags, kFSEventStreamEventFlagItemIsDir)
    }

    private func hasFlag(_ flags: FSEventStreamEventFlags, _ flag: Int) -> Bool {
        flags & FSEventStreamEventFlags(flag) != 0
    }

}

private let vaultWatcherCallback: FSEventStreamCallback = { _, clientInfo, eventCount, eventPaths, eventFlags, _ in
    guard let clientInfo else { return }
    let watcher = Unmanaged<VaultWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    var events: [(path: String, flags: FSEventStreamEventFlags)] = []
    events.reserveCapacity(eventCount)
    for index in 0..<eventCount {
        guard let path = paths[index] else { continue }
        events.append((String(cString: path), eventFlags[index]))
    }
    watcher.handle(events)
}
