import AppKit
import CoreText

/// Code decorations resolve their tint within the text view's drawing appearance.
@MainActor
final class MarkdownLayoutManager: NSLayoutManager {
    private var selectionLines = Set<NSRange>()
    private var composingLines = Set<NSRange>()
    private var pendingSelectionInvalidationLines = Set<NSRange>()
    private var activeElements = Set<MarkdownStyler.Element>()
    private var activeSyntaxCharacters = IndexSet()
    private var composingCharacters = IndexSet()
    private var startingCompositionCharacters = IndexSet()
    private var startingComposition = false
    private var pendingCharacterEdit = false
    private(set) var lastSelectionInvalidations: [NSRange] = []
    private(set) var selectionRevision = 0

    private var glyphDelegate: MarkdownGlyphDelegate?
    func enablePreview() {
        let glyphDelegate = MarkdownGlyphDelegate()
        glyphDelegate.owner = self
        self.glyphDelegate = glyphDelegate
        delegate = glyphDelegate
    }

    /// Reveal an active Markdown element before AppKit computes insertion points.
    /// Attribute lookup is limited to the old and new selection lines.
    @discardableResult
    func updateSelection(_ selections: [NSRange], markedRange: NSRange = NSRange(location: NSNotFound, length: 0)) -> Bool {
        guard !pendingCharacterEdit else { return false }
        guard let storage = textStorage else { return false }
        let source = storage.string as NSString
        let nextSelectionLines = logicalLines(selections, in: source)
        let nextComposing = markedRange.location == NSNotFound ? Set<NSRange>() : logicalLines([markedRange], in: source)
        let affectedLines = selectionLines.union(nextSelectionLines).union(composingLines)
            .union(nextComposing).union(pendingSelectionInvalidationLines)
        let affectedRanges = affectedLines.compactMap { bounded($0, to: source.length) }
        var elements = Set<MarkdownStyler.Element>()
        for range in affectedRanges {
            storage.enumerateAttribute(MarkdownStyler.element, in: range) { value, _, _ in
                if let element = value as? MarkdownStyler.Element { elements.insert(element) }
            }
        }
        elements.formUnion(activeElements.filter { element in affectedRanges.contains { NSIntersectionRange(element.range, $0).length > 0 } })

        var nextActive = activeElements.subtracting(elements)
        for element in elements where isActive(element, for: selections) { nextActive.insert(element) }

        var nextSyntaxCharacters = activeSyntaxCharacters
        for range in affectedRanges { nextSyntaxCharacters.remove(integersIn: range.location..<NSMaxRange(range)) }
        for range in affectedRanges {
            storage.enumerateAttribute(MarkdownStyler.syntax, in: range) { value, run, _ in
                guard value as? Bool == true else { return }
                var offset = run.location
                while offset < NSMaxRange(run) {
                    guard let element = storage.attribute(MarkdownStyler.element, at: offset, effectiveRange: nil) as? MarkdownStyler.Element else {
                        offset += 1; continue
                    }
                    let next = min(NSMaxRange(run), NSMaxRange(element.range))
                    if nextActive.contains(element) { nextSyntaxCharacters.insert(integersIn: offset..<next) }
                    offset = max(offset + 1, next)
                }
            }
        }

        let changedElements = activeElements.symmetricDifference(nextActive)
        let changedComposition = composingLines.symmetricDifference(nextComposing)
        selectionLines = nextSelectionLines
        composingLines = nextComposing
        activeElements = nextActive
        activeSyntaxCharacters = nextSyntaxCharacters
        composingCharacters = indices(in: nextComposing)
        startingCompositionCharacters = []
        startingComposition = false
        pendingSelectionInvalidationLines.removeAll()

        var invalidations = Set<NSRange>()
        for element in changedElements {
            if let range = bounded(element.range, to: source.length), range.length > 0 { invalidations.insert(range) }
            if element.kind == .blockMarker, hasParagraphVariant(for: element) {
                let line = source.lineRange(for: NSRange(location: min(source.length, element.range.location), length: 0))
                if let range = bounded(line, to: source.length), range.length > 0 { invalidations.insert(range) }
            }
        }
        for line in changedComposition {
            if let range = bounded(line, to: source.length), range.length > 0 { invalidations.insert(range) }
        }
        guard !invalidations.isEmpty else { return false }
        selectionRevision += 1
        lastSelectionInvalidations = invalidations.sorted { $0.location < $1.location }
        for line in lastSelectionInvalidations {
            if hasParagraphVariant(in: line) { applyParagraphs(in: line) }
            invalidateGlyphs(forCharacterRange: line, changeInLength: 0, actualCharacterRange: nil)
            invalidateDisplay(forCharacterRange: line)
        }
        return true
    }

