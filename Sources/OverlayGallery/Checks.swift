import AppKit
@_spi(Checks) import OverlayKit

@MainActor
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw GalleryError(message) }
}

@MainActor
private func currentPanel() throws -> OverlayPanel {
    try autoreleasepool {
        let panels = NSApp.windows.compactMap { $0 as? OverlayPanel }.filter { $0.isVisible && $0.canBecomeKey }
        // Sticky note panels may remain visible after losing key status. Synthetic input and
        // assertions must follow the active panel, not NSApp.windows enumeration order.
        let panel = panels.first(where: \.isKeyWindow)
            ?? panels.max(by: { $0.windowNumber < $1.windowNumber })
        guard let panel else {
            throw GalleryError("Interactive panel was not visible")
        }
        return panel
    }
}

@MainActor
private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
    let panel = try currentPanel()
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else {
        throw GalleryError("Could not construct key event")
    }
    if modifiers.contains(.command) { _ = panel.performKeyEquivalent(with: event) }
    else { panel.sendEvent(event) }
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

@MainActor
private func checkCardButtonState(in root: NSView, open: String?, context: String) throws {
    let buttons = descendants(root).filter { String(describing: type(of: $0)) == "ChromeButton" }
    try require(buttons.count == 5, "\(context): chrome buttons missing")
    for button in buttons {
        let on = button.accessibilityLabel() == open
        try require((button.accessibilityValue() as? NSNumber)?.boolValue == on && button.isAccessibilitySelected() == on,
                    "\(context): only the open card's button must expose an on/selected accessibility state")
        let alpha = button.layer?.backgroundColor?.alpha ?? 0
        try require(on ? abs(alpha - OverlayTheme.quickButtonPressedFill.alphaComponent) < 0.001
                       : alpha <= OverlayTheme.quickButtonHoverFill.alphaComponent + 0.001,
                    "\(context): the open card's button must keep the circular pressed fill")
        if on {
            var expected: CGColor?
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                expected = NSColor.labelColor.withAlphaComponent(OverlayTheme.quickButtonPressedFill.alphaComponent).cgColor
            }
            try require(button.layer?.backgroundColor == expected, "\(context): pressed fill must resolve for the button's appearance")
        }
    }
}

@MainActor
private func field(in panel: OverlayPanel) throws -> NSTextField {
    guard let content = panel.contentView,
          let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: \.isEditable) else {
        throw GalleryError("Input field was not found")
    }
    return field
}

@MainActor
private func settle() async throws { try await Task.sleep(for: .milliseconds(230)) }

@MainActor
private func settle(until condition: () -> Bool) async throws {
    for _ in 0..<20 where !condition() { try await Task.sleep(for: .milliseconds(100)) }
}

@MainActor
func runBehaviorChecks() async throws {
    try checkMarkdownStyler()
    let frontmostApplication = NSWorkspace.shared.frontmostApplication
    let frontmost = frontmostApplication?.processIdentifier
    let canCheckFocus = frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
    let interactive = OverlayPanel(interactive: true, size: .zero)
    let passive = OverlayPanel(interactive: false, size: .zero)
    try require(interactive.styleMask.contains(.nonactivatingPanel), "Missing permanent nonactivating style")
    try require(interactive.canBecomeKey && !interactive.canBecomeMain, "Interactive key/main policy")
    try require(!passive.canBecomeKey && passive.ignoresMouseEvents && !passive.canBecomeMain, "Toast key/mouse policy")
    try require(interactive.level == .modalPanel && passive.level == .floating, "Window levels")
    try require(!interactive.hidesOnDeactivate && !interactive.isReleasedWhenClosed && !interactive.isMovable, "Window lifecycle policy")
    try require(interactive.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle], "Space policy")
    let options = [Suggestion(title: "System Design"), Suggestion(title: "Rate limiting")]
    let input = InputPanelController()
    var submitted: [String] = []
    var canceled = 0
    func presentInput(_ initial: String = "  Custom heading  ") {
        input.present(placeholder: "Name this session", initialText: initial, suggestions: { _ in options },
                      onSubmit: { submitted.append($0) }, onCancel: { canceled += 1 })
    }
    presentInput()
    try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Input activated another application")
    if canCheckFocus {
        try require(try currentPanel().isKeyWindow, "Panel did not borrow keyboard focus")
    } else {
        print("Live keyboard-focus check skipped: macOS session is locked.")
    }
    weak let closedPanel = try currentPanel()
    weak let closedView = closedPanel?.contentView
    try key(36)
    try await settle()
    try require(submitted == ["Custom heading"] && canceled == 0, "Initial no-selection Enter or trimming failed")
    try require(closedView == nil && closedPanel == nil, "Closed input retained its panel/view hierarchy")
    presentInput()
    try key(125); try key(125); try key(36)
    try await settle()
    try require(submitted.last == "Rate limiting", "Arrow selection did not submit selected title")
    presentInput("")
    try key(48)
    try require(try field(in: currentPanel()).stringValue == "System Design", "Tab did not fill first suggestion")
    try key(53)
    try await settle()
    try require(canceled == 1, "Escape cancellation count")
    presentInput("   ")
    try key(36)
    try await settle()
    try require(canceled == 2, "Empty Enter did not cancel")
    presentInput()
    input.dismiss()
    try await settle()
    try require(canceled == 3, "Programmatic dismissal did not cancel exactly once")
    presentInput()
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try await settle()
    try require(canceled == 4 && !input.isVisible, "Screen change did not cancel")
    presentInput()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try await settle()
    try require(canceled == 5 && !input.isVisible, "Space change did not cancel")
    presentInput()
    let losingKey = try currentPanel()
    losingKey.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: losingKey))
    try await settle()
    try require(canceled == 6, "Lost key did not cancel")

    var acceptedBeforeClose = false
    var submittedAfterClose = false
    input.present(placeholder: "Add to note…", initialText: "Chosen title", suggestions: { _ in [] }, onAccept: { text in
        acceptedBeforeClose = text == "Chosen title" && input.isVisible
    }, onSubmit: { _ in submittedAfterClose = !input.isVisible }, onCancel: {})
    let acceptingPanel = try currentPanel()
    try key(36)
    try require(acceptedBeforeClose && submittedAfterClose, "Note title acceptance must precede dismissal and final callbacks")
    try require(!acceptingPanel.isVisible && !acceptingPanel.isKeyWindow, "Input retained key status during closing")

    let toast = ToastController()
    var expired = 0
    toast.onExpire = { expired += 1 }
    try require(Toast(style: .warning, title: "Warning").duration == 3, "Warning duration")
    try require(Toast(style: .success, title: "Saved").duration == 2, "Default duration")
    toast.show(Toast(style: .success, title: "Saved", duration: 0.03))
    toast.show(Toast(style: .copied, title: "Copied", duration: 0.03))
    try await settle()
    try require(expired == 1 && !toast.isVisible, "Toast replacement/expiry semantics")
    toast.show(Toast(style: .session, title: "Session"))
    toast.dismiss(expire: false)
    toast.show(Toast(style: .success, title: "Saved"))
    toast.dismiss(expire: true)
    try await settle()
    try require(expired == 2 && !toast.isVisible, "Toast dismissal during fade retained old toast or expired twice")

    let search = SearchPanelController()
    var performed: [String] = []
    var closed = 0
    let actions = SearchActions(primary: { performed.append("primary:\($0.id)") },
                                open: { performed.append("open:\($0.id)") },
                                reveal: { performed.append("reveal:\($0.id)") }, onClose: { closed += 1 })
    func presentSearch() {
        search.present(query: { _ in [SearchSection(title: "Recent", rows: [
            SearchRow(id: "first", title: "System Design"), SearchRow(id: "second", title: "Rate limiting")
        ])] }, actions: actions)
    }
    presentSearch()
    try await settle()
    try key(36)
    try await settle()
    try require(performed == ["primary:first"] && closed == 1, "Default search selection/primary")
    presentSearch(); try await settle()
    try key(125); try key(36, modifiers: .command)
    try await settle()
    try require(performed.last == "open:second", "Command Enter action")
    presentSearch(); try await settle()
    try key(36, modifiers: .option)
    try await settle()
    try require(performed.last == "reveal:first", "Option Enter action")
    var requested: [String] = []
    search.present(query: { text in
        requested.append(text)
        if text.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        return [SearchSection(title: "Results", rows: [SearchRow(id: text, title: text.isEmpty ? "Stale" : text)])]
    }, actions: actions)
    try await Task.sleep(for: .milliseconds(20))
    let panel = try currentPanel()
    let textField = try field(in: panel)
    textField.stringValue = "fresh"
    search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
    textField.stringValue = "newest"
    search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
    try await settle()
    try key(36)
    try await settle()
    try require(requested == ["", "newest"] && performed.last == "primary:newest", "Debounce/stale query rejection")
    search.present(query: { _ in try? await Task.sleep(for: .milliseconds(300)); return [] }, actions: actions)
    try await Task.sleep(for: .milliseconds(175))
    let loadingPanel = try currentPanel()
    let spinner = loadingPanel.contentView.map(descendants)?.compactMap({ $0 as? NSProgressIndicator }).first
    try require(spinner?.isDisplayedWhenStopped == false && spinner?.isHidden == false, "Delayed loading spinner")
    weak let searchView = loadingPanel.contentView
    search.dismiss()
    try require(!loadingPanel.isVisible && !loadingPanel.isKeyWindow, "Search retained key status during closing")
    try await settle()
    try require(searchView == nil && !search.isVisible, "Search close retained views")

    search.present(query: { _ in [SearchSection(title: "Results", rows: [], errorMessage: "Search failed. Try again.")] }, actions: actions)
    try await settle()
    let failurePanel = try currentPanel()
    let labels = failurePanel.contentView.map(descendants)?.compactMap { $0 as? NSTextField } ?? []
    try require(labels.contains { $0.stringValue == "Search failed. Try again." && !$0.isHidden }, "Search errors must use the no-results message area")
    search.dismiss()

    // Clear the mutable query model in onClose. The Enter action must already own
    // its selected value, rather than looking it up in the cleared model afterward.
    var model = "original full body"
    var frozen = ""
    var canceledQuery = false
    search.present(query: { text in
        if !text.isEmpty {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { canceledQuery = true }
        }
        return [SearchSection(title: "Recent", rows: [SearchRow(id: "same-id", title: "Original")])]
    }, actions: SearchActions(primary: { _ in }, open: { _ in }, reveal: { _ in }, onClose: { model = "changed after close" }, freeze: { _, _ in
        let selected = model
        return { frozen = selected }
    }))
    try await settle()
    let freezingPanel = try currentPanel()
    let freezingField = try field(in: freezingPanel)
    freezingField.stringValue = "pending"
    search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: freezingField))
    try await Task.sleep(for: .milliseconds(175))
    try key(36)
    try require(frozen == "original full body" && !freezingPanel.isVisible, "Search action was not frozen before dismissal")
    try await settle()
    try require(canceledQuery, "Dismissal did not cancel an outstanding query")
    try await checkNoteLineHeights()
    try await checkCoalescedLongNoteLayout()
    try await checkStickyNotes()
    try await checkNoteEditorBehavior()
    try await checkNoteOverlays()
    try await checkSaveAsNewShortcut()
    try checkCardButtonClicks()
    try checkQuickNoteDesign()
    try await checkFloatingCards()
    try await checkPanelMoving()
    try await checkCaretStates()
    try await checkLivePreviewInteraction()
    try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Panels changed frontmost application")
    print("Behavior checks passed: focus policy, immediate focus release, heading acceptance, screen/space dismissal, view release, toast expiry, frozen search actions, query cancellation/errors/loading.")
}

