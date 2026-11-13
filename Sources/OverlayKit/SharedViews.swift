import AppKit

@MainActor
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Card list backgrounds must receive the first click while the agent remains inactive.
@MainActor
final class NoteCardDocumentView: FlippedView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Full-bleed colour layer that never takes the mouse.
@MainActor
private final class SurfaceTintView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
class OverlaySurface: FlippedView {
    private let effect = NSVisualEffectView()
    private let tint = SurfaceTintView()
    var usesGalleryBackground = false { didSet { updateSurface() } }

    init(size: NSSize, radius: CGFloat = OverlayTheme.panelRadius) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        effect.material = OverlayTheme.material
        effect.blendingMode = OverlayTheme.blending
        effect.state = OverlayTheme.effectState
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        tint.frame = bounds
        addSubview(tint)
        updateSurface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    private func updateSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = OverlayTheme.borderWidth
            layer?.borderColor = OverlayTheme.surfaceBorder.cgColor
            let fill = usesGalleryBackground ? OverlayTheme.surfaceTint.withAlphaComponent(1) : OverlayTheme.surfaceTint
            tint.layer?.backgroundColor = fill.cgColor
        }
        effect.isHidden = usesGalleryBackground
    }
}

@MainActor
func label(_ text: String, font: NSFont, color: NSColor, truncates: Bool = true) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = font
    view.textColor = color
    view.lineBreakMode = truncates ? .byTruncatingTail : .byClipping
    view.maximumNumberOfLines = 1
    view.cell?.wraps = false
    view.cell?.isScrollable = !truncates
    view.setAccessibilityElement(false)
    return view
}

@MainActor
func labelFittingSize(of label: NSTextField) -> NSSize {
    // The cell includes the native text insets; intrinsicContentSize can omit
    // them for a scrolling single-line label and clip the last glyph.
    let size = label.cell?.cellSize ?? label.intrinsicContentSize
    return NSSize(width: ceil(size.width), height: ceil(size.height))
}

@MainActor
func symbol(_ name: String, color: NSColor) -> NSImageView {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    view.contentTintColor = color
    view.imageScaling = .scaleProportionallyUpOrDown
    view.setAccessibilityElement(false)
    return view
}