    /// Keep the small set of selection/composition caches aligned with NSTextStorage's
    /// post-edit coordinates. The attributed Element values are rebased by the editor;
    /// this method moves only currently active ranges, never scans the document.
    func textDidEdit(range: NSRange, changeInLength delta: Int) {
        guard let storage = textStorage else { return }
        pendingCharacterEdit = true
        let source = storage.string as NSString
        let location = min(max(0, range.location), source.length)
        let oldLength = max(0, range.length - delta)
        let oldRange = NSRange(location: location, length: oldLength)
        let oldEnd = NSMaxRange(oldRange)
        let currentLength = source.length
        let newRange = NSRange(location: location, length: min(max(0, range.length), currentLength - location))
        pendingSelectionInvalidationLines.formUnion(logicalLines([newRange], in: source))

        func shifted(_ value: NSRange) -> NSRange? {
            let end = NSMaxRange(value)
            let newLocation: Int
            if oldLength == 0 {
                if end <= location { return value }
                if value.location >= location { newLocation = value.location + delta }
                else { return nil }
            } else {
                if end <= location { return value }
                if value.location >= oldEnd { newLocation = value.location + delta }
                else { return nil }
            }
            guard newLocation >= 0, newLocation + value.length <= currentLength else { return nil }
            return NSRange(location: newLocation, length: value.length)
        }

        selectionLines = Set(selectionLines.compactMap(shifted))
        composingLines = Set(composingLines.compactMap(shifted))
        activeElements = Set(activeElements.compactMap { element in
            guard let range = shifted(element.range) else { return nil }
            return MarkdownStyler.Element(range: range, kind: element.kind)
        })

        func shiftedIndices(_ values: IndexSet) -> IndexSet {
            var result = IndexSet()
            for run in values.rangeView {
                if run.lowerBound < location {
                    let end = min(run.upperBound, location)
                    if end > run.lowerBound { result.insert(integersIn: run.lowerBound..<end) }
                }
                let suffixStart = max(run.lowerBound, oldEnd)
                let suffixEnd = run.upperBound
                let movedStart = max(0, suffixStart + delta)
                let movedEnd = min(currentLength, suffixEnd + delta)
                if movedEnd > movedStart { result.insert(integersIn: movedStart..<movedEnd) }
            }
            return result
        }
        activeSyntaxCharacters = shiftedIndices(activeSyntaxCharacters)
        composingCharacters = shiftedIndices(composingCharacters)
        startingCompositionCharacters = shiftedIndices(startingCompositionCharacters)
    }

    func finishTextEdit() { pendingCharacterEdit = false }

    /// Follows a styler pass over `range`: the edit must finish before selection
    /// sync, which must precede the paragraph variants that depend on it.
    func finishRestyle(in range: NSRange, for view: NSTextView) {
        finishTextEdit()
        synchronize(view)
        applyParagraphs(in: range)
        if range.length > 0 {
            invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        }
    }

    func prepareComposition() {
        startingComposition = true
        startingCompositionCharacters = indices(in: selectionLines)
        for line in selectionLines where line.length > 0 {
            invalidateGlyphs(forCharacterRange: line, changeInLength: 0, actualCharacterRange: nil)
        }
    }

    func synchronize(_ view: NSTextView) {
        startingComposition = false
        updateSelection(view.selectedRanges.map(\.rangeValue), markedRange: view.activeMarkedRange)
    }