@MainActor
private func checkNoteEditorBehavior() async throws {
    let editor = NoteEditorPanel()
    var draft = ""
    var submitted: [String] = []
    var closed = 0
    var storageFailure = false
    var errors = 0
    func present(_ text: String = "") {
        editor.present(destination: "System Design", isPinned: false, draft: text, handlers: NoteEditorHandlers(
            onDraft: {
                if storageFailure { throw GalleryError("Injected draft failure") }
                draft = $0
            }, onSubmit: { submitted.append($0) }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
            onBrowse: { _, _ in }, onTogglePin: { false }, onClose: { closed += 1 }, onError: { _ in errors += 1 }))
    }
    func textView() throws -> NSTextView {
        guard let root = try currentPanel().contentView, let text = descendants(root).compactMap({ $0 as? NSTextView }).first else {
            throw GalleryError("Note text view missing")
        }
        return text
    }
    present()
    let emptyPanel = try currentPanel()
    let emptyText = try textView()
    try require(emptyPanel.frame.width == OverlayTheme.quickMinWidth, "Editor width")
    try require(emptyText.accessibilityLabel() == "Note text", "Editor text accessibility label")
    try require(!emptyText.isRichText && emptyText.allowsUndo, "Plain text/undo configuration")
    let emptyLabels = emptyPanel.contentView.map(descendants)?.compactMap { $0 as? NSTextField } ?? []
    try require(emptyLabels.contains { $0.stringValue == "Start writing…" && !$0.isHidden }, "Empty placeholder")
    try require(emptyLabels.contains { $0.stringValue == "Draft kept" && $0.isHidden }, "Empty editor must hide draft hint")
    try require(emptyLabels.contains { $0.stringValue == "⌘↩" } && emptyLabels.contains { $0.stringValue == "Add to note" }
                && emptyLabels.contains { $0.stringValue == "Actions" } && emptyLabels.contains { $0.stringValue == "Close" }
                && !emptyLabels.contains { $0.stringValue == "New line" } && !emptyLabels.contains { $0.stringValue == "Write a note" },
                "Editor footer must show Command Return save caption, Actions and Close hints")
    try require(emptyLabels.contains { $0.stringValue == "System Design" && $0.font == OverlayTheme.quickTitleFont },
                "The destination title must be shown in the top band, not in the footer caption")
    let longTitle = OverlayPreview.noteEditor(destination: "A very long destination title that overflows")
    try require(descendants(longTitle).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Add to note" },
                "Save caption must not repeat the destination title")
    try require(descendants(OverlayPreview.noteEditor()).compactMap { $0 as? NSTextField }
                    .contains { $0.stringValue == "Create note" }, "Save caption without a destination")
    let top = emptyPanel.frame.maxY, minimum = emptyPanel.frame.height
    emptyText.insertText("one\ntwo\nthree\nfour\nfive", replacementRange: emptyText.selectedRange())
    try await settle()
    try require(abs(emptyPanel.frame.maxY - top) < 0.5 && emptyPanel.frame.height > minimum, "Editor must grow downward")
    emptyText.setSelectedRange(NSRange(location: 0, length: 3))
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("sentinel", forType: .string)
    try key(8, modifiers: [.command, .shift])
    try require(NSPasteboard.general.string(forType: .string) == "one\ntwo\nthree\nfour\nfive", "Shift Command C must copy the whole Markdown, not the selection")
    try key(53)
    try require(draft == "one\ntwo\nthree\nfour\nfive" && !editor.isVisible && closed == 1, "Escape must keep draft and close")
    present(draft)
    let restored = try textView()
    try require(restored.selectedRange().location == (draft as NSString).length, "Restored caret must be at end")
    let draftLabels = try currentPanel().contentView.map(descendants)?.compactMap { $0 as? NSTextField } ?? []
    try require(draftLabels.contains { $0.stringValue == "Draft kept" && !$0.isHidden }, "Restored draft hint")
    editor.dismiss()

    for (initial, expected) in [("- a", "- a\n- "), ("- item", "- item\n- "), ("* item", "* item\n* "),
                                ("1. item", "1. item\n2. "), ("  - [x] item", "  - [x] item\n  - [ ] "),
                                ("- [ ] item", "- [ ] item\n- [ ] "), ("- ", ""),
                                ("  3. ", ""), ("- [x] ", "")] {
        present(initial)
        try key(36)
        try require(try textView().string == expected && submitted.isEmpty, "Return list/newline behavior: \(initial)")
        editor.dismiss()
    }
    present("plain")
    let plainBreak = try textView()
    try key(36)
    try require(plainBreak.string == "plain\n", "Return on a non-list line must insert a plain newline")
    editor.dismiss()
    present("- a")
    let softBreak = try textView()
    try key(36, modifiers: .shift)
    try require(softBreak.string == "- a\n", "Shift Return must insert a plain newline without continuing a list")
    editor.dismiss()
    present("```\n- a")
    let fencedBreak = try textView()
    try key(36)
    try require(fencedBreak.string == "```\n- a\n", "Return inside fenced code must insert a plain newline")
    editor.dismiss()
    present("- item")
    let list = try textView()
    try key(48)
    try require(list.string == "  - item" && list.selectedRange().location == 8, "Tab list indentation")
    try key(48, modifiers: .shift)
    try require(list.string == "- item", "Shift Tab list outdent")
    editor.dismiss()
    present("one")
    let history = try textView()
    history.insertText(" two", replacementRange: history.selectedRange())
    try await settle()
    try key(6, modifiers: .command)
    try require(history.string == "one", "Editor undo must undo text, not preview attributes")
    try key(6, modifiers: [.command, .shift])
    try require(history.string == "one two", "Editor redo")
    try key(36, modifiers: .command)
    try require(submitted == ["one two"] && !editor.isVisible, "Command Return must save and release focus")
    try await settle()
    present("keypad save")
    try key(76, modifiers: .command)
    try require(submitted == ["one two", "keypad save"] && !editor.isVisible, "Command keypad Enter must save")
    try await settle()

    present()
    let autocorrect = try textView()
    autocorrect.insertText("- []", replacementRange: autocorrect.selectedRange())
    try await settle()
    autocorrect.insertText(" ", replacementRange: autocorrect.selectedRange())
    try require(autocorrect.string == "- [ ] ", "Typing space after an empty task marker must insert the checkbox spacing")
    try key(6, modifiers: .command)
    try require(autocorrect.string == "- []", "Task spacing autocorrection must be one undoable edit; got \(autocorrect.string.debugDescription)")
    editor.dismiss()

    present("```\n- []")
    let fencedTask = try textView()
    fencedTask.insertText(" ", replacementRange: fencedTask.selectedRange())
    try require(fencedTask.string == "```\n- [] ", "Task autocorrection must stay disabled inside fenced code")
    editor.dismiss()

    present("  - [ ] ")
    let taskBackspace = try textView()
    taskBackspace.deleteBackward(nil)
    try require(taskBackspace.string == "  - ", "Backspace at a rendered task marker must preserve indentation and leave a plain bullet marker")
    try key(6, modifiers: .command)
    try require(taskBackspace.string == "  - [ ] ", "Task marker Backspace must be one undoable edit")
    editor.dismiss()

    present()
    let ime = try textView()
    ime.setMarkedText("**marked**", selectedRange: NSRange(location: 10, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    try require(ime.hasMarkedText(), "IME fixture must have marked text")
    try require((ime.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont) != OverlayTheme.editorStrongFont, "Marked text must skip restyling")
    let submissionsBeforeIME = submitted.count
    try key(36)
    try require(editor.isVisible && submitted.count == submissionsBeforeIME, "IME Return must not save")
    ime.unmarkText()
    try require((ime.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont) == OverlayTheme.editorStrongFont, "Committed IME text must restyle")
    ime.setMarkedText(NSAttributedString(string: "**marked**", attributes: MarkdownStyler.baseAttributes),
                      selectedRange: NSRange(location: 10, length: 0), replacementRange: NSRange(location: 0, length: 10))
    try require(ime.hasMarkedText(), "Appearance IME fixture must have marked text")
    let imePanel = try currentPanel()
    imePanel.appearance = NSAppearance(named: .darkAqua)
    imePanel.contentView?.viewDidChangeEffectiveAppearance()
    try require(!ime.hasMarkedText() || (ime.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont) != OverlayTheme.editorStrongFont,
                "Appearance callback must defer styling while text is marked")
    try await settle()
    // AppKit can end a synthetic marked range during an appearance change.
    try require(ime.string == "**marked**" && editor.isVisible, "Appearance change must preserve IME text")
    ime.unmarkText()
    try require((ime.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont) == OverlayTheme.editorStrongFont,
                "Appearance styling must resume after unmarkText")
    editor.dismiss()

    present("`inline`\n```\ncode\n```")
    let appearancePanel = try currentPanel()
    let appearanceText = try textView()
    appearancePanel.appearance = NSAppearance(named: .aqua)
    try await settle()
    let selection = appearanceText.selectedRange()
    appearanceText.textStorage?.addAttribute(.font, value: OverlayTheme.editorFont, range: NSRange(location: 1, length: 6))
    appearancePanel.appearance = NSAppearance(named: .darkAqua)
    try await settle()
    try require((appearanceText.textStorage?.attribute(.font, at: 1, effectiveRange: nil) as? NSFont) == OverlayTheme.editorCodeFont,
                "Open editor must restyle on effective appearance change")
    try require(appearanceText.string == "`inline`\n```\ncode\n```" && appearanceText.selectedRange() == selection,
                "Appearance restyle must preserve Markdown and caret")
    editor.dismiss()

    present("short")
    let widePanel = try currentPanel(), wideText = try textView()
    let narrow = widePanel.frame.width
    wideText.insertText(" " + String(repeating: "wide ", count: 12), replacementRange: wideText.selectedRange())
    try await settle(until: { widePanel.frame.width > narrow && widePanel.frame.width == widePanel.frame.width.rounded() })
    try await settle()
    try require(widePanel.frame.width > narrow && widePanel.frame.width <= OverlayTheme.quickMaxWidth, "Width must grow with a long line, up to the cap")
    let grown = widePanel.frame.width
    wideText.selectAll(nil)
    wideText.insertText("a", replacementRange: wideText.selectedRange())
    try await settle()
    try require(widePanel.frame.width == grown, "Width must not shrink after deleting the long line")
    wideText.insertText(String(repeating: "x", count: 400), replacementRange: wideText.selectedRange())
    try await settle(until: { widePanel.frame.width == OverlayTheme.quickMaxWidth })
    try require(widePanel.frame.width == OverlayTheme.quickMaxWidth, "Width must cap at the maximum, got \(widePanel.frame.width)")
    editor.dismiss()

    // The editor never shrinks below its minimum lines, so on a short screen (CI VMs)
    // that floor can exceed the screen-fraction cap. Measure it rather than assume it.
    present("x")
    try await settle()
    let floorHeight = try currentPanel().frame.height
    editor.dismiss()

    present(String(repeating: "line\n", count: 30))
    let tallPanel = try currentPanel()
    let tallScroll = tallPanel.contentView.map(descendants)?.compactMap { $0 as? NSScrollView }.first
    try require(tallScroll?.hasVerticalScroller == true, "Long note must scroll at maximum height")
    let fractionCap = min((tallPanel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900, 10_000) * OverlayTheme.quickMaxHeightFraction
    // AppKit rounds window frames to whole points, so allow up to one point over the cap.
    try require(tallPanel.frame.height <= max(fractionCap, floorHeight) + 1
                && tallPanel.frame.height <= OverlayTheme.quickMaxHeight,
                "Editor height must respect the cap (height \(tallPanel.frame.height), screen cap \(fractionCap), floor \(floorHeight))")
    let shrinking = try textView()
    shrinking.selectAll(nil)
    shrinking.insertText("short", replacementRange: shrinking.selectedRange())
    try await settle()
    try require(tallScroll?.hasVerticalScroller == false && tallPanel.frame.height == minimum, "Editor must shrink and remove scroller after deletion")
    tallPanel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: tallPanel))
    try require(editor.isVisible && shrinking.string == "short", "Sticky key loss must retain the note text")
    editor.dismiss()
    try require(!editor.isVisible && draft == "short", "Explicit close must preserve the draft")
    present("keep me")
    storageFailure = true
    try key(53)
    try require(editor.isVisible && errors == 1, "Draft failure must retain editor")
    storageFailure = false
    editor.dismiss()
    try require(!editor.isVisible && draft == "keep me", "Draft failure retry")
    print("Note editor checks passed (focus, placeholder/draft, growth, lists, indent, undo/redo, IME, scroll, dismissal failure).")
}

@MainActor
private func checkNoteOverlays() async throws {
    let editor = NoteEditorPanel()
    let items = [BrowseItem(id: "a", title: "Trip planning", detail: "Note · Oct 12", symbolName: "doc.text", isPinned: false),
                 BrowseItem(id: "b", title: "System Design", detail: "Session · Oct 9", symbolName: "record.circle", isPinned: false)]
    var browsed: [(String, BrowseChoice)] = []
    var opened: [String] = []
    var pins = 0
    func present(_ text: String) {
        editor.present(destination: nil, isPinned: false, draft: text, handlers: NoteEditorHandlers(
            onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { opened.append($0) },
            browseItems: { items }, onBrowse: { browsed.append(($0.id, $1)) }, onTogglePin: { pins += 1; return true }, onClose: {}, onError: { _ in }))
    }
    func named(_ name: String) throws -> NSView? {
        guard let root = try currentPanel().contentView else { return nil }
        return descendants(root).first { String(describing: type(of: $0)) == name }
    }
    func assertCardInside(_ message: String) throws {
        let panel = try currentPanel()
        guard let card = try named("NoteActionMenuView"), let content = panel.contentView else { throw GalleryError("\(message): card missing") }
        try require(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(content.convert(card.bounds, from: card)), "\(message): card must lie inside the panel")
    }
    func chromeButtonsClearOfCard() throws -> Bool {
        guard let content = try currentPanel().contentView, let card = try named("NoteActionMenuView") ?? named("NoteBrowseView") else { return false }
        let cardFrame = content.convert(card.bounds, from: card)
        return descendants(content).filter { String(describing: type(of: $0)) == "ChromeButton" }
            .allSatisfy { !content.convert($0.bounds, from: $0).intersects(cardFrame) }
    }
    func textView() throws -> NSTextView {
        guard let root = try currentPanel().contentView, let text = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { $0.isRichText == false && $0.accessibilityLabel() == "Note text" }) else {
            throw GalleryError("Note text view missing")
        }
        return text
    }

    present("one\ntwo")
    let panel = try currentPanel()
    let text = try textView()
    let restSize = panel.frame.size
    try checkCardButtonState(in: panel.contentView!, open: nil, context: "Closed cards")
    try key(40, modifiers: .command)
    try checkCardButtonState(in: panel.contentView!, open: "Actions", context: "Keyboard opens Actions")
    try require(try named("NoteActionMenuView") != nil, "Command K must open the action card")
    try require(try chromeButtonsClearOfCard(), "Card must clear the chrome immediately after opening")
    try assertCardInside("Card open")
    let menuField = try field(in: panel)
    try require(panel.firstResponder === menuField.currentEditor(), "Card filter must take focus")
    try key(40, modifiers: .command)
    try await settle()
    try require(try named("NoteActionMenuView") == nil && panel.firstResponder === text, "Command K must close the card and restore the text focus")
    try require(panel.frame.size == restSize, "Panel must return to its content size when the card closes")
    try checkCardButtonState(in: panel.contentView!, open: nil, context: "Keyboard closes Actions")
    try key(40, modifiers: .command)
    try await settle()
    try require(try chromeButtonsClearOfCard(), "Card must not cover the chrome buttons")
    try key(53)
    try await settle()
    try require(editor.isVisible && (try named("NoteActionMenuView")) == nil, "Escape with the card open must close only the card")
    try checkCardButtonState(in: panel.contentView!, open: nil, context: "Escape closes Actions")
    // A click into the text leaves a stale card: Return must edit the text, not run the card's row.
    try key(40, modifiers: .command)
    try await settle()
    try require(panel.makeFirstResponder(text), "Text view must accept focus")
    try key(36)
    try await settle()
    try require(editor.isVisible && text.string == "one\ntwo\n", "Return after focusing the text must insert a newline")
    try key(53)
    try await settle()
    try require(editor.isVisible && (try named("NoteActionMenuView")) == nil, "Escape with a stale card must close only the card")
    text.insertText("", replacementRange: NSRange(location: text.string.count - 1, length: 1))
    try await settle()
    try key(40, modifiers: .command)
    try key(35, modifiers: .command)
    try await settle()
    try require(try named("NoteBrowseView") != nil, "Command P in Actions must open Browse")
    try checkCardButtonState(in: panel.contentView!, open: "Browse notes", context: "Actions swaps to Browse")
    // Browse is a card now: the editor stays, the card hangs top-right under the band, the Browse hints live inside the card.
    guard let content = panel.contentView, let browseCard = try named("NoteBrowseView") else { throw GalleryError("Browse card missing") }
    content.layoutSubtreeIfNeeded()
    let browseFrame = content.convert(browseCard.bounds, from: browseCard)
    try require(abs(browseFrame.width - OverlayTheme.browseCardWidth) < 0.5, "Browse card width")
    try require(abs(browseFrame.maxX - (content.bounds.width - OverlayTheme.cardEdgeMargin)) < 0.5
                && abs(browseFrame.minY - (OverlayTheme.quickTopBandHeight + OverlayTheme.cardTopGap)) < 0.5, "Browse card must anchor top-right under the band")
    try require(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(browseFrame)
                && panel.frame.height >= browseFrame.maxY + OverlayTheme.cardEdgeMargin - 0.5, "Window must fit the Browse overflow")
    try require(descendants(content).filter { String(describing: type(of: $0)) == "BrowseRowView" }.count == items.count, "Browse rows")
    let scrolls = descendants(content).compactMap { $0 as? NSScrollView }
    try require(scrolls.contains { !$0.isHidden && $0.documentView is NSTextView }, "The note must stay visible behind the Browse card")
    let cardHints = descendants(browseCard).filter { String(describing: type(of: $0)) == "KeycapView" }
    let cardCaptions = cardHints.flatMap { descendants($0).compactMap { $0 as? NSTextField }.map(\.stringValue) }
    let noteHints = descendants(content).filter { view in
        String(describing: type(of: view)) == "KeycapView" && !cardHints.contains(where: { $0 === view }) && !view.isHidden
    }
    let noteCaptions = noteHints.flatMap { descendants($0).compactMap { $0 as? NSTextField }.map(\.stringValue) }
    try require(cardCaptions.contains("Write here") && cardCaptions.contains("Open") && cardCaptions.contains("Reveal") && !cardCaptions.contains("Back"),
                "Browse hints must live in the card without an esc Back hint")
    try require(noteCaptions.contains("Actions") && noteCaptions.contains("Close") && !noteCaptions.contains("Write here"),
                "The note footer must keep its normal hints while Browse is open")
    try require(try chromeButtonsClearOfCard(), "Browse card must not cover the chrome buttons")
    try key(53)
    try await settle(until: { panel.frame.size == restSize })
    try require(editor.isVisible && (try named("NoteBrowseView")) == nil && panel.frame.size == restSize && panel.firstResponder === text,
                "Escape in Browse must return to the editor at its previous size")
    try checkCardButtonState(in: content, open: nil, context: "Escape closes Browse")
    // Command P toggles Browse; Command K swaps to Actions; a click outside the card closes it.
    try key(35, modifiers: .command)
    try await settle()
    try require(try named("NoteBrowseView") != nil, "Command P must open Browse")
    try checkCardButtonState(in: content, open: "Browse notes", context: "Keyboard opens Browse")
    try key(35, modifiers: .command)
    try await settle(until: { panel.frame.size == restSize })
    try require(try named("NoteBrowseView") == nil && panel.frame.size == restSize && panel.firstResponder === text, "Command P in Browse must close it")
    try checkCardButtonState(in: content, open: nil, context: "Keyboard closes Browse")
    try key(35, modifiers: .command)
    try await settle()
    try key(40, modifiers: .command)
    try await settle()
    try require(try named("NoteActionMenuView") != nil && (try named("NoteBrowseView")) == nil, "Command K in Browse must swap to the Actions card")
    try checkCardButtonState(in: content, open: "Actions", context: "Browse swaps to Actions")
    try key(35, modifiers: .command)
    try await settle()
    try require(try named("NoteBrowseView") != nil && (try named("NoteActionMenuView")) == nil, "Command P in Actions must swap to Browse")
    if let content = panel.contentView,
       let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: OverlayTheme.quickFooterHeight + 8), modifierFlags: [], timestamp: 0,
                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
        content.mouseDown(with: click)
    } else { throw GalleryError("Could not construct a click") }
    try await settle(until: { panel.frame.size == restSize })
    try require(try named("NoteBrowseView") == nil && panel.frame.size == restSize, "A click outside the card must close it")
    try checkCardButtonState(in: content, open: nil, context: "Click-away closes Browse")
    try key(35, modifiers: .command)
    try await settle()
    try key(36)
    try await settle()
    try require(browsed.last?.0 == "a" && browsed.last?.1 == .write && editor.isVisible && (try named("NoteBrowseView")) == nil,
                "Return in Browse must write here and return to the editor")
    try checkCardButtonState(in: content, open: nil, context: "Browse Write here closes card")
    try key(35, modifiers: .command)
    try await settle()
    try key(36, modifiers: .command)
    try require(browsed.last?.1 == .open && !editor.isVisible, "Command Return in Browse must open and dismiss the panel")
    try checkCardButtonState(in: content, open: nil, context: "Browse Open dismisses panel")
    try await settle()

    present("")
    try key(40, modifiers: .command)
    try assertCardInside("Empty note card (immediately after opening)")
    try require(try chromeButtonsClearOfCard(), "Card must clear the chrome immediately after opening")
    for _ in 0..<8 { try key(125) }
    try key(36)
    try require(opened == [""] && !editor.isVisible, "Arrow keys must skip disabled rows (last enabled row is Open as Note)")
    try await settle()
    // Card regrow: shrinking by filtering then clearing must not leave the card over the chrome.
    present("one\ntwo")
    try key(40, modifiers: .command)
    let regrowPanel = try currentPanel()
    guard let filterEditor = try field(in: regrowPanel).currentEditor() as? NSTextView else { throw GalleryError("Card filter editor missing") }
    filterEditor.insertText("zzz", replacementRange: filterEditor.selectedRange())
    try await settle()
    filterEditor.insertText("", replacementRange: NSRange(location: 0, length: 3))
    try assertCardInside("Card regrow")
    try require(try chromeButtonsClearOfCard(), "Card must clear the chrome immediately after the filter is cleared")
    // Card shortcuts work while the filter has focus.
    try key(35, modifiers: .command)
    try await settle()
    try require(try named("NoteBrowseView") != nil && (try named("NoteActionMenuView")) == nil, "Command P in the card must open Browse")
    try key(53)
    try await settle()
    try key(40, modifiers: .command)
    try key(35, modifiers: [.command, .shift])
    try require(pins == 1 && (try named("NoteActionMenuView")) == nil && editor.isVisible, "Shift Command P in the card must pin and close the card")
    try checkCardButtonState(in: regrowPanel.contentView!, open: nil, context: "Running Actions closes card")
    editor.dismiss()
    try await settle()
    // Browse builds at most browseMaxRows rows, pinned first.
    let many = (0..<500).map { BrowseItem(id: "n\($0)", title: "Note \($0)", detail: "Note", symbolName: "doc.text", isPinned: $0 == 250) }
    let browse = OverlayPreview.noteEditor(overlay: .browse(items: many))
    let rowViews = descendants(browse).filter { String(describing: type(of: $0)) == "BrowseRowView" }
    try require(rowViews.count == OverlayTheme.browseMaxRows, "Browse must cap its rows (\(rowViews.count))")
    try require((rowViews.first?.accessibilityLabel() ?? "").contains("Note 250") || rowViews.first.map({ descendants($0).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Note 250" } }) == true,
                "The pinned item must be listed first")
    try await checkFooterFit()
    print("Note overlay checks passed (card toggle/escape/focus/bounds, row navigation, Browse write/open/back, size restore).")
}

/// Exercise mouse press/release and hover on the production buttons, including dismissal with a card open.
@MainActor
private func checkCardButtonClicks() throws {
    let editor = NoteEditorPanel()
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        for label in ["Actions", "Browse notes"] {
            editor.present(destination: nil, isPinned: false, draft: "one\ntwo", handlers: NoteEditorHandlers(
                onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
                onBrowse: { _, _ in }, onTogglePin: { true }, onClose: {}, onError: { _ in }))
            let panel = try currentPanel()
            guard let root = panel.contentView, let button = descendants(root).first(where: {
                String(describing: type(of: $0)) == "ChromeButton" && $0.accessibilityLabel() == label
            }) else { throw GalleryError("Card button missing") }
            root.appearance = NSAppearance(named: appearance)
            root.layoutSubtreeIfNeeded()
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                // Overflow changes the window's origin; each click needs the button's current window coordinates.
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    throw GalleryError("Could not construct card button click")
                }
                return event
            }
            func click() throws {
                button.mouseDown(with: try event(.leftMouseDown))
                button.mouseUp(with: try event(.leftMouseUp))
            }
            try click()
            try checkCardButtonState(in: root, open: label, context: "Mouse opens \(label)")
            button.mouseEntered(with: try event(.mouseMoved))
            try checkCardButtonState(in: root, open: label, context: "Hover keeps \(label) pressed")
            button.mouseExited(with: try event(.mouseMoved))
            try checkCardButtonState(in: root, open: label, context: "Exit keeps \(label) pressed")
            try click()
            try checkCardButtonState(in: root, open: nil, context: "Mouse closes \(label)")
            try click()
            editor.dismiss()
            try require(!editor.isVisible, "Card button dismissal must close the panel")
            try checkCardButtonState(in: root, open: nil, context: "Dismissal clears \(label)")
        }
    }
    print("Card button checks passed (click/key toggles, swaps, hover, escape/click-away/resign/action/dismissal, accessibility, dark/light pressed fill).")
}

