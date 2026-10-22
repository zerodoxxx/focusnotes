import AppKit
import CaptureKit

/// Edits a private copy; only Save publishes the bindings to the controller.
@MainActor
final class FolderShortcutsPanel: NSObject, NSWindowDelegate {
    @MainActor
    private final class Row {
        let id: UUID
        var hotkey: Hotkey?
        let action = NSPopUpButton()
        let folder = NSTextField()
        let record = NSButton()
        let remove = NSButton()
        let status = NSTextField(wrappingLabelWithString: "")
        let view = NSStackView()

        init(id: UUID = UUID(), hotkey: Hotkey? = nil) {
            self.id = id
            self.hotkey = hotkey
        }
    }

    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let list = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let add = NSButton(title: "Add Shortcut", target: nil, action: nil)
    private var rows: [Row] = []
    private var recording: Row?
    private var monitor: Any?
    private var closed = false
    private let failures: [Hotkey: HotkeyError]
    private let onSave: ([FolderShortcut]) throws -> Void
    private let onRecordingChanged: (Bool) -> Void
    private let onClose: () -> Void

    init(bindings: [FolderShortcut], failures: [Hotkey: HotkeyError],
         onSave: @escaping ([FolderShortcut]) throws -> Void,
         onRecordingChanged: @escaping (Bool) -> Void, onClose: @escaping () -> Void) {
        self.failures = failures
        self.onSave = onSave
        self.onRecordingChanged = onRecordingChanged
        self.onClose = onClose
        super.init()
        window.title = "Folder Shortcuts"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 350)
        window.delegate = self
        buildContent()
        for binding in bindings {
            appendRow(id: binding.id, hotkey: binding.hotkey,
                      session: binding.action == .startSession, folder: binding.folder)
        }
        updateAdd()
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        stopRecording()
        window.close()
    }

    private func buildContent() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        let explanation = NSTextField(wrappingLabelWithString:
            "Quick notes use folders inside your notes folder. Start Session asks for a name, then creates or resumes it in Sessions/<folder>. Enter a relative folder such as Work/Projects. Explicitly choosing a note overrides the shortcut folder.")
        root.addArrangedSubview(explanation)
        let hint = NSTextField(wrappingLabelWithString:
            "Record a shortcut with ⌘, ⌃, or ⌥ (optionally ⇧). Press Escape to stop recording. Built-in shortcuts are reserved.")
        hint.textColor = .secondaryLabelColor
        root.addArrangedSubview(hint)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        root.addArrangedSubview(scroll)
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        add.target = self
        add.action = #selector(addRow)
        root.addArrangedSubview(add)
        errorLabel.textColor = .systemRed
        root.addArrangedSubview(errorLabel)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(save)
        root.addArrangedSubview(buttons)
        guard let content = window.contentView else { return }
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            explanation.widthAnchor.constraint(equalTo: root.widthAnchor),
            hint.widthAnchor.constraint(equalTo: root.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func appendRow(id: UUID = UUID(), hotkey: Hotkey? = nil, session: Bool = false, folder: String = "") {
        let row = Row(id: id, hotkey: hotkey)
        row.action.addItems(withTitles: ["Quick Note", "Start Session"])
        row.action.selectItem(at: session ? 1 : 0)
        row.folder.stringValue = folder
        row.folder.placeholderString = "Relative folder"
        row.folder.setAccessibilityLabel("Destination folder")
        row.record.title = hotkey?.displayString ?? "Record Shortcut…"
        row.record.target = self
        row.record.action = #selector(recordShortcut(_:))
        row.remove.title = "Delete"
        row.remove.target = self
        row.remove.action = #selector(deleteRow(_:))
        row.view.orientation = .vertical
        row.view.alignment = .leading
        row.view.spacing = 4
        let controls = NSStackView(views: [row.action, row.folder, row.record, row.remove])
        controls.spacing = 8
        row.folder.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        row.record.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        row.view.addArrangedSubview(controls)
        row.status.textColor = .systemOrange
        if let hotkey, let failure = failures[hotkey] {
            row.status.stringValue = failure == .conflict
                ? "Unavailable: another app uses this shortcut. Change it or retry after releasing it."
                : "macOS could not register this shortcut. Change it or retry."
        }
        row.view.addArrangedSubview(row.status)
        list.addArrangedSubview(row.view)
        rows.append(row)
    }

    @objc private func addRow() {
        stopRecording()
        guard rows.count < FolderShortcutStore.maximumBindings else { return }
        appendRow()
        updateAdd()
    }

    private func updateAdd() {
        add.isEnabled = rows.count < FolderShortcutStore.maximumBindings
        add.title = "Add Shortcut (\(rows.count)/\(FolderShortcutStore.maximumBindings))"
    }

    @objc private func deleteRow(_ sender: NSButton) {
        guard let row = rows.first(where: { $0.remove === sender }) else { return }
        stopRecording()
        list.removeArrangedSubview(row.view)
        row.view.removeFromSuperview()
        rows.removeAll { $0 === row }
        updateAdd()
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        let wasRecording = recording?.record === sender
        stopRecording()
        guard !wasRecording, let row = rows.first(where: { $0.record === sender }) else { return }
        window.makeFirstResponder(nil)
        recording = row
        row.record.title = "Press shortcut…"
        errorLabel.stringValue = ""
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.recording != nil else { return event }
                return self.receive(event)
            }
        }
        if monitor == nil {
            stopRecording()
            errorLabel.stringValue = "Could not start recording. Try again."
        }
    }

    private func receive(_ event: NSEvent) -> NSEvent? {
        guard let row = recording else { return event }
        if event.keyCode == 53 { stopRecording(); return nil }
        guard !event.isARepeat else { return nil }
        guard ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(event.keyCode) else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            errorLabel.stringValue = "Include Command, Control, or Option."
            return nil
        }
        var modifiers: Hotkey.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        row.hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        row.status.stringValue = ""
        errorLabel.stringValue = ""
        stopRecording()
        return nil
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let row = recording else { return }
        recording = nil
        row.record.title = row.hotkey?.displayString ?? "Record Shortcut…"
        onRecordingChanged(false)
    }

    @objc private func save() {
        stopRecording()
        window.makeFirstResponder(nil)
        do {
            var bindings: [FolderShortcut] = []
            for row in rows {
                guard let hotkey = row.hotkey else {
                    errorLabel.stringValue = "Record a shortcut for every row, or delete unused rows."
                    return
                }
                bindings.append(FolderShortcut(id: row.id, hotkey: hotkey,
                    action: row.action.indexOfSelectedItem == 1 ? .startSession : .quickNote,
                    folder: row.folder.stringValue))
            }
            try onSave(bindings)
            window.close()
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func cancel() { close() }

    func windowDidResignKey(_ notification: Notification) { stopRecording() }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        guard !closed else { return }
        closed = true
        onClose()
    }
}