    /// Attribute restyles restore raw paragraph styles; reapply just the task and
    /// quote layout variants, without touching text or the undo history.
    func applyParagraphs(in range: NSRange) {
        guard let storage = textStorage, range.length > 0 else { return }
        guard !startingComposition, textContainers.first?.textView?.hasMarkedText() != true else { return }
        var updates: [(NSRange, NSParagraphStyle)] = []
        storage.enumerateAttribute(MarkdownStyler.previewParagraph, in: range) { value, run, _ in
            guard let preview = value as? NSParagraphStyle,
                  let raw = storage.attribute(MarkdownStyler.rawParagraph, at: run.location, effectiveRange: nil) as? NSParagraphStyle else { return }
            let source = storage.string as NSString
            var offset = run.location
            while offset < NSMaxRange(run) {
                let line = source.lineRange(for: NSRange(location: offset, length: 0))
                updates.append((NSIntersectionRange(line, run), isBlockMarkerActive(on: line) ? raw : preview))
                offset = NSMaxRange(line)
            }
        }
        let history = textContainers.first?.textView?.undoManager
        history?.disableUndoRegistration()
        storage.beginEditing()
        for (run, paragraph) in updates { storage.addAttribute(.paragraphStyle, value: paragraph, range: run) }
        storage.endEditing()
        history?.enableUndoRegistration()
    }