@MainActor
private func checkFooterFit() async throws {
    let editor = NoteEditorPanel()
    for title in ["System Design", "Demo Session", "MLE Interview Prep and Other Long Titles"] {
        for draft in ["", "restored"] {
            editor.present(destination: title, isPinned: false, draft: draft, handlers: NoteEditorHandlers(
                onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
                onBrowse: { _, _ in }, onTogglePin: { false }, onClose: {}, onError: { _ in }))
            let panel = try currentPanel()
            guard let content = panel.contentView else { throw GalleryError("Footer check: no content view") }
            content.layoutSubtreeIfNeeded()
            let all = descendants(content)
            let hints = all.filter { String(describing: type(of: $0)) == "KeycapView" && !$0.isHidden }
            let frames = hints.map { content.convert($0.bounds, from: $0) }
            let label = all.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Draft kept" }
            let context = "Footer \(title) draft=\(!draft.isEmpty)"
            try require(hints.count == 3, "\(context): three hints")
            try require(frames.allSatisfy { content.bounds.contains($0) }, "\(context): hints must be inside the panel")
            try require(panel.frame.width >= (frames.map(\.maxX).max() ?? 0) + OverlayTheme.quickFooterLeadingInset, "\(context): width must cover the footer")
            if let label, !label.isHidden {
                let labelFrame = content.convert(label.bounds, from: label)
                try require(content.bounds.contains(labelFrame), "\(context): draft label must be inside the panel")
                try require((frames.map(\.maxX).max() ?? 0) < labelFrame.minX, "\(context): hints must not overlap Draft kept")
            } else {
                try require(draft.isEmpty, "\(context): Draft kept must fit at these widths")
            }
            // Browse adds its own three hints while the note footer stays unchanged.
            try key(35, modifiers: .command)
            try await settle()
            content.layoutSubtreeIfNeeded()
            guard let card = descendants(content).first(where: { String(describing: type(of: $0)) == "NoteBrowseView" }) else {
                throw GalleryError("\(context): Browse card missing")
            }
            let browseHints = descendants(card).filter { String(describing: type(of: $0)) == "KeycapView" }
            try require(browseHints.count == 3 && browseHints.allSatisfy { card.bounds.insetBy(dx: OverlayTheme.browseFooterInset, dy: 0).contains(card.convert($0.bounds, from: $0)) },
                        "\(context): three Browse hints must fit inside the card with 12pt side insets")
            try require(hints.enumerated().allSatisfy { index, hint in !hint.isHidden && content.convert(hint.bounds, from: hint) == frames[index] },
                        "\(context): normal note hints must remain visible at their original frames")
            try key(53)
            try await settle()
            editor.dismiss()
            try await settle()
        }
    }
}

