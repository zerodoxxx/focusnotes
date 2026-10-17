import AppKit
import Darwin
import OverlayKit

@MainActor
func thumbnail() -> NSImage {
    NSImage(size: NSSize(width: 72, height: 72), flipped: false) { bounds in
        NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.29, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedRed: 0.45, green: 0.72, blue: 0.88, alpha: 1).setStroke()
        let connections = NSBezierPath()
        connections.move(to: NSPoint(x: 20, y: 52)); connections.line(to: NSPoint(x: 52, y: 52))
        connections.move(to: NSPoint(x: 36, y: 52)); connections.line(to: NSPoint(x: 36, y: 22))
        connections.move(to: NSPoint(x: 20, y: 22)); connections.line(to: NSPoint(x: 52, y: 22))
        connections.lineWidth = 2; connections.stroke()
        for point in [NSPoint(x: 12, y: 44), NSPoint(x: 44, y: 44), NSPoint(x: 28, y: 14)] {
            NSColor(calibratedRed: 0.35, green: 0.65, blue: 0.81, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(origin: point, size: NSSize(width: 16, height: 16)), xRadius: 3, yRadius: 3).fill()
        }
        return true
    }
}

@MainActor
func recent() -> [SearchSection] {
    [SearchSection(title: "Recent", rows: [
        SearchRow(id: "system", title: "System Design", snippet: "Design a reliable notification service at scale.", meta: "10:04 · Safari · System Design"),
        SearchRow(id: "limits", title: "Rate limiting", snippet: "Token buckets allow controlled bursts of requests.", meta: "09:58 · Safari · System Design"),
        SearchRow(id: "diagram", title: "Service architecture", snippet: "Gateway, queue, and worker topology.", meta: "09:51 · Preview · System Design", kind: .image, thumbnailLoader: { thumbnail() }),
        SearchRow(id: "mle", title: "MLE Interview Prep", snippet: "Feature stores, evaluation, and serving latency.", meta: "Yesterday · Notes · Interview Prep", kind: .note),
        SearchRow(id: "cache", title: "Caching patterns", snippet: "Cache aside with explicit invalidation boundaries.", meta: "Yesterday · Safari · System Design"),
        SearchRow(id: "queue", title: "Message queues", snippet: "At least once delivery needs idempotent consumers.", meta: "Oct 9 · Safari · System Design")
    ])]
}

@MainActor
func matched() -> [SearchSection] {
    [SearchSection(title: "Captures", rows: [
        SearchRow(id: "limit", title: "Rate limiting", titleMatches: [NSRange(location: 5, length: 5)],
                  snippet: "A rate limit protects services from traffic spikes.", snippetMatches: [NSRange(location: 7, length: 5)],
                  meta: "10:04 · Safari · System Design"),
        SearchRow(id: "token", title: "Token bucket limits", titleMatches: [NSRange(location: 13, length: 5)],
                  snippet: "Set a limit per user, route, and time window.", snippetMatches: [NSRange(location: 6, length: 5)],
                  meta: "09:58 · Safari · System Design")
    ]), SearchSection(title: "Notes", rows: [
        SearchRow(id: "note", title: "System Design", snippet: "Rate limiting: fixed windows versus token buckets.",
                  snippetMatches: [NSRange(location: 5, length: 5)], meta: "Oct 9 · System Design", kind: .note)
    ])]
}

let suggestions = [
    Suggestion(title: "System Design", secondary: "Session · Oct 9", symbolName: "record.circle"),
    Suggestion(title: "MLE Interview Prep", secondary: "Session · Oct 8", symbolName: "record.circle"),
    Suggestion(title: "Rate limiting", secondary: "Note · System Design", symbolName: "doc.text"),
    Suggestion(title: "Distributed systems", secondary: "Note · System Design", symbolName: "doc.text")
]