@MainActor
final class KeycapView: FlippedView {
    let key: NSTextField
    let caption: NSTextField
    private var capsuleWidth: CGFloat {
        ceil(key.attributedStringValue.size().width) + OverlayTheme.hintPadding * 2
    }
    var desiredWidth: CGFloat {
        capsuleWidth
        + (caption.stringValue.isEmpty ? 0 : OverlayTheme.hintLabelGap + labelFittingSize(of: caption).width)
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: desiredWidth, height: max(OverlayTheme.hintHeight, labelFittingSize(of: caption).height))
    }
    private let capsule = FlippedView()

    init(key: String, caption: String = "", color: NSColor = OverlayTheme.secondaryColor) {
        self.key = label(key, font: OverlayTheme.hintFont, color: color, truncates: false)
        self.caption = label(caption, font: OverlayTheme.metaFont, color: color, truncates: false)
        super.init(frame: .zero)
        for view in [self, self.key, self.caption] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = OverlayTheme.hintRadius
        addSubview(capsule)
        capsule.addSubview(self.key)
        addSubview(self.caption)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() {
        super.layout()
        let width = capsuleWidth
        let keySize = labelFittingSize(of: key)
        let captionSize = labelFittingSize(of: caption)
        // Account for the cell's own inset so the glyphs, rather than the field
        // frame, have exactly hintPadding on each side of the capsule.
        let cellInset = (keySize.width - ceil(key.attributedStringValue.size().width)) / 2
        capsule.frame = NSRect(x: 0, y: (bounds.height - OverlayTheme.hintHeight) / 2,
                               width: width, height: OverlayTheme.hintHeight)
        key.frame = NSRect(x: OverlayTheme.hintPadding - cellInset, y: (OverlayTheme.hintHeight - keySize.height) / 2,
                           width: keySize.width, height: keySize.height)
        // A caption given less room than its text truncates; at its desired width this is the full text.
        let captionWidth = min(captionSize.width, max(0, bounds.width - (width + OverlayTheme.hintLabelGap)))
        caption.frame = NSRect(x: width + OverlayTheme.hintLabelGap, y: (bounds.height - captionSize.height) / 2,
                               width: captionWidth, height: captionSize.height)
        effectiveAppearance.performAsCurrentDrawingAppearance { capsule.layer?.backgroundColor = OverlayTheme.hintFill.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
}

@MainActor
final class OverlayTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(placeholder: String) {
        super.init(frame: .zero)
        font = OverlayTheme.inputFont
        textColor = OverlayTheme.textColor
        placeholderString = placeholder
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        maximumNumberOfLines = 1
        cell?.wraps = false
        cell?.isScrollable = true
        setAccessibilityLabel(placeholder)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

@MainActor
final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        OverlayTheme.separatorColor.setFill()
        bounds.fill()
    }
}

@MainActor
final class ChoiceRowView: FlippedView {
    enum Kind { case note, suggestion, image }
    let title: NSTextField
    let secondary: NSTextField
    let meta: NSTextField
    let icon: NSImageView
    var onClick: (() -> Void)?
    private let selected: Bool
    private let kind: Kind

    init(title: NSAttributedString, secondary: NSAttributedString, meta: String,
         iconName: String?, selected: Bool, kind: Kind = .note) {
        self.selected = selected
        self.kind = kind
        self.title = label("", font: OverlayTheme.titleFont, color: OverlayTheme.textColor)
        self.secondary = label("", font: OverlayTheme.snippetFont, color: OverlayTheme.secondaryColor)
        self.meta = label(meta, font: OverlayTheme.metaFont, color: selected ? OverlayTheme.selectedSecondary : OverlayTheme.tertiaryColor)
        self.icon = symbol(iconName ?? OverlayTheme.textSymbol, color: selected ? OverlayTheme.selectedText : OverlayTheme.secondaryColor)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = OverlayTheme.selectedRadius
        self.title.attributedStringValue = title
        self.secondary.attributedStringValue = secondary
        if kind == .suggestion { self.secondary.alignment = .right }
        addSubview(self.title); addSubview(self.secondary); addSubview(self.meta)
        if iconName != nil || kind == .image { addSubview(self.icon) }
        if kind == .image {
            self.icon.image = nil
            self.icon.wantsLayer = true
            self.icon.layer?.cornerRadius = OverlayTheme.thumbnailRadius
            self.icon.layer?.masksToBounds = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([title.string, secondary.string].filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilitySelectedValue(selected)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? OverlayTheme.selectedFill.cgColor : nil
        }
        let inset = OverlayTheme.rowInset
        if kind == .suggestion {
            let iconSize = OverlayTheme.suggestionIconSize
            icon.frame = NSRect(x: inset + (OverlayTheme.suggestionLeadingWidth - iconSize) / 2,
                                y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            let x = inset + OverlayTheme.suggestionLeadingWidth + OverlayTheme.suggestionIconGap
            let trailing = bounds.width - OverlayTheme.suggestionTrailingInset
            let gap = secondary.stringValue.isEmpty ? 0 : OverlayTheme.padding
            let secondarySize = labelFittingSize(of: secondary)
            let secondaryWidth = secondary.stringValue.isEmpty ? 0 : min(secondarySize.width, max(0, trailing - x - gap))
            let secondaryX = trailing - secondaryWidth
            let titleHeight = labelFittingSize(of: title).height
            title.frame = NSRect(x: x, y: (bounds.height - titleHeight) / 2,
                                 width: max(0, secondaryX - gap - x), height: titleHeight)
            secondary.frame = NSRect(x: secondaryX, y: (bounds.height - secondarySize.height) / 2,
                                     width: secondaryWidth, height: secondarySize.height)
            meta.frame = .zero
            return
        }
        let iconSize = kind == .image ? OverlayTheme.thumbnailSize : OverlayTheme.iconSize
        let leadingWidth = OverlayTheme.thumbnailSize
        icon.frame = NSRect(x: inset + (leadingWidth - iconSize) / 2,
                            y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let x = inset + leadingWidth + OverlayTheme.iconGap
        let width = bounds.width - x - inset
        let secondaryHeight = secondary.stringValue.isEmpty ? 0 : OverlayTheme.snippetLineHeight
        let metaHeight = meta.stringValue.isEmpty ? 0 : OverlayTheme.metaLineHeight
        let height = OverlayTheme.titleLineHeight + secondaryHeight + metaHeight
        let y = (bounds.height - height) / 2
        title.frame = NSRect(x: x, y: y, width: width, height: OverlayTheme.titleLineHeight)
        secondary.frame = NSRect(x: x, y: y + OverlayTheme.titleLineHeight, width: width, height: secondaryHeight)
        meta.frame = NSRect(x: x, y: y + OverlayTheme.titleLineHeight + secondaryHeight, width: width, height: metaHeight)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
}

@MainActor
func attributed(_ text: String, font: NSFont, color: NSColor, matches: [NSRange] = [], matchFont: NSFont? = nil, matchColor: NSColor? = nil) -> NSAttributedString {
    let value = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    for range in matches where range.location != NSNotFound && range.location >= 0 && range.length > 0
        && range.location <= value.length && range.length <= value.length - range.location {
        value.addAttributes([.font: matchFont ?? font, .foregroundColor: matchColor ?? color], range: range)
    }
    return value
}

extension NSView {
    /// VoiceOver value for the highlighted row of a list.
    func setAccessibilitySelectedValue(_ selected: Bool) { setAccessibilityValue(selected ? "Selected" : "") }
}