/// Option-Command-Return saves the text as a new note even when it names an existing one.
@MainActor
private func checkSaveAsNewShortcut() async throws {
    let editor = NoteEditorPanel()
    let text = "# groceries\n- milk"
    var saved: [String] = []
    editor.present(destination: nil, isPinned: false, draft: text, handlers: NoteEditorHandlers(
        onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in },
        browseItems: { [] }, onBrowse: { _, _ in }, onTogglePin: { true }, onClose: {}, onError: { _ in },
        existingTitleForText: { _ in "Groceries" }, onSaveAsNew: { saved.append($0) }))
    let panel = try currentPanel()
    try key(36, modifiers: [.command, .option])
    try await settle()
    try require(saved == [text] && !panel.isVisible, "Option-Command-Return must save as a new note and close the editor")
}

/// Spec checks for the quick-note surface: title line, top-band chrome, footer copy, caret geometry.
@MainActor
private func checkQuickNoteDesign() throws {
    func titleLabel(_ view: NSView) -> NSTextField? {
        descendants(view).compactMap { $0 as? NSTextField }.first { $0.font == OverlayTheme.quickTitleFont }
    }
    func shown(_ view: NSView) -> String? { view.layoutSubtreeIfNeeded(); return titleLabel(view)?.stringValue }
    let empty = OverlayPreview.noteEditor()
    try require(shown(empty) == "New note", "Empty quick note must be titled \"New note\"")
    let rest = titleLabel(empty), hover = titleLabel(OverlayPreview.noteEditor(revealed: true))
    try require(rest.map { abs($0.alphaValue - OverlayTheme.quickTitleRestAlpha) < 0.001 } == true, "Title must be faded at rest")
    try require(hover.map { abs($0.alphaValue - OverlayTheme.quickTitleRevealAlpha) < 0.001 } == true, "Title must brighten on reveal")
    try require(rest?.accessibilityRole() == .staticText && rest?.accessibilityValue() as? String == "New note", "Title accessibility")
    try require(shown(OverlayPreview.noteEditor(destination: "Trip planning", text: "# Other")) == "Trip planning", "Destination wins the title")
    try require(shown(OverlayPreview.noteEditor(text: "\n  # Trip planning\nbody")) == "Trip planning", "Typed text must title the note")
    try require(shown(OverlayPreview.noteEditor(text: "- [ ] buy milk")) == "buy milk", "Task markers must be stripped from the title")
    try require(shown(OverlayPreview.noteEditor(text: " \n ")) == "New note", "Blank text must keep the placeholder title")
    let long = NoteEditorHandlers.defaultTitle("> 1. " + String(repeating: "x", count: 80))
    try require(long == String(repeating: "x", count: OverlayTheme.quickTitleLimit) + "…", "Default title must strip markers and cut at 60")

    let footerLabels = { (view: NSView) in descendants(view).compactMap { $0 as? NSTextField }.map(\.stringValue) }
    try require(footerLabels(OverlayPreview.noteEditor()).contains("Create note"), "Footer without a destination")
    try require(footerLabels(OverlayPreview.noteEditor(destination: "Trip planning")).contains("Add to note"), "Footer with a destination")
    try require(shown(OverlayPreview.noteEditor(text: "# groceries\n- milk", appendsTo: "Groceries")) == "Groceries", "Text naming a note must title the note with that note's title")
    try require(footerLabels(OverlayPreview.noteEditor(text: "# groceries\n- milk", appendsTo: "Groceries")).contains("Add to note"), "Footer when the text names a note")
    try require(shown(OverlayPreview.noteEditor(text: "# groceries\n- milk")) == "groceries", "Text without a matching note keeps its own title")
    try require(footerLabels(OverlayPreview.noteEditor(text: "# groceries\n- milk")).contains("Create note"), "Footer when the text names no note")

    // Top band: five 26pt buttons; the right three are adjacent inside one capsule; the title stays clear of all of them.
    let band = OverlayPreview.noteEditor(destination: String(repeating: "Wide title ", count: 12), revealed: true)
    band.layoutSubtreeIfNeeded()
    let buttons = descendants(band).filter { String(describing: type(of: $0)) == "ChromeButton" }
    try require(buttons.count == 5 && buttons.allSatisfy { $0.frame.size == NSSize(width: OverlayTheme.quickButtonSize, height: OverlayTheme.quickButtonSize) },
                "Top band must have five 26pt buttons")
    let right = buttons.sorted { $0.frame.minX < $1.frame.minX }.suffix(3)
    try require(right.map { $0.accessibilityLabel() ?? "" } == ["Browse notes", "New note", "Actions"],
                "The capsule order must be Browse, New, Actions")
    try require(right.last.flatMap { OverlayPreview.chromeSymbol(in: $0) } == "ellipsis", "The trailing Actions button must use ellipsis")
    try require(zip(right, right.dropFirst()).allSatisfy { abs($0.frame.maxX - $1.frame.minX) < 0.01 }, "Right buttons must be adjacent")
    let capsule = descendants(band).first { String(describing: type(of: $0)) == "ChromeCluster" }
    try require(capsule.map { $0.frame.height == OverlayTheme.quickClusterHeight && $0.frame.contains(right.first!.frame) && $0.frame.contains(right.last!.frame) } == true,
                "Right buttons must sit inside one 28pt capsule")
    if let title = titleLabel(band) {
        try require(buttons.allSatisfy { !$0.frame.intersects(title.frame) }, "Title must not overlap the chrome buttons")
        try require(abs(title.frame.midX - band.bounds.midX) < 0.5, "Title must be centred in the band")
    } else { throw GalleryError("Title label missing") }

    for revealed in [false, true] {
        let pinned = OverlayPreview.noteEditor(destination: "Trip planning", revealed: revealed, isPinned: true)
        pinned.layoutSubtreeIfNeeded()
        guard let pin = descendants(pinned).first(where: { $0.accessibilityIdentifier() == "QuickNote.pinned" }), let label = titleLabel(pinned) else {
            throw GalleryError("Pinned title glyph missing")
        }
        try require(!pin.isHidden && pin.frame.size == NSSize(width: 10, height: 10) && pin.alphaValue == label.alphaValue,
                    "The title pin must be 10pt and share the title reveal alpha")
        try require(label.frame.minX - pin.frame.maxX == 4 && abs(pin.frame.union(label.frame).midX - pinned.bounds.midX) < 0.01,
                    "Pin plus title must be centred as one unit with a 4pt gap")
    }
    let unpinned = OverlayPreview.noteEditor()
    try require(descendants(unpinned).first { $0.accessibilityIdentifier() == "QuickNote.pinned" }?.isHidden == true,
                "An unpinned note must hide its title pin")
    // Caret: 2pt wide, 1.1 x font size tall, 0.22 x font size below the baseline.
    let width = OverlayTheme.editorCaretWidth
    for (text, selection, size) in [("hello", 5, 15.0), ("hello", 0, 15.0), ("", 0, 15.0), ("hello\n", 6, 15.0), ("# Head", 6, 22.0), ("- [ ] ", 6, 15.0)] {
        let view = OverlayPreview.noteEditor(text: text, selection: NSRange(location: selection, length: 0))
        view.layoutSubtreeIfNeeded()
        guard let caret = OverlayPreview.caretRect(in: view) else { throw GalleryError("Caret rect missing for \(text.debugDescription)") }
        try require(abs(caret.width - width) < 0.01 && width == 2, "Caret must be 2pt wide")
        try require(abs(caret.height - size * 1.1) < 0.5, "Caret height for \(text.debugDescription): \(caret.height)")
    }
    let sample = OverlayPreview.noteEditor(text: "hello", selection: NSRange(location: 5, length: 0))
    sample.layoutSubtreeIfNeeded()
    try require(OverlayPreview.caretRect(in: sample).map { abs($0.height - 16.5) < 0.5 } == true, "Body caret must be about 16.5pt tall")
    let selected = OverlayPreview.noteEditor(text: "hello", selection: NSRange(location: 1, length: 3))
    try require(OverlayPreview.caretRect(in: selected) == nil, "A selection must hide the caret")
    try checkCardDesign()
    print("Quick-note design checks passed (title line, capsule chrome, footer copy, caret geometry).")
}

