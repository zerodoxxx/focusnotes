import AppKit

public struct ThoughtEditorContent: Sendable {
    public enum Excerpt: Sendable { case text(String); case image(@Sendable () async -> NSImage?) }
    public var sourceTitle: String
    public var sourceDetail: String?
    public var excerpt: Excerpt
    public var text: String
    public init(sourceTitle: String, sourceDetail: String? = nil, excerpt: Excerpt, text: String = "") {
        self.sourceTitle = sourceTitle; self.sourceDetail = sourceDetail; self.excerpt = excerpt; self.text = text
    }
}

@MainActor private final class ThoughtEditorView: OverlaySurface {
    private static let contentWidth: CGFloat = 440
    private static let excerptMaxLines = 6
    private static let imageMaxHeight: CGFloat = 120
    let editor = NSTextView(frame: .zero)
    let error = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let excerpt = NSTextField(wrappingLabelWithString: "")
    private let imageView = NSImageView()
    private let thoughtLabel = NSTextField(labelWithString: "My thought")
    private let scroll = NSScrollView()
    private let saveKey = KeycapView(key: "⌘S", caption: "Save")
    private let closeKey = KeycapView(key: "esc", caption: "Close")
    private var excerptHeight: CGFloat = 0

    init(_ content: ThoughtEditorContent, image: NSImage? = nil, errorMessage: String? = nil) {
        super.init(size: .zero, radius: OverlayTheme.panelRadius)
        title.stringValue = content.sourceTitle; title.font = OverlayTheme.titleFont; title.lineBreakMode = .byTruncatingTail
        detail.stringValue = content.sourceDetail ?? ""; detail.font = OverlayTheme.metaFont; detail.textColor = OverlayTheme.secondaryColor
        detail.isHidden = content.sourceDetail == nil
        excerpt.font = OverlayTheme.snippetFont
        // Tail truncation is only honored by wrapping cells, so keep the wrap mode and truncate the last line instead.
        excerpt.maximumNumberOfLines = ThoughtEditorView.excerptMaxLines; excerpt.cell?.truncatesLastVisibleLine = true
        imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.imageAlignment = .alignLeft
        thoughtLabel.font = OverlayTheme.titleFont
        editor.font = OverlayTheme.editorFont; editor.string = content.text; editor.isRichText = false; editor.allowsUndo = true
        editor.textContainer?.widthTracksTextView = true; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .lineBorder
        error.stringValue = errorMessage ?? ""; error.textColor = OverlayTheme.warningColor; error.font = OverlayTheme.metaFont; error.isHidden = errorMessage == nil
        [title, detail, excerpt, imageView, thoughtLabel, scroll, error, saveKey, closeKey].forEach(addSubview)

        let isImageExcerpt: Bool
        if case .text(let value) = content.excerpt { excerpt.stringValue = value; isImageExcerpt = false } else { isImageExcerpt = true }
        excerpt.isHidden = isImageExcerpt; imageView.isHidden = !isImageExcerpt
        imageView.image = image
        // Until the image loads, reserve the maximum height so the panel does not jump twice.
        excerptHeight = isImageExcerpt ? image.map(ThoughtEditorView.imageHeight) ?? ThoughtEditorView.imageMaxHeight : ThoughtEditorView.textHeight(excerpt.stringValue)
        title.frame = NSRect(x: OverlayTheme.quickTextInset, y: 16, width: ThoughtEditorView.contentWidth, height: 22)
        detail.frame = NSRect(x: OverlayTheme.quickTextInset, y: 40, width: ThoughtEditorView.contentWidth, height: 18)
        layoutContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Called when the async excerpt image arrives; nil means it could not be loaded and the row collapses.
    func setImage(_ image: NSImage?) {
        imageView.image = image
        imageView.isHidden = image == nil
        excerptHeight = image.map(ThoughtEditorView.imageHeight) ?? 0
        layoutContent()
    }

    private func layoutContent() {
        let inset = OverlayTheme.quickTextInset, width = inset * 2 + ThoughtEditorView.contentWidth
        let excerptFrame = NSRect(x: inset, y: 64, width: ThoughtEditorView.contentWidth, height: excerptHeight)
        excerpt.frame = excerptFrame; imageView.frame = excerptFrame
        let labelY = excerptFrame.maxY + 14
        thoughtLabel.frame = NSRect(x: inset, y: labelY, width: ThoughtEditorView.contentWidth, height: 22)
        let scrollY = labelY + 26
        scroll.frame = NSRect(x: inset, y: scrollY, width: ThoughtEditorView.contentWidth, height: 118)
        let errorY = scrollY + 118 + 10
        error.frame = NSRect(x: inset, y: errorY, width: 310, height: OverlayTheme.hintHeight)
        let footerY = errorY + 32
        closeKey.frame = NSRect(x: width - inset - closeKey.desiredWidth, y: footerY, width: closeKey.desiredWidth, height: OverlayTheme.hintHeight)
        saveKey.frame = NSRect(x: closeKey.frame.minX - OverlayTheme.footerHintGap - saveKey.desiredWidth, y: footerY, width: saveKey.desiredWidth, height: OverlayTheme.hintHeight)
        setFrameSize(NSSize(width: width, height: footerY + OverlayTheme.hintHeight + 12))
    }

    /// Wraps like the label will render, capped at the excerpt line limit so the tail truncates with an ellipsis.
    private static func textHeight(_ text: String) -> CGFloat {
        let font = OverlayTheme.snippetFont
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let needed = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        return min(ceil(needed), lineHeight * CGFloat(excerptMaxLines))
    }

    private static func imageHeight(_ image: NSImage) -> CGFloat {
        guard image.size.width > 0 else { return imageMaxHeight }
        return min(imageMaxHeight, ceil(contentWidth * image.size.height / image.size.width))
    }
}

@MainActor public final class ThoughtEditorPanel {
    public struct Handlers { public var onSave: (String) -> Void; public var onClose: (String) -> Void; public init(onSave: @escaping (String) -> Void, onClose: @escaping (String) -> Void) { self.onSave = onSave; self.onClose = onClose } }
    private var panel: OverlayPanel?; private var view: ThoughtEditorView?; private var handlers: Handlers?; private var saving = false
    // Bumped on every transition so callbacks from a panel that is already closing are ignored.
    private var generation = 0
    public private(set) var captureID: UUID?; public var isVisible: Bool { panel?.isVisible ?? false }; public var currentText: String? { view?.editor.string }; public var instanceID: Int { generation }; public init() {}
    public func present(captureID: UUID, content: ThoughtEditorContent, handlers: Handlers) {
        if panel != nil { finish(close: true) }
        generation += 1
        let token = generation
        let view = ThoughtEditorView(content); self.view = view; self.handlers = handlers; self.captureID = captureID; saving = false
        let panel = OverlayPanel(interactive: true, size: view.frame.size); self.panel = panel
        // Sticky like the note editor, so session prompts and captures leave the draft open.
        panel.isSticky = true
        panel.onClose = { [weak self] in guard let self, self.generation == token else { return }; self.finish(close: true, alreadyClosed: true) }
        panel.onKey = { [weak self] event in
            guard let self else { return false }
            if event.keyCode == OverlayKeyCode.escape { self.finish(close: true); return true }
            if event.modifierFlags.contains(.command) && (event.charactersIgnoringModifiers?.lowercased() == "s" || event.keyCode == OverlayKeyCode.returnKey) { guard !self.saving else { return true }; self.saving = true; self.handlers?.onSave(self.view?.editor.string ?? ""); return true }
            return false
        }
        if case .image(let load) = content.excerpt {
            Task { @MainActor [weak self, weak view] in
                let image = await load()
                guard let self, let view, self.generation == token else { return }
                view.setImage(image)
                self.panel?.resizeContent(to: view.frame.size)
            }
        }
        panel.present(content: view); panel.makeKey(); panel.makeFirstResponder(view.editor)
        view.editor.setSelectedRange(NSRange(location: (view.editor.string as NSString).length, length: 0))
    }
    private func finish(close: Bool, alreadyClosed: Bool = false) {
        generation += 1
        let old = panel; let text = view?.editor.string ?? ""; let callback = handlers?.onClose
        panel = nil; view = nil; handlers = nil; captureID = nil; saving = false
        if close && !alreadyClosed { old?.dismiss() }
        callback?(text)
    }
    // Text typed while the save was pending keeps the editor open and saveable.
    public func saveSucceeded(_ savedText: String) { if currentText == savedText { dismiss() } else { saving = false } }
    public func saveFailed(_ message: String) { saving = false; view?.error.stringValue = message; view?.error.isHidden = false }
    public func dismiss() {
        generation += 1
        let old = panel; panel = nil; view = nil; handlers = nil; captureID = nil; saving = false
        old?.dismiss()
    }
}

@MainActor extension OverlayPreview {
    @_spi(Checks) public static func thoughtEditor(_ content: ThoughtEditorContent, error: String? = nil, image: NSImage? = nil) -> NSView { let view = ThoughtEditorView(content, image: image, errorMessage: error); view.usesGalleryBackground = true; return view }
}
