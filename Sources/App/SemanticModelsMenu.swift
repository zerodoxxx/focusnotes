import AppKit
import EmbedKit
import ModelInstall

/// Status-menu entry and consent dialogs for the opt-in semantic search model download.
/// Nothing touches the network except an explicit Download or Resume choice.
@MainActor
final class SemanticModelsMenu {
    private enum Phase {
        case idle
        case downloading(Task<Void, Never>)
        case removing
    }

    /// Top-level status item. While the models are installed, its submenu offers removal.
    let item: NSMenuItem
    private let submenu = NSMenu()
    private let semantic: SemanticIndexer
    private let downloadAction: Selector
    private let changed: @MainActor () -> Void
    private let failed: @MainActor (Error, String) -> Void
    private let succeeded: @MainActor () -> Void
    private var phase = Phase.idle
    private var progress: ModelInstaller.Progress?
    private var installed = false
    private var installer: ModelInstaller?

    init(semantic: SemanticIndexer, target: AnyObject, download: Selector, remove: Selector,
         changed: @escaping @MainActor () -> Void,
         failed: @escaping @MainActor (Error, String) -> Void,
         succeeded: @escaping @MainActor () -> Void) {
        self.semantic = semantic
        self.downloadAction = download
        self.changed = changed
        self.failed = failed
        self.succeeded = succeeded
        item = NSMenuItem(title: "", action: download, keyEquivalent: "")
        item.target = target
        let removeItem = NSMenuItem(title: "Remove Semantic Search Models…", action: remove, keyEquivalent: "")
        removeItem.target = target
        submenu.addItem(removeItem)
    }

    /// Called from the status-menu refresh with what is on disk right now.
    func refresh(installed: Bool) {
        self.installed = installed
        let idle = isIdle
        item.submenu = installed && idle ? submenu : nil
        item.action = installed ? nil : downloadAction
        item.isEnabled = !isRemoving
        item.title = title()
    }

    /// Stops an in-flight download so it cannot outlive the app. Partial files are kept for resume.
    func cancelDownload() {
        if case let .downloading(task) = phase { task.cancel() }
    }

    /// Menu action for the download or resume entry.
    func activate() {
        switch phase {
        case .downloading:
            confirmCancel()
        case .removing:
            return
        case .idle:
            guard !installed else { return }
            confirmDownload()
        }
    }

    /// Menu action for the removal entry.
    func confirmRemove() {
        guard installed, isIdle else { return }
        let alert = NSAlert()
        alert.messageText = "Remove semantic search models?"
        alert.informativeText = "This frees about \(size(ModelManifest.current.totalDownloadBytes)). Keyword search keeps working, and you can download the models again later."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        alert.buttons[1].hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        remove()
    }

    private var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    private var isRemoving: Bool {
        if case .removing = phase { return true }
        return false
    }

    private func title() -> String {
        if installed {
            return isRemoving ? "Removing Semantic Search Models…" : "Semantic Search: On"
        }
        switch phase {
        case .downloading:
            guard let progress else { return "Downloading Semantic Search Models…" }
            let percent = Int((progress.fraction * 100).rounded(.down))
            return "Downloading Semantic Search Models… \(percent)% (\(size(progress.completedBytes)) of \(size(progress.totalBytes)))"
        case .removing:
            return "Removing Semantic Search Models…"
        case .idle:
            if (try? makeInstaller())?.hasPartialDownload == true {
                return "Resume Semantic Search Model Download…"
            }
            return "Download Semantic Search Models (\(size(ModelManifest.current.totalDownloadBytes)))…"
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func makeInstaller() throws -> ModelInstaller {
        if let installer { return installer }
        guard let resources = Bundle.main.resourceURL else {
            throw ModelInstallError.missingBundledResource("Resources")
        }
        let created = ModelInstaller(modelsDirectory: semantic.modelsDirectory, bundledResources: resources)
        created.recoverInterruptedCommit()
        installer = created
        return created
    }

    private func confirmDownload() {
        let installer: ModelInstaller
        do { installer = try makeInstaller() }
        catch {
            failed(error, "Couldn't download semantic search models")
            return
        }
        let resuming = installer.hasPartialDownload
        let alert = NSAlert()
        alert.messageText = resuming ? "Resume the semantic search model download?" : "Download semantic search models?"
        alert.informativeText = "\(AppInfo.name) will download about \(size(ModelManifest.current.totalDownloadBytes)) from huggingface.co and github.com: the EmbeddingGemma model (Apache-2.0) and ONNX Runtime (MIT). Each file is checked against a pinned SHA-256 hash before use. Your notes never leave your Mac, and you can remove the models at any time."
        alert.addButton(withTitle: resuming ? "Resume" : "Download")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startDownload(installer)
    }

    private func startDownload(_ installer: ModelInstaller) {
        progress = nil
        let task = Task { @MainActor [weak self] in
            do {
                try await installer.install { [weak self] update in
                    Task { @MainActor in self?.received(update) }
                }
                self?.finish(.success(()))
            } catch {
                self?.finish(.failure(error))
            }
        }
        phase = .downloading(task)
        changed()
    }

    private func received(_ update: ModelInstaller.Progress) {
        guard case .downloading = phase else { return }
        progress = update
        item.title = title()
    }

    private func finish(_ outcome: Result<Void, Error>) {
        phase = .idle
        progress = nil
        changed()
        switch outcome {
        case .success:
            succeeded()
        case let .failure(error):
            // A user cancel is silent, whichever error the installer surfaced on the way out.
            if Task.isCancelled || (error as? ModelInstallError) == .cancelled { return }
            failed(error, "Couldn't download semantic search models")
        }
    }

    private func confirmCancel() {
        guard case let .downloading(task) = phase else { return }
        let alert = NSAlert()
        alert.messageText = "Cancel the download?"
        alert.informativeText = "Downloaded data is kept, so the next download resumes where it stopped."
        alert.addButton(withTitle: "Keep Downloading")
        alert.addButton(withTitle: "Cancel Download")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { task.cancel() }
    }

    private func remove() {
        phase = .removing
        changed()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Stops new embedding work and keeps the indexer usable for a later re-download.
            await self.semantic.setEnabled(false)
            do {
                try await self.makeInstaller().remove()
            } catch {
                self.failed(error, "Couldn't remove semantic search models")
            }
            self.phase = .idle
            self.changed()
        }
    }
}