/// Spec F: both cards share one surface, hang top-right under the band, and use the spec metrics.
@MainActor
private func checkCardDesign() throws {
    func named(_ view: NSView, _ name: String) -> [NSView] { descendants(view).filter { String(describing: type(of: $0)) == name } }
    let actions = OverlayPreview.noteEditor(text: "one\ntwo", revealed: true, overlay: .actions(selected: 0))
    actions.layoutSubtreeIfNeeded()
    try checkCardButtonState(in: actions, open: "Actions", context: "Actions snapshot")
    guard let menu = named(actions, "NoteActionMenuView").first else { throw GalleryError("Actions card missing") }
    let menuFrame = actions.convert(menu.bounds, from: menu)
    try require(abs(menuFrame.width - 280) < 0.5, "Actions card width")
    try require(abs(menuFrame.maxX - (actions.bounds.width - 8)) < 0.5 && abs(menuFrame.minY - 40) < 0.5, "Actions card must anchor top-right under the band")
    try require(actions.bounds.height >= menuFrame.maxY + 8 - 0.5, "Window must fit the Actions overflow")
    let rows = named(menu, "ActionRowView")
    let actionLabels = descendants(menu).compactMap { $0 as? NSTextField }.map(\.stringValue)
    try require(actionLabels.contains("Add to Pinned") && !actionLabels.contains("Pin Note") && !actionLabels.contains("Unpin Note"),
                "The action must describe Browse pinning, not window stickiness")
    let pinnedMenu = OverlayPreview.noteEditor(isPinned: true, overlay: .actions())
    try require(descendants(pinnedMenu).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Remove from Pinned" },
                "Pinned notes must offer Remove from Pinned")
    try require(rows.count == 6 && rows.allSatisfy { abs($0.frame.height - 32) < 0.01 }, "Actions rows are 32pt")
    // Save as New Note is enabled only when the text names an existing note; a disabled row refuses a press.
    let saveRow = rows.first { $0.accessibilityLabel() == "Save as New Note" }
    try require(saveRow?.isAccessibilityEnabled() == false && saveRow?.accessibilityPerformPress() == false,
                "Save as New Note must be disabled when the text names no note")
    let collision = OverlayPreview.noteEditor(text: "one\ntwo", revealed: true, overlay: .actions(), appendsTo: "Groceries")
    collision.layoutSubtreeIfNeeded()
    let collisionRows = named(collision, "ActionRowView")
    let collisionSave = collisionRows.first { $0.accessibilityLabel() == "Save as New Note" }
    try require(collisionRows.count == 6 && collisionSave?.isAccessibilityEnabled() == true, "Save as New Note must be enabled when the text names a note")
    try require(named(menu, "SeparatorView").count == 2, "Actions card: header separator plus one group separator")
    let groups = rows.map { menu.convert($0.bounds, from: $0).minY }.sorted()
    try require(groups[3] - groups[2] > 32.5, "A gap must separate the two action groups")
    try require(menu.layer?.cornerRadius == 12, "Cards use a 12pt radius")

    let many = (0..<12).map { BrowseItem(id: "n\($0)", title: "Note \($0)", detail: "Note · Oct \($0 + 1)", symbolName: "doc.text", isPinned: $0 < 2) }
    let browse = OverlayPreview.noteEditor(text: "one\ntwo", revealed: true, overlay: .browse(items: many, selected: 0))
    browse.layoutSubtreeIfNeeded()
    try checkCardButtonState(in: browse, open: "Browse notes", context: "Browse snapshot")
    guard let card = named(browse, "NoteBrowseView").first, let list = card.subviews.compactMap({ $0 as? NSScrollView }).first else { throw GalleryError("Browse card missing") }
    let cardFrame = browse.convert(card.bounds, from: card)
    try require(abs(cardFrame.width - 320) < 0.5, "Browse card width")
    // Two section headers (Pinned, Recent) and seven rows are visible; the rest scrolls.
    let expected = 4 + 2 * OverlayTheme.browseHeaderHeight + 7 * OverlayTheme.browseRowHeight + 4
    try require(abs(list.frame.height - expected) < 0.5,
                "Browse list must show at most seven rows (height \(list.frame.height))")
    try require((list.documentView?.frame.height ?? 0) > list.frame.height, "Browse must scroll past seven rows")
    try require(named(browse, "BrowseRowView").allSatisfy { abs($0.frame.height - 40) < 0.01 }, "Browse rows are 40pt")
    try require(browse.bounds.height >= cardFrame.maxY + 8 - 0.5, "Window must fit the Browse overflow")
    let cardHints = named(card, "KeycapView").sorted { $0.frame.minX < $1.frame.minX }
    try require(cardHints.count == 3, "Browse must have exactly three footer hints")
    guard let strip = cardHints.first?.superview else { throw GalleryError("Browse footer missing") }
    let stripFrame = card.convert(strip.bounds, from: strip)
    try require(stripFrame.height == OverlayTheme.browseFooterHeight && stripFrame.maxY == card.bounds.maxY,
                "Browse hints must occupy the bottom 28pt strip")
    try require(named(card, "SeparatorView").count == 2 && list.frame.maxY == stripFrame.minY - OverlayTheme.borderWidth,
                "The list must scroll above the footer separator")
    try require(cardHints.first?.frame.minX == OverlayTheme.browseFooterInset && cardHints.allSatisfy { strip.bounds.contains($0.frame) }
                && zip(cardHints, cardHints.dropFirst()).allSatisfy { $1.frame.minX - $0.frame.maxX == 16 },
                "Browse footer hints must fit with a 12pt inset and the standard gaps")
    let empty = OverlayPreview.noteEditor(text: "one", revealed: true, overlay: .browse(items: []))
    guard let emptyCard = named(empty, "NoteBrowseView").first else { throw GalleryError("Empty Browse card missing") }
    try require(abs(emptyCard.frame.height - (OverlayTheme.cardFieldHeight + OverlayTheme.borderWidth + OverlayTheme.browseEmptyHeight + OverlayTheme.borderWidth + OverlayTheme.browseFooterHeight)) < 0.5, "Empty Browse area is 56pt")
}

/// Moving the quick note: position math, drag handles, screen changes, remembered position, resize clamp.
@MainActor
private func checkPanelMoving() async throws {
    func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
    // Fractions -> clamped frame.
    let big = NSRect(x: 0, y: 25, width: 1440, height: 875)
    let size = NSSize(width: 500, height: 200)
    let mid = OverlayPreview.panelFrame(topCenter: CGPoint(x: 0.5, y: 0.78), size: size, in: big)
    try require(near(mid.midX, 720) && near(mid.maxY, 25 + 875 * 0.78) && mid.size == size, "Top-centre fractions must place the frame")
    let back = OverlayPreview.topCenter(of: mid, in: big)
    try require(near(back.x, 0.5) && near(back.y, 0.78), "Top-centre fractions must round-trip")
    let corner = OverlayPreview.panelFrame(topCenter: CGPoint(x: 0.99, y: 1.02), size: size, in: big)
    try require(near(corner.maxX, big.maxX) && near(corner.maxY, big.maxY), "A point near the top-right edge must be clamped inside")
    let low = OverlayPreview.panelFrame(topCenter: CGPoint(x: 0.001, y: 0.05), size: size, in: big)
    try require(near(low.minX, big.minX) && near(low.minY, big.minY), "A point near the bottom-left edge must be clamped inside")
    let small = NSRect(x: 1440, y: 0, width: 1024, height: 600)
    for point in [CGPoint(x: 0.5, y: 0.78), CGPoint(x: 0.97, y: 0.2), CGPoint(x: 0.02, y: 0.99)] {
        let frame = OverlayPreview.panelFrame(topCenter: point, size: size, in: small)
        try require(small.insetBy(dx: -0.01, dy: -0.01).contains(frame), "A stored point must clamp inside a smaller screen")
    }
    let tooBig = OverlayPreview.panelFrame(topCenter: CGPoint(x: 0.5, y: 0.5), size: NSSize(width: 2000, height: 900), in: small)
    try require(near(tooBig.minX, small.minX) && near(tooBig.maxY, small.maxY), "A frame larger than the screen keeps its top-left")
    // Resize clamp: top fixed and centred until the frame would leave the screen.
    let free = OverlayPreview.resizedFrame(NSRect(x: 400, y: 400, width: 500, height: 200), to: NSSize(width: 560, height: 300), in: big)
    try require(near(free.maxY, 600) && near(free.midX, 650), "An unconstrained resize keeps the top edge and centre")
    let nearBottom = OverlayPreview.resizedFrame(NSRect(x: 400, y: 60, width: 500, height: 200), to: NSSize(width: 500, height: 500), in: big)
    try require(near(nearBottom.minY, big.minY) && near(nearBottom.height, 500) && big.contains(nearBottom), "Growing near the bottom must shift up, staying inside")
    let nearEdge = OverlayPreview.resizedFrame(NSRect(x: 10, y: 400, width: 400, height: 200), to: NSSize(width: 600, height: 200), in: big)
    try require(near(nearEdge.minX, big.minX) && near(nearEdge.maxY, 600), "Growing near the left edge must shift right only")

    // Drag handles: bands yes; text, buttons and open cards no.
    let rest = OverlayPreview.noteEditor(text: "one\ntwo")
    rest.layoutSubtreeIfNeeded()
    let width = rest.bounds.width, height = rest.bounds.height
    try require(OverlayPreview.isDragHandle(in: rest, at: NSPoint(x: width / 2, y: 19)), "The title/top band must be a drag handle at rest")
    try require(OverlayPreview.isDragHandle(in: rest, at: NSPoint(x: 20, y: 5)) && OverlayPreview.isDragHandle(in: rest, at: NSPoint(x: width - 5, y: 30)),
                "Top band points are drag handles")
    try require(OverlayPreview.isDragHandle(in: rest, at: NSPoint(x: width / 2, y: height - 10)), "The footer band must be a drag handle")
    try require(!OverlayPreview.isDragHandle(in: rest, at: NSPoint(x: 60, y: 38 + 10)), "Text must not be a drag handle")
    let hover = OverlayPreview.noteEditor(text: "one\ntwo", revealed: true)
    hover.layoutSubtreeIfNeeded()
    let buttons = descendants(hover).filter { String(describing: type(of: $0)) == "ChromeButton" }
    try require(!buttons.isEmpty && buttons.allSatisfy { !OverlayPreview.isDragHandle(in: hover, at: hover.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), from: $0)) },
                "Chrome buttons must not be drag handles")
    try require(OverlayPreview.isDragHandle(in: hover, at: NSPoint(x: width / 2, y: 19)), "The title stays a handle when revealed")
    let withCard = OverlayPreview.noteEditor(text: "one\ntwo", revealed: true, overlay: .actions(selected: 0))
    withCard.layoutSubtreeIfNeeded()
    guard let card = descendants(withCard).first(where: { String(describing: type(of: $0)) == "NoteActionMenuView" }) else { throw GalleryError("Card missing") }
    try require(!OverlayPreview.isDragHandle(in: withCard, at: withCard.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), from: card)), "An open card must not be a drag handle")
    try require(OverlayPreview.isDragHandle(in: withCard, at: NSPoint(x: withCard.bounds.width / 2, y: 19))
                && OverlayPreview.isDragHandle(in: withCard, at: NSPoint(x: 10, y: OverlayPreview.noteRect(in: withCard).maxY - 10)),
                "The bands stay handles while a card is open")

    // Only the note editor's panel is movable.
    try require(OverlayPanel(interactive: true, size: .zero, movable: true).isMovable && !OverlayPanel(interactive: true, size: .zero).isMovable
                && !OverlayPanel(interactive: false, size: .zero).isMovable, "Only the note editor panel is movable")

    // A real panel: remembered position, screen/Space changes keep it open, screen parameters re-clamp it.
    let defaults = UserDefaults.standard
    let saved = defaults.object(forKey: OverlayPreview.positionDefaultsKey)
    defer { if let saved { defaults.set(saved, forKey: OverlayPreview.positionDefaultsKey) } else { defaults.removeObject(forKey: OverlayPreview.positionDefaultsKey) } }
    defaults.set([0.5, 0.9], forKey: OverlayPreview.positionDefaultsKey)
    let editor = NoteEditorPanel()
    func present() {
        editor.present(destination: nil, isPinned: false, draft: "moving", handlers: NoteEditorHandlers(
            onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
            onBrowse: { _, _ in }, onTogglePin: { false }, onClose: {}, onError: { _ in }))
    }
    present()
    let panel = try currentPanel()
    try require(panel.isMovable, "The note editor panel must be movable")
    guard let visible = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame else { throw GalleryError("No screen") }
    let placed = OverlayPreview.topCenter(of: panel.frame, in: visible)
    try require(near(placed.x, 0.5) && near(placed.y, 0.9) && visible.insetBy(dx: -0.01, dy: -0.01).contains(panel.frame), "The panel must open at the remembered position")
    NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: panel)
    try await settle()
    try require(editor.isVisible, "A screen change must not dismiss the movable note panel")
    panel.setFrameOrigin(NSPoint(x: visible.maxX - 10, y: visible.minY - 60))
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    try await settle()
    try require(editor.isVisible && visible.insetBy(dx: -0.01, dy: -0.01).contains(OverlayPreview.noteFrame(in: panel)),
                "Screen parameter changes must re-clamp the sticky note rather than dismiss it")
    editor.dismiss()
    defaults.removeObject(forKey: OverlayPreview.positionDefaultsKey)
    present()
    let defaultPanel = try currentPanel()
    try require(near(defaultPanel.frame.midX, visible.midX), "Without a remembered position the panel opens centred")
    editor.dismiss()
    try await settle()
    print("Panel moving checks passed (position math, drag handles, screen change, remembered position, resize clamp).")
}