struct GalleryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
func writePNG(_ view: NSView, appearance: NSAppearance, to url: URL) throws {
    // Hosting in an unordered nonactivating panel supplies a backing environment
    // to AppKit. Pixels come exclusively from view caching, never the display.
    let host = OverlayPanel(interactive: false, size: view.frame.size)
    host.appearance = appearance
    host.contentView = view
    view.appearance = appearance
    view.layoutSubtreeIfNeeded()
    var failure: Error?
    appearance.performAsCurrentDrawingAppearance {
        guard let prototype = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                  pixelsWide: Int(view.bounds.width * OverlayTheme.galleryScale),
                  pixelsHigh: Int(view.bounds.height * OverlayTheme.galleryScale),
                  bitsPerSample: prototype.bitsPerSample, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            failure = GalleryError("Could not allocate bitmap: \(url.lastPathComponent)"); return
        }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            failure = GalleryError("Could not encode PNG: \(url.lastPathComponent)"); return
        }
        do { try checkEditorCodePixels(view, bitmap: bitmap); try checkFloatingCardPixels(view, bitmap: bitmap); try png.write(to: url) } catch { failure = error }
    }
    host.contentView = nil
    if let failure { throw failure }
    print(url.path)
}

@MainActor
func generateGallery() async throws {
    try checkMarkdownStyler()
    try checkLivePreviewGlyphs()
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/gallery", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        guard let appearance = NSAppearance(named: appearanceName) else { throw GalleryError("Appearance unavailable") }
        func save(_ view: NSView, _ name: String) throws {
            try writePNG(view, appearance: appearance, to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
        for (style, title, subtitle, stem) in [
            (Toast.Style.success, "Capture saved", "Added to System Design", "success"),
            (.warning, "Choose a destination", "Your capture is waiting for a note", "warning"),
            (.session, "Session started", "MLE Interview Prep", "session"),
            (.copied, "Copied to clipboard", "Ready to paste into your notes", "copied")
        ] {
            for hasSubtitle in [false, true] {
                for hasHint in [false, true] {
                    let toast = Toast(style: style, title: title, subtitle: hasSubtitle ? subtitle : nil,
                                      hint: hasHint ? Toast.Hint(key: "⌥⇧C", label: "name") : nil)
                    try save(OverlayPreview.toast(toast), "toast-\(stem)-\(hasSubtitle ? "subtitle" : "plain")-\(hasHint ? "hint" : "no-hint")")
                }
            }
        }
        try save(OverlayPreview.noteEditor(), "editor-empty")
        try save(OverlayPreview.noteEditor(destination: "System Design", text: "- [ ] jdf", selection: NSRange(location: 9, length: 0)), "editor-typing-task")
        try save(OverlayPreview.noteEditor(text: "## Ideas for tomorrow\n- Make space for a focused morning\n- [ ] Review the next step", selection: NSRange(location: 3, length: 0)), "editor-new-note")
        try save(OverlayPreview.noteEditor(destination: "System Design", text: "A thought to come back to.\n- [ ] Check the retry policy", restoredDraft: true), "editor-draft")
        try save(OverlayPreview.noteEditor(destination: "System Design", text: editorSample, selection: NSRange(location: 3, length: 0)), "editor-styles")
        let bulletCaret = (editorSample as NSString).range(of: "A long item").location
        try save(OverlayPreview.noteEditor(destination: "System Design", text: editorSample, selection: NSRange(location: bulletCaret, length: 0)), "editor-caret-on-list")
        let quickText = "# Trip planning\nBook the train for Friday and call Anna about the hotel."
        let longNote = (1...44).map { "Line \($0): a thought worth keeping" }.joined(separator: "\n")
        let wideNote = "This is a single very long line that keeps going well past the width cap so the editor has to wrap it instead of growing forever, which is the behaviour under test.\nShort one\n- a bullet\nAnother short line"
        try save(OverlayPreview.noteEditor(text: quickText), "quick-rest")
        try save(OverlayPreview.noteEditor(text: quickText, revealed: true), "quick-hover")
        try save(OverlayPreview.noteEditor(text: quickText, isPinned: true), "quick-rest-pinned")
        try save(OverlayPreview.noteEditor(text: quickText, revealed: true, isPinned: true), "quick-hover-pinned")
        try save(OverlayPreview.noteEditor(text: "- [ ] ", selection: NSRange(location: 6, length: 0)), "quick-caret-checkbox")
        try save(OverlayPreview.noteEditor(text: "- [ ] Review the plan\n- [x] Book the train", selection: NSRange(location: 6, length: 0)), "quick-caret-checkbox-text")
        try save(OverlayPreview.noteEditor(text: quickText, selection: NSRange(location: (quickText as NSString).length, length: 0)), "quick-caret-body")
        try save(OverlayPreview.noteEditor(revealed: true), "quick-empty-hover")
        try save(OverlayPreview.noteEditor(text: longNote, revealed: true), "quick-long")
        try save(OverlayPreview.noteEditor(text: wideNote, revealed: true), "quick-wide")
        try save(OverlayPreview.noteEditor(destination: "Trip planning", text: quickText, revealed: true), "quick-existing")
        try save(OverlayPreview.noteEditor(destination: "MLE Interview Prep and Other Long Titles", text: quickText, restoredDraft: true, revealed: true), "quick-footer-long")
        let twoLines = "# Trip planning\nBook the train for Friday."
        let browseItems = [
            BrowseItem(id: "/vault/Trip planning.md", title: "Trip planning", detail: "Note · Oct 12", symbolName: "doc.text", isPinned: true),
            BrowseItem(id: "/vault/MLE Interview Prep.md", title: "MLE Interview Prep", detail: "Session · Oct 9", symbolName: "record.circle", isPinned: true),
            BrowseItem(id: "/vault/System Design.md", title: "System Design", detail: "Session · Oct 9", symbolName: "record.circle", isPinned: false),
            BrowseItem(id: "/vault/Reading list.md", title: "Reading list", detail: "Note · Oct 8", symbolName: "doc.text", isPinned: false),
            BrowseItem(id: "/vault/Weekend trip ideas.md", title: "Weekend trip ideas", detail: "Note · Oct 6", symbolName: "doc.text", isPinned: false),
            BrowseItem(id: "/vault/Standup notes.md", title: "Standup notes", detail: "Session · Oct 3", symbolName: "record.circle", isPinned: false),
            BrowseItem(id: "/vault/Groceries.md", title: "Groceries", detail: "Note · Oct 1", symbolName: "doc.text", isPinned: false),
            BrowseItem(id: "/vault/Book club.md", title: "Book club", detail: "Note · Sep 28", symbolName: "doc.text", isPinned: false),
        ]
        try save(OverlayPreview.noteEditor(text: twoLines, revealed: true, overlay: .actions(selected: 0)), "quick-actions")
        try save(OverlayPreview.noteEditor(text: twoLines, revealed: true, isPinned: true, overlay: .actions(selected: 0)), "quick-actions-pinned")
        try save(OverlayPreview.noteEditor(text: twoLines, revealed: true, overlay: .actions(query: "pin")), "quick-actions-filtered")
        try save(OverlayPreview.noteEditor(revealed: true, overlay: .actions(selected: 0)), "quick-actions-empty-text")
        try save(OverlayPreview.noteEditor(text: twoLines, overlay: .browse(items: browseItems, selected: 0)), "quick-browse")
        let scrollingItems = browseItems + (1...4).map {
            BrowseItem(id: "/vault/Older note \($0).md", title: "Older note \($0)", detail: "Note · Sep \(20 - $0)", symbolName: "doc.text", isPinned: false)
        }
        try save(OverlayPreview.noteEditor(text: twoLines, overlay: .browse(items: scrollingItems, selected: 0)), "quick-browse-scroll")
        try save(OverlayPreview.noteEditor(text: twoLines, overlay: .browse(items: browseItems, query: "trip", selected: 0)), "quick-browse-filtered")
        try save(OverlayPreview.noteEditor(text: twoLines, overlay: .browse(items: [])), "quick-browse-empty")
        try save(OverlayPreview.noteEditor(text: twoLines, overlay: .browse(items: browseItems, query: "zzz")), "quick-browse-none")
        try save(OverlayPreview.input(placeholder: "Subheading", title: "Add subheading", secondary: "In System Design"), "input-subheading")
        try save(OverlayPreview.input(placeholder: "Name this session"), "input-empty")
        try save(OverlayPreview.input(placeholder: "Name this session", text: "System", suggestions: suggestions), "input-suggestions")
        try save(OverlayPreview.input(placeholder: "Name this session", text: "System", suggestions: suggestions, selection: 0), "input-selected")
        try save(await OverlayPreview.search(sections: recent()), "search-recent")
        try save(await OverlayPreview.search(sections: matched(), query: "limit"), "search-matches")
        try save(await OverlayPreview.search(sections: [], query: "consistent hashing", selection: nil), "search-no-results")
        try save(await OverlayPreview.search(sections: recent(), query: "distributed", selection: nil, loading: true), "search-loading")
    }
}

@MainActor
final class LiveGallery: NSObject {
    let toast = ToastController()
    let input = InputPanelController()
    let search = SearchPanelController()
    let editor = NoteEditorPanel()
    private var escapeMonitor: Any?

    func start(_ component: String) throws {
        let finish: () -> Void = {
            // Defer termination until the action callback that closed the panel returns.
            Task { @MainActor in NSApp.terminate(nil) }
        }
        switch component {
        case "toast", "success", "warning", "session", "copied":
            let style: Toast.Style = switch component {
            case "warning": .warning
            case "session": .session
            case "copied": .copied
            default: .success
            }
            toast.onExpire = finish
            toast.show(Toast(style: style, title: "Capture saved", subtitle: "Added to System Design",
                             hint: .init(key: "⌥⇧C", label: "name")))
            // A toast never receives keys, so Esc is observed globally for the demo.
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    if event.keyCode == 53 { self?.toast.dismiss(expire: false); NSApp.terminate(nil) }
                }
            }
        case "editor":
            editor.present(destination: "System Design", isPinned: false, draft: ProcessInfo.processInfo.environment["GALLERY_SHORT_NOTE"] == "1" ? "First line\nSecond line" : editorSample, handlers: NoteEditorHandlers(
                onDraft: { _ in }, onSubmit: { print("Submitted: \($0)"); finish() },
                onNew: { print("New: \($0)"); finish() }, onOpenAsNote: { print("Open as note: \($0)"); finish() },
                browseItems: { [
                    BrowseItem(id: "trip", title: "Trip planning", detail: "Note · Oct 12", symbolName: "doc.text", isPinned: true),
                    BrowseItem(id: "system", title: "System Design", detail: "Session · Oct 9", symbolName: "record.circle", isPinned: false),
                    BrowseItem(id: "reading", title: "Reading list", detail: "Note · Oct 8", symbolName: "doc.text", isPinned: false)
                ] }, onBrowse: { item, choice in print("Browse: \(item.title) \(choice)") },
                onTogglePin: { true }, onClose: finish, onError: { print($0) }))

        case "subheading":
            input.present(placeholder: "Subheading", title: "Add subheading", secondary: "In System Design", suggestions: { _ in [] },
                          onSubmit: { print("Submitted: \($0)"); finish() }, onCancel: finish)
        case "input":
            input.present(placeholder: "Name this session", initialText: "", suggestions: { _ in suggestions },
                          onSubmit: { print("Submitted: \($0)"); finish() }, onCancel: finish)
        case "search":
            search.present(query: { text in
                if text.isEmpty { return recent() }
                if text.lowercased().contains("limit") { return matched() }
                return recent().map { SearchSection(title: $0.title, rows: $0.rows.filter { $0.title.localizedCaseInsensitiveContains(text) }) }
            }, actions: SearchActions(primary: { print("Copy: \($0.title)"); finish() },
                                      open: { print("Open: \($0.title)"); finish() },
                                      reveal: { print("Reveal: \($0.title)"); finish() }, onClose: finish))
        default: throw GalleryError("Unknown live component: \(component). Use toast, input, search, success, warning, session, or copied.")
        }
    }
}

NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.finishLaunching()
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--live" {
        guard arguments.count == 2 else { throw GalleryError("Usage: OverlayGallery --live <toast|input|search>") }
        let live = LiveGallery()
        try live.start(arguments[1])
        withExtendedLifetime(live) { NSApplication.shared.run() }
    } else if arguments == ["--check"] {
        // Interactive panels dismiss when another process takes key focus, so concurrent runs
        // would fail each other. Serialize them on a lock held for this process's lifetime.
        let lock = open(NSTemporaryDirectory() + "overlaygallery-check.lock", O_CREAT | O_RDWR, 0o600)
        if lock >= 0 {
            let start = Date()
            var announced = false
            while flock(lock, LOCK_EX | LOCK_NB) != 0 {
                let waited = Date().timeIntervalSince(start)
                if waited > 120 { throw GalleryError("Timed out after 120s waiting for another OverlayGallery --check run") }
                if waited > 2, !announced { print("Waiting for another OverlayGallery --check run…"); announced = true }
                usleep(100_000)
            }
        }
        var failure: Error?
        Task { @MainActor in
            do { try await runBehaviorChecks() } catch { failure = error }
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: false)
            }
        }
        NSApp.run()
        if let failure { throw failure }
    } else {
        guard arguments.isEmpty else { throw GalleryError("Usage: OverlayGallery [--live <component>|--check]") }
        try await generateGallery()
    }
} catch {
    print("Gallery failed: \(error)")
    exit(EXIT_FAILURE)
}