    fileprivate func generateGlyphs(_ glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        var displayed = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var flags = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var character: UniChar = OverlayTheme.editorBullet.utf16.first!
        var bullet: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font as CTFont, &character, &bullet, 1)
        let view = textContainers.first?.textView
        let marked = view?.hasMarkedText() == true ? view!.markedRange() : NSRange(location: NSNotFound, length: 0)
        let liveComposing = marked.location == NSNotFound ? nil : (storage.string as NSString).lineRange(for: marked)
        var changed = false
        for offset in 0..<glyphRange.length {
            let index = characterIndexes[offset]
            guard index < storage.length else { continue }
            let composing = composingCharacters.contains(index) || startingCompositionCharacters.contains(index) || (liveComposing.map { NSLocationInRange(index, $0) } ?? false)
            if composing { continue }
            if !activeSyntaxCharacters.contains(index), storage.attribute(MarkdownStyler.syntax, at: index, effectiveRange: nil) as? Bool == true {
                flags[offset].insert(.null); displayed[offset] = 0; changed = true
                // A zero-width control glyph preserves an empty task/quote line's
                // metrics and gives its decoration a real layout anchor at EOF.
                if isDecorationAnchor(at: index) {
                    flags[offset].remove([.null, .elastic]); flags[offset].insert(.controlCharacter)
                }
            } else if storage.attribute(MarkdownStyler.bullet, at: index, effectiveRange: nil) as? Bool == true, bullet != 0 {
                displayed[offset] = bullet; changed = true
            }
        }
        guard changed else { return 0 }
        displayed.withUnsafeBufferPointer { displayed in
            flags.withUnsafeBufferPointer { flags in
                setGlyphs(displayed.baseAddress!, properties: flags.baseAddress!, characterIndexes: characterIndexes,
                          font: font, forGlyphRange: glyphRange)
            }
        }
        return glyphRange.length
    }

    private func isEditing(at index: Int) -> Bool {
        activeSyntaxCharacters.contains(index) || composingCharacters.contains(index) || startingCompositionCharacters.contains(index)
    }

    func isBlockMarkerActive(at location: Int) -> Bool {
        guard let storage = textStorage, location >= 0, location < storage.length,
              let element = storage.attribute(MarkdownStyler.element, at: location, effectiveRange: nil) as? MarkdownStyler.Element,
              element.kind == .blockMarker else { return false }
        return isBlockMarkerActive(element, at: location)
    }

    private func isBlockMarkerActive(_ element: MarkdownStyler.Element, at location: Int) -> Bool {
        activeElements.contains(element) || composingLines.contains { NSIntersectionRange($0, element.range).length > 0 }
            || startingCompositionCharacters.contains(location)
    }

    private func isBlockMarkerActive(on line: NSRange) -> Bool {
        guard let storage = textStorage, line.length > 0 else { return false }
        var active = false
        storage.enumerateAttribute(MarkdownStyler.element, in: line) { value, _, stop in
            guard let element = value as? MarkdownStyler.Element, element.kind == .blockMarker else { return }
            active = isBlockMarkerActive(element, at: element.range.location)
            if active { stop.pointee = true }
        }
        return active
    }

    private func isActive(_ element: MarkdownStyler.Element, for selections: [NSRange]) -> Bool {
        selections.contains { selection in
            guard selection.location != NSNotFound else { return false }
            if selection.length > 0 {
                if element.kind == .headingLine, let storage = textStorage {
                    let line = (storage.string as NSString).lineRange(for: NSRange(location: element.range.location, length: 0))
                    return NSIntersectionRange(selection, line).length > 0
                }
                return NSIntersectionRange(selection, element.range).length > 0
            }
            switch element.kind {
            case .blockMarker:
                return element.range.location < selection.location && selection.location < NSMaxRange(element.range)
            case .headingLine, .inlineSpan:
                return element.range.location <= selection.location && selection.location <= NSMaxRange(element.range)
            }
        }
    }

    private func hasParagraphVariant(for element: MarkdownStyler.Element) -> Bool {
        guard let storage = textStorage, element.range.location < storage.length else { return false }
        return storage.attribute(MarkdownStyler.rawParagraph, at: element.range.location, effectiveRange: nil) is NSParagraphStyle
    }

    private func hasParagraphVariant(in range: NSRange) -> Bool {
        guard let storage = textStorage, range.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(MarkdownStyler.previewParagraph, in: range) { value, _, stop in
            if value is NSParagraphStyle { found = true; stop.pointee = true }
        }
        return found
    }

    private func bounded(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location != NSNotFound, range.location <= length else { return nil }
        let start = max(0, range.location)
        let end = min(length, NSMaxRange(range))
        return NSRange(location: start, length: max(0, end - start))
    }
    fileprivate func isDecorationAnchor(at index: Int) -> Bool {
        guard let storage = textStorage, !isEditing(at: index),
              storage.attribute(MarkdownStyler.syntax, at: index, effectiveRange: nil) as? Bool == true,
              let element = storage.attribute(MarkdownStyler.element, at: index, effectiveRange: nil) as? MarkdownStyler.Element,
              element.kind == .blockMarker,
              MarkdownStyler.taskState(storage.attribute(MarkdownStyler.task, at: index, effectiveRange: nil)) != nil || storage.attribute(MarkdownStyler.quote, at: index, effectiveRange: nil) as? Bool == true else { return false }
        let source = storage.string as NSString
        let line = source.lineRange(for: NSRange(location: index, length: 0))
        var contentEnd = NSMaxRange(line)
        while contentEnd > line.location, source.character(at: contentEnd - 1) == 10 || source.character(at: contentEnd - 1) == 13 { contentEnd -= 1 }
        return element.range.location == index && NSMaxRange(element.range) >= contentEnd
    }
    fileprivate func decorationBounds(at index: Int) -> NSRect {
        let font = (textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? OverlayTheme.editorFont
        return NSRect(x: 0, y: font.descender, width: 0, height: defaultLineHeight(for: font))
    }
    private func indices(in lines: Set<NSRange>) -> IndexSet {
        var result = IndexSet()
        for line in lines where line.length > 0 { result.insert(integersIn: line.location..<NSMaxRange(line)) }
        return result
    }
    private func logicalLines(_ selections: [NSRange], in source: NSString) -> Set<NSRange> {
        var lines = Set<NSRange>()
        for selection in selections where selection.location != NSNotFound {
            let start = min(source.length, max(0, selection.location))
            let length = min(selection.length, source.length - start)
            let end = start + length
            let last = length > 0 ? end - 1 : start
            var offset = source.lineRange(for: NSRange(location: start, length: 0)).location
            let lastLine = source.lineRange(for: NSRange(location: last, length: 0))
            while offset <= lastLine.location {
                let line = source.lineRange(for: NSRange(location: offset, length: 0))
                lines.insert(line)
                if NSMaxRange(line) <= offset { break }
                offset = NSMaxRange(line)
            }
        }
        return lines
    }

    /// Coordinates are in the text container. A toggle changes only the task's
    /// one-character state; normal AppKit editing provides undo and draft writes.
    func checkbox(at point: NSPoint, in container: NSTextContainer) -> NSRange? {
        guard let storage = textStorage, storage.length > 0, numberOfGlyphs > 0 else { return nil }
        let source = storage.string as NSString
        let glyph = glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        let line = source.lineRange(for: NSRange(location: min(characterIndexForGlyph(at: glyph), storage.length - 1), length: 0))
        var result: NSRange?
        storage.enumerateAttribute(MarkdownStyler.task, in: line) { value, marker, stop in
            guard MarkdownStyler.taskState(value) != nil, !isBlockMarkerActive(at: marker.location) else { return }
            guard checkboxRect(for: line, in: container).contains(point) else { return }
            let bracket = source.range(of: "[", options: [], range: marker)
            guard bracket.location != NSNotFound else { return }
            result = NSRange(location: bracket.location + 1, length: 1)
            stop.pointee = true
        }
        return result
    }

    private func visibleGlyphs(for line: NSRange) -> NSRange {
        let range = glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        var start = range.location, end = NSMaxRange(range)
        while start < end, propertyForGlyph(at: start).contains(.null) { start += 1 }
        while end > start, propertyForGlyph(at: end - 1).contains(.null) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private func checkboxRect(for line: NSRange, in container: NSTextContainer) -> NSRect {
        let glyphs = visibleGlyphs(for: line)
        guard glyphs.length > 0 else { return .zero }
        let fragment = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        var indent: CGFloat = 0
        if let storage = textStorage {
            storage.enumerateAttribute(MarkdownStyler.taskIndent, in: line) { value, _, stop in
                guard let value = value as? CGFloat else { return }
                indent = value; stop.pointee = true
            }
        }
        let size = OverlayTheme.editorCheckboxSize
        let baseline = fragment.minY + location(forGlyphAt: glyphs.location).y
        let center = baseline - OverlayTheme.editorFont.capHeight / 2
        return NSRect(x: indent, y: center - size / 2, width: size, height: size)
    }

    nonisolated override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        nonisolated(unsafe) let drawingLayout = self
        MainActor.assumeIsolated { drawingLayout.drawPreviewGlyphs(for: glyphsToShow, at: origin) }
    }
    private func drawPreviewGlyphs(for glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, glyphsToShow.length > 0,
              let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil), let view = container.textView else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let range = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let source = storage.string as NSString
            var offset = source.lineRange(for: NSRange(location: range.location, length: 0)).location
            while offset < NSMaxRange(range) {
                let line = source.lineRange(for: NSRange(location: offset, length: 0))
                defer { offset = NSMaxRange(line) }
                guard !isBlockMarkerActive(on: line) else { continue }
                var taskState: Bool?
                storage.enumerateAttribute(MarkdownStyler.task, in: line) { value, _, stop in
                    guard let checked = MarkdownStyler.taskState(value) else { return }
                    taskState = checked; stop.pointee = true
                }
                if let checked = taskState {
                    drawCheckbox(checkboxRect(for: line, in: container).offsetBy(dx: origin.x, dy: origin.y), checked: checked)
                } else if storage.attribute(MarkdownStyler.quote, at: offset, effectiveRange: nil) as? Bool == true {
                    let glyphs = visibleGlyphs(for: line)
                    guard glyphs.length > 0 else { continue }
                    let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                    let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
                    let inset = OverlayTheme.editorQuoteBarInset, width = OverlayTheme.editorQuoteBarWidth
                    let bar = NSRect(x: origin.x, y: origin.y + first.minY + inset, width: width, height: max(0, last.maxY - first.minY - inset * 2))
                    OverlayTheme.tertiaryColor.setFill()
                    NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
                }
            }
        }
    }
    private func drawCheckbox(_ rect: NSRect, checked: Bool) {
        let stroke = OverlayTheme.editorCheckboxStroke
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: stroke / 2, dy: stroke / 2),
                               xRadius: OverlayTheme.editorCheckboxRadius, yRadius: OverlayTheme.editorCheckboxRadius)
        if checked {
            OverlayTheme.editorCheckboxFill.setFill(); box.fill()
            let check = NSBezierPath()
            for (index, point) in OverlayTheme.editorCheckboxCheckPoints.enumerated() {
                let vertex = NSPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
                if index == 0 { check.move(to: vertex) } else { check.line(to: vertex) }
            }
            check.lineWidth = stroke; check.lineCapStyle = .round; check.lineJoinStyle = .round
            OverlayTheme.editorCheckboxCheckColor.setStroke(); check.stroke()
        } else {
            box.lineWidth = stroke; OverlayTheme.editorCheckboxStrokeColor.setStroke(); box.stroke()
        }
    }
    // AppKit draws this text view on the main thread. Its inherited drawing hook
    // is nonisolated, so explicitly assert that boundary before accessing UI state.
    nonisolated override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        nonisolated(unsafe) let drawingLayout = self
        MainActor.assumeIsolated { drawingLayout.drawMarkdownBackground(for: glyphsToShow, at: origin) }
    }

    private func drawMarkdownBackground(for glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, glyphsToShow.length > 0,
              let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil),
              let view = container.textView else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            var drawn = Set<Int>()
            storage.enumerateAttribute(MarkdownStyler.fencedCodeBlock, in: characters) { value, visibleRange, _ in
                guard value as? Bool == true else { return }
                // Fetch the entire block even if only its middle is being repainted.
                var block = NSRange()
                _ = storage.attribute(MarkdownStyler.fencedCodeBlock, at: visibleRange.location,
                                      longestEffectiveRange: &block,
                                      in: NSRange(location: 0, length: storage.length))
                guard drawn.insert(block.location).inserted else { return }
                let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
                guard glyphs.length > 0 else { return }
                let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
                let rect = NSRect(x: origin.x, y: origin.y + first.minY,
                                  width: container.size.width, height: last.maxY - first.minY)
                OverlayTheme.codeBackground.setFill()
                NSBezierPath(roundedRect: rect, xRadius: OverlayTheme.codeBlockRadius,
                             yRadius: OverlayTheme.codeBlockRadius).fill()
            }
            storage.enumerateAttribute(MarkdownStyler.inlineCode, in: characters) { value, visibleRange, _ in
                guard value as? Bool == true else { return }
                var code = NSRange()
                _ = storage.attribute(MarkdownStyler.inlineCode, at: visibleRange.location, longestEffectiveRange: &code,
                                      in: NSRange(location: 0, length: storage.length))
                let glyphs = visibleGlyphs(for: code)
                guard glyphs.length > 0 else { return }
                enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, fragmentGlyphs, _ in
                    let run = NSIntersectionRange(glyphs, fragmentGlyphs)
                    let bounds = self.boundingRect(forGlyphRange: run, in: container)
                    let rect = bounds.insetBy(dx: -OverlayTheme.inlineCodePadding, dy: 0).offsetBy(dx: origin.x, dy: origin.y)
                    OverlayTheme.codeBackground.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: OverlayTheme.inlineCodeRadius,
                                 yRadius: OverlayTheme.inlineCodeRadius).fill()
                }
            }
            // Selection and marked-text highlights draw over the block decoration.
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        }
    }
}

@MainActor
private final class MarkdownGlyphDelegate: NSObject, @MainActor NSLayoutManagerDelegate {
    weak var owner: MarkdownLayoutManager?
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        owner?.generateGlyphs(glyphs, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange) ?? 0
    }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        owner?.isDecorationAnchor(at: charIndex) == true ? .whitespace : action
    }
    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        owner?.isDecorationAnchor(at: charIndex) == true ? owner!.decorationBounds(at: charIndex) : .zero
    }
}

extension NSTextView {
    /// The marked (IME composition) range, or NSNotFound when nothing is marked.
    var activeMarkedRange: NSRange { hasMarkedText() ? markedRange() : NSRange(location: NSNotFound, length: 0) }
}