/// Caret at soft wraps, in selections and marked text, on empty fenced-code lines; title with leading blank lines.
@MainActor
private func checkCaretStates() async throws {
    // At a soft wrap the caret is drawn on the line of the system's rect, not the line of the character.
    let wrapped = OverlayPreview.noteEditor(text: String(repeating: "wrapping words ", count: 14))
    wrapped.layoutSubtreeIfNeeded()
    let lines = OverlayPreview.lineEndSystemRects(in: wrapped)
    try require(lines.count >= 2, "Soft-wrap fixture must wrap")
    let tight = lines.prefix(2).compactMap { OverlayPreview.tightCaret(in: wrapped, systemRect: $0) }
    try require(tight.count == 2, "Tight caret for wrapped lines")
    for (caret, system) in zip(tight, lines) {
        try require(caret.midY > system.minY && caret.midY < system.maxY && abs(caret.minX - system.minX) < 0.001,
                    "The caret must lie on the line (and at the x) of the system rect: \(caret) vs \(system)")
    }
    try require(tight[1].minY - tight[0].minY > 15, "Different lines must give different carets")

    // Title: leading blank lines must not hide the first real line.
    let late = OverlayPreview.noteEditor(text: String(repeating: "\n", count: 2_100) + "Late title")
    try require(descendants(late).compactMap { $0 as? NSTextField }.contains { $0.font == OverlayTheme.quickTitleFont && $0.stringValue == "Late title" },
                "A draft starting with thousands of blank lines must still be titled")

    // An empty line inside an open fence uses the code font.
    let fenced = OverlayPreview.noteEditor(text: "```\ncode\n", selection: NSRange(location: 9, length: 0))
    fenced.layoutSubtreeIfNeeded()
    try require(OverlayPreview.caretRect(in: fenced).map { abs($0.height - OverlayTheme.editorCodeFont.pointSize * 1.1) < 0.5 } == true,
                "Caret on an empty fenced-code line must be 1.1 x the code font size")
    let plain = OverlayPreview.noteEditor(text: "```\ncode\n```\n", selection: NSRange(location: 13, length: 0))
    plain.layoutSubtreeIfNeeded()
    try require(OverlayPreview.caretRect(in: plain).map { abs($0.height - OverlayTheme.editorFont.pointSize * 1.1) < 0.5 } == true,
                "Caret after a closed fence is body-sized")

    // Selection draws nothing (and never reaches the system's caret); marked text keeps the tight caret.
    let editor = NoteEditorPanel()
    editor.present(destination: nil, isPinned: false, draft: "hello world", handlers: NoteEditorHandlers(
        onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
        onBrowse: { _, _ in }, onTogglePin: { false }, onClose: {}, onError: { _ in }))
    defer { editor.dismiss() }
    guard let root = try currentPanel().contentView,
          let text = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }) else {
        throw GalleryError("Note text view missing")
    }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw GalleryError("Could not allocate a bitmap context") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    text.setSelectedRange(NSRange(location: 2, length: 3))
    guard let system = OverlayPreview.layoutCaretRect(in: text) else { throw GalleryError("Layout caret rect missing") }
    let selected = OverlayPreview.drawCaret(in: text, systemRect: system, turnedOn: true)
    try require(selected.painted == 0 && selected.system == 0, "A selection must draw no caret, not even the system one")
    let erased = OverlayPreview.drawCaret(in: text, systemRect: system, turnedOn: false)
    try require(erased.painted == 0 && erased.system == 1, "Blink-off/erase must still run with a selection")
    text.setSelectedRange(NSRange(location: 5, length: 0))
    try require(OverlayPreview.drawCaret(in: text, systemRect: system, turnedOn: true) == (1, 0), "A collapsed selection draws the tight caret")
    let reported = text.firstRect(forCharacterRange: NSRange(location: 5, length: 0), actualRange: nil)
    if let window = text.window {
        let local = text.convert(window.convertFromScreen(reported), from: nil)
        try require(abs(local.width - OverlayTheme.editorCaretWidth) < 0.01 && abs(local.height - 16.5) < 0.5,
                    "System insertion-point accessories must receive the drawn caret's geometry")
    }
    text.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    try require(text.hasMarkedText(), "IME fixture must have marked text")
    try require(OverlayPreview.drawCaret(in: text, systemRect: system, turnedOn: true) == (1, 0), "Marked text must show the tight caret")
    text.setMarkedText("abc", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
    try require(OverlayPreview.drawCaret(in: text, systemRect: system, turnedOn: true) == (1, 0), "A selection inside marked text still shows the caret")
    text.unmarkText()
    print("Caret state checks passed (soft wrap, selection, marked text, fenced code, leading-blank title).")
}

/// One window, two visible shapes: a card must leave every note geometry unchanged.
@MainActor
private func checkFloatingCards() async throws {
    let editor = NoteEditorPanel()
    defer { editor.dismiss() }
    let items = (0..<12).map { BrowseItem(id: "n\($0)", title: "Note \($0)", detail: "Recent", symbolName: "doc.text", isPinned: $0 < 2) }
    var clicked: String?
    func present(_ text: String) {
        editor.present(destination: nil, isPinned: false, draft: text, handlers: NoteEditorHandlers(
            onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { items },
            onBrowse: { item, _ in clicked = item.id }, onTogglePin: { true }, onClose: {}, onError: { _ in }))
    }
    func named(_ root: NSView, _ name: String) -> [NSView] {
        descendants(root).filter { String(describing: type(of: $0)) == name }
    }
    func move(_ panel: OverlayPanel, root: NSView, to point: NSPoint) throws {
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: root.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
            throw GalleryError("Could not construct movement")
        }
        panel.sendEvent(event)
    }
    for text in ["one\ntwo", String(repeating: "line\n", count: 44)] {
        present(text)
        let panel = try currentPanel()
        guard let root = panel.contentView else { throw GalleryError("Editor root missing") }
        root.layoutSubtreeIfNeeded()
        let noteFrame = OverlayPreview.noteFrame(in: panel)
        let noteRect = OverlayPreview.noteRect(in: root)
        guard let surface = named(root, "OverlaySurface").first else { throw GalleryError("Note surface missing") }
        let geometry = surface.subviews.map(\.frame)
        for code: UInt16 in [40, 35] {
            try key(code, modifiers: .command)
            root.layoutSubtreeIfNeeded()
            try require(OverlayPreview.noteFrame(in: panel) == noteFrame && OverlayPreview.noteRect(in: root) == noteRect,
                        "Card open must keep the note's screen and local rect identical (text \(text.count), key \(code), screen \(noteFrame) -> \(OverlayPreview.noteFrame(in: panel)), local \(noteRect) -> \(OverlayPreview.noteRect(in: root)))")
            try require(surface.subviews.map(\.frame) == geometry, "The title, text, chrome and footer must not move")
            guard let card = named(root, code == 40 ? "NoteActionMenuView" : "NoteBrowseView").first else { throw GalleryError("Floating card missing") }
            try require(root.layer?.masksToBounds == false && surface.layer?.masksToBounds == true && card.layer?.shadowOpacity == 0,
                        "Clip only the note surface and use a single window shadow for the visible shapes")
            try require(card.acceptsFirstMouse(for: nil), "Card backgrounds must accept the first mouse click")
            guard let filter = descendants(card).compactMap({ $0 as? NSTextField }).first(where: \.isEditable),
                  let list = card.subviews.compactMap({ $0 as? NSScrollView }).first, let document = list.documentView else {
                throw GalleryError("Card filter/document missing")
            }
            try require(filter.acceptsFirstMouse(for: nil) && document.acceptsFirstMouse(for: nil),
                        "Card filters and scroll documents must accept the first mouse click while inactive")
            try require(named(card, code == 40 ? "ActionRowView" : "BrowseRowView").allSatisfy { $0.acceptsFirstMouse(for: nil) },
                        "Every card row must accept the first mouse click")
            try require(panel.frame.maxY == noteFrame.maxY && panel.frame.width == noteFrame.width, "Window overflow only grows downward")
            if text == "one\ntwo" {
                try require(card.frame.maxY > noteRect.maxY && panel.frame.height > noteFrame.height, "Card must hang below a two-line note")
                try require(!OverlayPreview.isDragHandle(in: root, at: NSPoint(x: 5, y: root.bounds.height - 5)), "Transparent overflow cannot drag")
                try require(!OverlayPreview.isDragHandle(in: root, at: NSPoint(x: card.frame.midX, y: card.frame.maxY - 10)), "Overflow card cannot drag")
            }
            try key(53)
            try require(panel.frame == noteFrame && OverlayPreview.noteFrame(in: panel) == noteFrame && OverlayPreview.noteRect(in: root) == noteRect,
                        "Card close must immediately shrink the window to exactly the unchanged note")
        }
        // Swapping between differently sized cards keeps the note at the same rect.
        try key(40, modifiers: .command); try key(35, modifiers: .command)
        try require(OverlayPreview.noteFrame(in: panel) == noteFrame, "Swapping cards must not move or resize the note")
        try key(53)
        editor.dismiss()
    }
    // Card operations during a resize must preserve the current animation frame and let it continue.
    if !OverlayTheme.reduceMotion {
        present("one\ntwo")
        let animatingPanel = try currentPanel()
        guard let animatingRoot = animatingPanel.contentView,
              let typing = descendants(animatingRoot).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }) else {
            throw GalleryError("Animating editor missing")
        }
        typing.insertText(String(repeating: "\nline", count: 12), replacementRange: typing.selectedRange())
        try await Task.sleep(for: .milliseconds(20))
        let during = OverlayPreview.noteFrame(in: animatingPanel)
        try key(40, modifiers: .command)
        try require(OverlayPreview.noteFrame(in: animatingPanel) == during, "Opening a card must not jump an in-flight note resize")
        try key(35, modifiers: .command)
        try require(OverlayPreview.noteFrame(in: animatingPanel) == during, "Swapping cards must not jump an in-flight note resize")
        try key(53)
        try require(OverlayPreview.noteFrame(in: animatingPanel) == during && animatingPanel.frame == during,
                    "Closing a card must shrink to the current note animation frame")
        try await settle()
        try require(OverlayPreview.noteFrame(in: animatingPanel).height > during.height, "Card operations must allow the note animation to finish normally")
        editor.dismiss()
    }
    // Both lists cap to the actual screen space, and scroll internally instead of shifting the note.
    present("one\ntwo")
    let panel = try currentPanel()
    guard let root = panel.contentView, let screen = panel.screen else { throw GalleryError("Editor/screen missing") }
    var low = panel.frame
    low.origin.y = screen.visibleFrame.minY + 16
    panel.setFrame(low, display: true)
    let noteFrame = OverlayPreview.noteFrame(in: panel)
    for code: UInt16 in [40, 35] {
        try key(code, modifiers: .command)
        root.layoutSubtreeIfNeeded()
        guard let card = named(root, code == 40 ? "NoteActionMenuView" : "NoteBrowseView").first,
              let scroll = card.subviews.compactMap({ $0 as? NSScrollView }).first else { throw GalleryError("Capped card/list missing") }
        let cardScreen = panel.convertToScreen(root.convert(card.frame, to: nil))
        try require(cardScreen.minY >= screen.visibleFrame.minY + 8 - 0.01 && OverlayPreview.noteFrame(in: panel) == noteFrame,
                    "Card must end 8pt above the screen bottom without moving the note")
        try require((scroll.documentView?.frame.height ?? 0) > scroll.contentSize.height && scroll.hasVerticalScroller,
                    "Both capped card lists must scroll")
        try key(53)
    }
    // Exercise the real screen-change callback with an open card on a single-monitor host.
    var callbackPosition = panel.frame
    callbackPosition.origin.y = screen.visibleFrame.minY + 200
    panel.setFrame(callbackPosition, display: true)
    let callbackNote = OverlayPreview.noteFrame(in: panel)
    var smaller = screen.visibleFrame
    smaller.origin.y += 180
    smaller.size.height -= 180
    for code: UInt16 in [40, 35] {
        OverlayPreview.screenChanged(in: panel, to: screen.visibleFrame)
        try key(code, modifiers: .command)
        guard let card = named(root, code == 40 ? "NoteActionMenuView" : "NoteBrowseView").first else { throw GalleryError("Screen-change card missing") }
        let originalHeight = card.frame.height
        let anchor = card.frame.origin
        OverlayPreview.screenChanged(in: panel, to: smaller)
        try await settle()
        let budget = callbackNote.maxY - smaller.minY - OverlayTheme.quickTopBandHeight - OverlayTheme.cardTopGap - OverlayTheme.cardEdgeMargin
        try require(editor.isVisible && OverlayPreview.noteFrame(in: panel) == callbackNote,
                    "A screen-change callback with a card open must leave the note frame unchanged")
        try require(card.frame.origin == anchor && card.frame.maxX == root.bounds.width - OverlayTheme.cardEdgeMargin,
                    "A screen change must preserve the card anchor")
        try require(card.frame.height < originalHeight && abs(card.frame.height - budget) < 0.01,
                    "A screen change must recompute the card cap from the new visible frame")
        if code == 35, let list = card.subviews.compactMap({ $0 as? NSScrollView }).first {
            let hints = named(card, "KeycapView")
            guard let strip = hints.first?.superview else { throw GalleryError("Capped Browse footer missing") }
            try require(strip.frame.height == OverlayTheme.browseFooterHeight && strip.frame.maxY == card.bounds.height
                        && list.frame.maxY == strip.frame.minY - OverlayTheme.borderWidth && hints.allSatisfy { strip.bounds.contains($0.frame) },
                        "The capped list must preserve the full Browse hint strip")
        }
        try key(53)
    }
    OverlayPreview.screenChanged(in: panel, to: screen.visibleFrame)
    editor.dismiss()
    // Mouse movement uses the same path as live events, including label/icon hit testing and disabled rows.
    present("")
    let mousePanel = try currentPanel()
    guard let mouseRoot = mousePanel.contentView else { throw GalleryError("Mouse root missing") }
    try require(mousePanel.acceptsMouseMovedEvents, "The inactive panel must request mouse movement")
    try key(40, modifiers: .command)
    guard let menu = named(mouseRoot, "NoteActionMenuView").first else { throw GalleryError("Actions missing") }
    let rows = named(menu, "ActionRowView")
    try require(rows.count == 6 && !descendants(menu).compactMap({ $0 as? NSTextField }).contains { $0.stringValue == "Browse Notes" },
                "Actions must contain six rows and no Browse Notes")
    let pinPoint = mouseRoot.convert(NSPoint(x: rows[2].bounds.midX, y: rows[2].bounds.midY), from: rows[2])
    try move(mousePanel, root: mouseRoot, to: pinPoint)
    try require(OverlayPreview.selectedCardID(in: menu) == "pin" && rows[2].accessibilityValue() as? String == "Selected", "Hover must select the Actions row")
    let disabledPoint = mouseRoot.convert(NSPoint(x: rows[5].bounds.midX, y: rows[5].bounds.midY), from: rows[5])
    try move(mousePanel, root: mouseRoot, to: disabledPoint)
    try require(OverlayPreview.selectedCardID(in: menu) == "pin" && rows[5].accessibilityValue() as? String != "Selected", "Disabled rows must not highlight on hover")
    try require(!rows[5].accessibilityPerformPress(), "Disabled Actions must do nothing")
    try key(35, modifiers: .command)
    guard let browse = named(mouseRoot, "NoteBrowseView").first else { throw GalleryError("Browse missing") }
    let browseRows = named(browse, "BrowseRowView")
    let browsePoint = mouseRoot.convert(NSPoint(x: browseRows[1].bounds.midX, y: browseRows[1].bounds.midY), from: browseRows[1])
    try move(mousePanel, root: mouseRoot, to: browsePoint)
    try require(OverlayPreview.selectedCardID(in: browse) == "n1", "Hover must select the Browse row")
    let hit = mouseRoot.hitTest(mouseRoot.convert(browsePoint, to: mouseRoot.superview))
    try require(hit === browseRows[1], "Row labels and icons must route mouse clicks to the row")
    guard let click = NSEvent.mouseEvent(with: .leftMouseDown, location: mouseRoot.convert(browsePoint, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: mousePanel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw GalleryError("Click fixture missing") }
    hit?.mouseDown(with: click)
    try require(clicked == "n1" && named(mouseRoot, "NoteBrowseView").isEmpty, "Clicking Browse must Write here and close the card")
    try key(40, modifiers: .command)
    let filter = try field(in: mousePanel)
    try require((filter.currentEditor() as? NSTextView)?.insertionPointColor == OverlayTheme.brandAccent,
                "The card field editor caret must be brandAccent")
    let filterPoint = mouseRoot.convert(NSPoint(x: filter.bounds.midX, y: filter.bounds.midY), from: filter)
    try move(mousePanel, root: mouseRoot, to: filterPoint)
    try require(NSCursor.current == NSCursor.iBeam && mousePanel.firstResponder === filter.currentEditor(), "Movement over the filter must use I-beam and retain typing focus")
    try move(mousePanel, root: mouseRoot, to: NSPoint(x: 10, y: 10))
    try require(NSCursor.current == NSCursor.arrow, "Bands must use the arrow cursor")
    try key(53)
    // A rendered checkbox shows the pointing hand; the same line's text keeps the I-beam.
    guard let taskText = descendants(mouseRoot).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }) else { throw GalleryError("Task text missing") }
    taskText.insertText("- [ ] one\ntwo", replacementRange: NSRange(location: 0, length: 0))
    taskText.setSelectedRange(NSRange(location: (taskText.string as NSString).length, length: 0))
    try await settle()
    mouseRoot.layoutSubtreeIfNeeded()
    guard let taskManager = taskText.layoutManager, let taskContainer = taskText.textContainer else { throw GalleryError("Task layout missing") }
    taskManager.ensureLayout(for: taskContainer)
    let taskGlyph = taskManager.glyphIndexForCharacter(at: 3)
    let taskLine = taskManager.lineFragmentRect(forGlyphAt: taskGlyph, effectiveRange: nil)
    let taskY = taskText.textContainerOrigin.y + taskLine.minY + taskManager.location(forGlyphAt: taskGlyph).y - OverlayTheme.editorFont.capHeight / 2
    try move(mousePanel, root: mouseRoot, to: mouseRoot.convert(NSPoint(x: taskText.textContainerOrigin.x + OverlayTheme.editorCheckboxSize / 2, y: taskY), from: taskText))
    try require(NSCursor.current == NSCursor.pointingHand, "A rendered checkbox must use the pointing hand")
    try move(mousePanel, root: mouseRoot, to: mouseRoot.convert(NSPoint(x: taskText.textContainerOrigin.x + 120, y: taskY), from: taskText))
    try require(NSCursor.current == NSCursor.iBeam, "Task text must keep the I-beam")
    // With the caret on the task line its marker is raw, so the same spot is plain text.
    let checkboxPoint = mouseRoot.convert(NSPoint(x: taskText.textContainerOrigin.x + OverlayTheme.editorCheckboxSize / 2, y: taskY), from: taskText)
    taskText.setSelectedRange(NSRange(location: 3, length: 0))
    try await settle()
    try move(mousePanel, root: mouseRoot, to: checkboxPoint)
    try require(NSCursor.current == NSCursor.iBeam, "A raw task marker must keep the I-beam")
    taskText.setSelectedRange(NSRange(location: (taskText.string as NSString).length, length: 0))
    try await settle()
    try move(mousePanel, root: mouseRoot, to: checkboxPoint)
    try require(NSCursor.current == NSCursor.pointingHand, "Moving the caret off the task line must render the checkbox again")
    // Editing while a card remains attached must resize just as editing without a card does.
    guard let textView = descendants(mouseRoot).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }) else { throw GalleryError("Text missing") }
    let oldNote = OverlayPreview.noteFrame(in: mousePanel)
    try key(40, modifiers: .command)
    textView.insertText(String(repeating: "line\n", count: 10), replacementRange: NSRange(location: 0, length: 0))
    try await settle()
    try require(OverlayPreview.noteFrame(in: mousePanel).height > oldNote.height && OverlayPreview.noteFrame(in: mousePanel).maxY == oldNote.maxY,
                "Text growth with an open card must resize the note with its top fixed")
    try key(53)
    print("Floating-card checks passed (stable note geometry, overflow, shrink, screen cap/change, scroll, hint strip, first mouse, handles, five Actions, hover/click, cursor, caret tint, text growth).")
}

/// Offscreen caching must preserve alpha in the overflow instead of painting a window-sized rectangle.
@MainActor
func checkFloatingCardPixels(_ view: NSView, bitmap: NSBitmapImageRep) throws {
    guard let card = descendants(view).first(where: { ["NoteActionMenuView", "NoteBrowseView"].contains(String(describing: type(of: $0))) }) else { return }
    try checkCardButtonState(in: view, open: String(describing: type(of: card)) == "NoteActionMenuView" ? "Actions" : "Browse notes",
                             context: "Rendered card snapshot")
    let note = OverlayPreview.noteRect(in: view)
    guard view.bounds.height > note.maxY + 12 else { return }
    let scale = OverlayTheme.galleryScale
    let clear = bitmap.colorAt(x: Int(5 * scale), y: Int((note.maxY + 10) * scale))?.alphaComponent ?? 1
    let opaque = bitmap.colorAt(x: Int(card.frame.midX * scale), y: Int((card.frame.maxY - 6) * scale))?.alphaComponent ?? 0
    try require(clear == 0 && opaque == 1, "Card snapshots must have transparent overflow and an opaque card")
}

/// Every laid-out body line, including a trailing caret line, contributes once.
@MainActor
private func checkNoteLineHeights() async throws {
    let editor = NoteEditorPanel()
    editor.present(destination: nil, isPinned: false, draft: "", handlers: NoteEditorHandlers(
        onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
        onBrowse: { _, _ in }, onTogglePin: { false }, onClose: {}, onError: { _ in }))
    defer { editor.dismiss() }
    let panel = try currentPanel()
    guard let root = panel.contentView, let text = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }),
          let manager = text.layoutManager, let container = text.textContainer else { throw GalleryError("Height editor missing") }
    let plain = OverlayPreview.noteEditor(text: "a\nb\nc", selection: NSRange(location: 5, length: 0))
    plain.layoutSubtreeIfNeeded()
    guard let sample = descendants(plain).compactMap({ $0 as? NSTextView }).first, let sampleManager = sample.layoutManager else { throw GalleryError("Body line fixture missing") }
    let lineHeight = sampleManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
    let minimum = CGFloat(OverlayTheme.editorMinLines) * lineHeight
    func set(_ value: String, lines: Int) async throws -> CGFloat {
        text.insertText(value, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        text.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        try await settle()
        root.layoutSubtreeIfNeeded()
        manager.ensureLayout(for: container)
        let expected = max(minimum, CGFloat(lines) * lineHeight)
        let actual = OverlayPreview.textHeight(in: root)
        try require(abs(actual - expected) < 0.01,
                    "Height for \(value.debugDescription): expected \(expected), got \(actual); used \(manager.usedRect(for: container).height), extra \(manager.extraLineFragmentRect.height)")
        try require(abs(OverlayPreview.noteFrame(in: panel).height - OverlayTheme.quickTopBandHeight - OverlayTheme.quickFooterHeight - expected) < 0.01,
                    "The note and text viewport must count each line once")
        try require(abs(text.frame.height - expected) < 0.01, "The text document frame must not double-count the trailing fragment")
        return actual
    }
    var previous: CGFloat = 0
    for (value, lines) in [("", 1), ("Tasks", 1), ("Tasks\n", 2), ("Tasks\n- ", 2), ("Tasks\n- a", 2), ("Tasks\n- a\n", 3), ("Tasks\n- a\n- b", 3)] {
        let height = try await set(value, lines: lines)
        try require(height >= previous, "Typing the Tasks/list sequence must never shrink the note")
        previous = height
    }
    for (value, lines) in [("- [ ] ", 1), ("1. ", 1), ("Tasks\n- [ ] ", 2), ("Tasks\n1. ", 2), ("Tasks\n\n", 3),
                           ("Tasks\n> quote", 2), ("Tasks\n**bold**", 2), ("Tasks\n`code`", 2), ("`one`\n`two`\n`three`", 3)] {
        _ = try await set(value, lines: lines)
    }
    text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
    text.insertText("Tasks", replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
    try await settle()
    try require(OverlayPreview.textHeight(in: root) == minimum, "Deleting back to Tasks must restore the two-line minimum")
    print("Note height checks passed (trailing fragments counted once, monotonic typing, body styling, deletion, document frame).")
}

@MainActor
private func checkCoalescedLongNoteLayout() async throws {
    let editor = NoteEditorPanel()
    let initial = "😀 lead\n" + String(repeating: "tail line\n", count: 2_400) + "# Suffix **bold**\n"
    editor.present(destination: nil, isPinned: false, draft: initial, handlers: NoteEditorHandlers(
        onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
        onBrowse: { _, _ in }, onTogglePin: { false }, onClose: {}, onError: { _ in }))
    let panel = try currentPanel()
    guard let root = panel.contentView,
          let text = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }),
          let manager = text.layoutManager, let container = text.textContainer,
          let scroll = text.enclosingScrollView else { throw GalleryError("Long-note layout editor missing") }
    let originalDocumentHeight = text.frame.height
    let replacement = "a\nb\nc\n**inserted**\n# final\n"
    let firstPlainLine = (text.string as NSString).range(of: "tail line\n")
    text.insertText(replacement, replacementRange: firstPlainLine)
    try await Task.sleep(for: .milliseconds(350))
    let insertedSource = text.string as NSString
    let insertedLabel = insertedSource.range(of: "inserted")
    let insertedHeading = insertedSource.range(of: "# final")
    guard insertedLabel.location != NSNotFound, insertedHeading.location != NSNotFound else {
        throw GalleryError("Multi-line replacement text missing")
    }
    try require(text.textStorage?.attribute(.font, at: insertedLabel.location, effectiveRange: nil) as? NSFont == OverlayTheme.editorStrongFont,
                "A lengthening multi-line replacement must restyle all inserted lines")
    let insertedElement = text.textStorage?.attribute(MarkdownStyler.element, at: insertedHeading.location,
                                                       effectiveRange: nil) as? MarkdownStyler.Element
    try require(insertedElement?.range.location == insertedHeading.location,
                "A lengthening multi-line replacement must keep heading metadata at its UTF-16 offset")

    let insertedBlock = insertedSource.range(of: replacement)
    guard insertedBlock.location != NSNotFound else { throw GalleryError("Multi-line replacement block missing") }
    text.insertText("tail line\n", replacementRange: insertedBlock)
    try await Task.sleep(for: .milliseconds(350))
    let restoredSource = text.string as NSString
    let suffixHeading = restoredSource.range(of: "# Suffix")
    guard suffixHeading.location != NSNotFound else { throw GalleryError("Suffix heading missing after deletion") }
    let suffixElement = text.textStorage?.attribute(MarkdownStyler.element, at: suffixHeading.location,
                                                     effectiveRange: nil) as? MarkdownStyler.Element
    try require(suffixElement?.range.location == suffixHeading.location,
                "A shortening multi-line replacement must rebase following heading metadata")

    let end = (text.string as NSString).length
    text.setSelectedRange(NSRange(location: end, length: 0))
    text.insertText(String(repeating: "tail extension\n", count: 30), replacementRange: text.selectedRange())
    let newEnd = (text.string as NSString).length
    text.setSelectedRange(NSRange(location: newEnd, length: 0))

    // The editor coalesces accurate AppKit layout for up to 250 ms after continued edits.
    try await Task.sleep(for: .milliseconds(350))
    try await settle(until: { text.frame.height > originalDocumentHeight + 100 })
    root.layoutSubtreeIfNeeded()
    manager.ensureLayout(for: container)
    let usedBottom = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY) + text.textContainerOrigin.y
    try require(scroll.hasVerticalScroller, "A 20k+ character quick note must remain scrollable after coalesced layout")
    try require(text.frame.height > originalDocumentHeight + 100,
                "The coalesced layout must extend the document frame to include the appended tail")
    try require(usedBottom <= text.frame.height + 0.5,
                "The accurate AppKit used rect and trailing caret line must fit inside the scroll document")
    guard let beforeScrollCaret = OverlayPreview.layoutCaretRect(in: text) else { throw GalleryError("Long-note tail caret missing") }
    try require(beforeScrollCaret.maxY <= text.frame.height + 0.5, "Tail caret must remain inside the measured document")
    text.scrollRangeToVisible(NSRange(location: newEnd, length: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(30))
    guard let visibleTailCaret = OverlayPreview.layoutCaretRect(in: text) else { throw GalleryError("Visible tail caret missing") }
    try require(text.visibleRect.insetBy(dx: -1, dy: -1).intersects(visibleTailCaret),
                "Scrolling to the end of a long note must make its caret reachable")
    try require(editor.dismiss(), "Long-note panel dismissal failed")

    let closingEditor = NoteEditorPanel()
    closingEditor.present(destination: nil, isPinned: false, draft: "short", handlers: NoteEditorHandlers(
        onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
        onBrowse: { _, _ in }, onTogglePin: { false }, onClose: {}, onError: { _ in }))
    let closingPanel = try currentPanel()
    guard let closingRoot = closingPanel.contentView,
          let closingText = descendants(closingRoot).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }) else {
        throw GalleryError("Pending-measure editor missing")
    }
    closingText.insertText(" " + String(repeating: "wider ", count: 80), replacementRange: closingText.selectedRange())
    try require(closingEditor.dismiss(), "A valid draft must allow panel dismissal with measurement queued")
    let dismissedFrame = closingPanel.frame
    try require(!closingPanel.isVisible && closingPanel.contentView == nil, "Dismissal must release the panel content")
    try await Task.sleep(for: .milliseconds(350))
    try require(closingPanel.frame == dismissedFrame && !closingPanel.isVisible,
                "A delayed measurement must not resize a closed panel")
    print("Coalesced long-note checks passed (tail layout/scroll reachability and no delayed resize after dismissal).")
}

@MainActor
private func checkStickyNotes() async throws {
    let editor = NoteEditorPanel()
    let initial = String(repeating: "line\n", count: 35)
    editor.present(destination: nil, isPinned: false, draft: initial, handlers: NoteEditorHandlers(
        onDraft: { _ in }, onSubmit: { _ in }, onNew: { _ in }, onOpenAsNote: { _ in }, browseItems: { [] },
        onBrowse: { _, _ in }, onTogglePin: { true }, onClose: {}, onError: { _ in }))
    let panel = try currentPanel()
    guard let root = panel.contentView, let text = descendants(root).compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Note text" }),
          let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first(where: { $0.documentView === text }) else { throw GalleryError("Sticky editor missing") }
    try require(panel.isSticky && panel.level == .modalPanel && text.acceptsFirstMouse(for: nil) && root.acceptsFirstMouse(for: nil),
                "Only the note editor opts into stickiness and first-click text/band input")
    let frame = OverlayPreview.noteFrame(in: panel)
    let selection = NSRange(location: 10, length: 0)
    text.setSelectedRange(selection)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
    let scrollOrigin = scroll.contentView.bounds.origin
    for code: UInt16 in [40, 35] {
        editor.focus()
        try key(code, modifiers: .command)
        try checkCardButtonState(in: root, open: code == 40 ? "Actions" : "Browse notes", context: "Card before resign-key")
        panel.resignKey()
        panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        try require(editor.isVisible && OverlayPreview.noteFrame(in: panel) == frame && panel.firstResponder === text,
                    "Key loss closes a card, keeps the note frame, and restores the note first responder")
        try require(!descendants(root).contains { ["NoteActionMenuView", "NoteBrowseView"].contains(String(describing: type(of: $0))) },
                    "Sticky key loss must close both kinds of card")
        try checkCardButtonState(in: root, open: nil, context: "Resign-key closes card")
        editor.focus()
        try require(text.string == initial && text.selectedRange() == selection && scroll.contentView.bounds.origin == scrollOrigin,
                    "Re-focusing must preserve the draft, caret and scroll")
    }
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    try require(editor.isVisible && OverlayPreview.noteFrame(in: panel) == frame, "Sticky notes survive Space changes at the same position")
    let buttons = descendants(root).filter { String(describing: type(of: $0)) == "ChromeButton" }
    try require(buttons.allSatisfy { $0.acceptsFirstMouse(for: nil) }, "Chrome buttons must run on the first click")
    editor.dismiss()
    let input = InputPanelController()
    for space in [false, true] {
        input.present(placeholder: "Input", suggestions: { _ in [] }, onSubmit: { _ in }, onCancel: {})
        let transient = try currentPanel()
        try require(!transient.isSticky, "Input must remain transient")
        if space { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil) }
        else { transient.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: transient)) }
        try require(!input.isVisible, "Input must still dismiss on key loss and Space changes")
    }
    let search = SearchPanelController()
    for space in [false, true] {
        search.present(query: { _ in [] }, actions: SearchActions(primary: { _ in }, open: { _ in }, reveal: { _ in }, onClose: {}))
        let transient = try currentPanel()
        try require(!transient.isSticky, "Search must remain transient")
        if space { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil) }
        else { transient.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: transient)) }
        try require(!search.isVisible, "Search must still dismiss on key loss and Space changes")
    }
    print("Sticky-note checks passed (resign/Space survival, card close, focus/scroll/caret retention, first mouse, transient Input/Search).")
}
