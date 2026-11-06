import AppKit
import QuartzCore

/// The single source of visual metrics, colors, typography, symbols, and motion.
@MainActor
public enum OverlayTheme {
    public static let material: NSVisualEffectView.Material = .popover
    public static let blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// Dynamic colour providers run off the main actor, so this helper must not inherit isolation.
    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    public static let effectState: NSVisualEffectView.State = .active
    public static let panelRadius: CGFloat = 14
    public static let quickPanelRadius: CGFloat = 16
    public static let toastRadius: CGFloat = 12
    public static let borderWidth: CGFloat = 0.5
    public static let surfaceTint = NSColor(name: NSColor.Name("OverlayKit.surfaceTint"), dynamicProvider: { appearance in
        let dark = OverlayTheme.isDark(appearance)
        return NSColor(srgbRed: dark ? 0.086 : 0.984, green: dark ? 0.086 : 0.984, blue: dark ? 0.086 : 0.984, alpha: 0.97)
    })
    public static let surfaceBorder = NSColor(name: NSColor.Name("OverlayKit.surfaceBorder"), dynamicProvider: { appearance in
        let dark = OverlayTheme.isDark(appearance)
        return NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.10)
    })
    public static let borderColor = NSColor.separatorColor
    public static let brandAccent = NSColor(name: NSColor.Name("OverlayKit.brandAccent"), dynamicProvider: { appearance in
        let dark = OverlayTheme.isDark(appearance)
        return dark ? NSColor(srgbRed: 1.0, green: 0.420, blue: 0.373, alpha: 1)
                    : NSColor(srgbRed: 0.898, green: 0.282, blue: 0.235, alpha: 1)
    })
    public static let windowShadow = true
    public static let windowBackground = NSColor.clear
    public static let inputFont = NSFont.systemFont(ofSize: 22, weight: .regular)
    public static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    public static let snippetFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    public static let matchedSnippetFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    public static let metaFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    public static let toastTitleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    public static let toastSubtitleFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    public static let hintFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    public static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    public static let messageFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    public static let textColor = NSColor.labelColor
    public static let secondaryColor = NSColor.secondaryLabelColor
    public static let tertiaryColor = NSColor.tertiaryLabelColor
    public static let hintFill = NSColor.quaternaryLabelColor
    public static let selectedFill = NSColor.selectedContentBackgroundColor
    public static let selectedText = NSColor.alternateSelectedControlTextColor
    public static let selectedSecondary = selectedText.withAlphaComponent(0.85)
    public static let hintPadding: CGFloat = 4
    public static let hintRadius: CGFloat = 4
    public static let hintHeight: CGFloat = 18
    public static let hintLabelGap: CGFloat = 4
    public static let headerTracking: CGFloat = 0.5
    public static let padding: CGFloat = 12
    public static let searchFieldHeight: CGFloat = 52
    public static let inputFieldHeight: CGFloat = 44
    public static let resultHeight: CGFloat = 52
    public static let suggestionHeight: CGFloat = 30
    public static let rowInset: CGFloat = 6
    public static let selectedRadius: CGFloat = 8
    public static let iconGap: CGFloat = 10
    public static let searchWidth: CGFloat = 640
    public static let inputWidth: CGFloat = 480
    public static let editorFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    public static let editorStrongFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    public static let editorCodeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    public static let editorHeadingFonts = [22.0, 19.0, 17.0, 15.0].map { NSFont.systemFont(ofSize: $0, weight: .semibold) }
    public static let editorLineHeightMultiple: CGFloat = 1.25
    public static let editorMinLines = 2
    public static let quickTopBandHeight: CGFloat = 38
    public static let quickFooterHeight: CGFloat = 38
    public static let quickTextInset: CGFloat = 20
    public static let quickButtonSize: CGFloat = 26
    public static let quickSymbolSize: CGFloat = 13
    public static let quickButtonGap: CGFloat = 2
    public static let quickChromeEdgeInset: CGFloat = 10
    public static let quickClusterHeight: CGFloat = 28
    public static let quickClusterRadius: CGFloat = 14
    public static let quickClusterPadding: CGFloat = 1
    public static let quickClusterFill = NSColor(name: NSColor.Name("OverlayKit.quickClusterFill"), dynamicProvider: { appearance in
        let dark = OverlayTheme.isDark(appearance)
        return NSColor(white: dark ? 1 : 0, alpha: dark ? 0.06 : 0.04)
    })
    public static let quickClusterBorder = NSColor(name: NSColor.Name("OverlayKit.quickClusterBorder"), dynamicProvider: { appearance in
        let dark = OverlayTheme.isDark(appearance)
        return NSColor(white: dark ? 1 : 0, alpha: 0.08)
    })
    public static let quickTitlePinSize: CGFloat = 10
    public static let quickTitlePinGap: CGFloat = 4
    public static let quickTitleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    public static let quickTitleRestAlpha: CGFloat = 0.30
    public static let quickTitleRevealAlpha: CGFloat = 0.60
    public static let quickTitleClusterGap: CGFloat = 12
    public nonisolated static let quickTitleLimit = 60
    public static let quickEmptyTitle = "New note"
    public static let quickFooterLeadingInset: CGFloat = 16
    public static let quickRevealIn: TimeInterval = 0.15
    public static let quickRevealOut: TimeInterval = 0.20
    public static let quickMinWidth: CGFloat = 400
    public static let quickMaxWidth: CGFloat = 600
    public static let quickMaxHeight: CGFloat = 680
    public static let quickMaxHeightFraction: CGFloat = 0.60
    public static let quickIndentAllowance: CGFloat = 24
    public static let quickMeasuredParagraphs = 300
    public static let quickButtonHoverFill = NSColor.labelColor.withAlphaComponent(0.08)
    public static let quickButtonPressedFill = NSColor.labelColor.withAlphaComponent(0.14)
    public static let editorHeadingColor = NSColor.labelColor
    public static let editorQuoteIndent: CGFloat = 8
    public static let editorBullet = "•"
    public static let editorBulletFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    public static let editorQuoteBarWidth: CGFloat = 3
    public static let editorQuoteBarInset: CGFloat = 2
    public static let editorCheckboxSize: CGFloat = 13
    public static let editorCheckboxRadius: CGFloat = 3.5
    public static let editorCheckboxStroke: CGFloat = 1.5
    public static let editorCheckboxGap: CGFloat = 6
    public static let editorCheckboxFill = brandAccent
    public static let editorCheckboxStrokeColor = brandAccent
    public static let editorCheckboxCheckColor = NSColor.white
    public static let editorCheckboxCheckPoints = [NSPoint(x: 0.25, y: 0.5), NSPoint(x: 0.43, y: 0.7), NSPoint(x: 0.76, y: 0.3)]
    public static let editorTextInset = NSSize.zero
    public static let codeBackground = NSColor(name: NSColor.Name("OverlayKit.codeBackground"), dynamicProvider: { appearance in
        let dark = OverlayTheme.isDark(appearance)
        return NSColor(white: dark ? 1 : 0, alpha: dark ? 0.09 : 0.05)
    })
    public static let codeBlockRadius: CGFloat = 4
    public static let codeBlockInset: CGFloat = 6
    public static let inlineCodePadding: CGFloat = 3
    public static let inlineCodeRadius: CGFloat = 3
    public static let editorInsertionColor = brandAccent
    public static let editorCaretWidth: CGFloat = 2
    public static let editorCaretRadius: CGFloat = 1
    public static let editorCaretHeightFactor: CGFloat = 1.1
    public static let editorCaretDescentFactor: CGFloat = 0.22
    public static let editorLinkColor = NSColor.linkColor
    public static let separatorColor = NSColor.separatorColor
    public static let editorRestyleLimit = 20_000
    public static let maxResults = 8
    public static let maxSuggestions = 6
    public static let toastMinWidth: CGFloat = 240
    public static let toastMaxWidth: CGFloat = 380
    public static let toastHeight: CGFloat = 56
    public static let panelTopFraction: CGFloat = 0.22
    public static let toastBottomOffset: CGFloat = 72
    public static let panelAppear: TimeInterval = 0.14
    public static let panelDisappear: TimeInterval = 0.10
    public static let panelScale: CGFloat = 0.98
    public static let toastAppear: TimeInterval = 0.16
    public static let toastDisappear: TimeInterval = 0.20
    public static let toastTravel: CGFloat = 6
    public static let resizeDuration: TimeInterval = 0.12
    public static let easeOut = CAMediaTimingFunction(name: .easeOut)
    public static let easeIn = CAMediaTimingFunction(name: .easeIn)
    public static let iconSize: CGFloat = 18
    public static let thumbnailSize: CGFloat = 36
    public static let thumbnailRadius: CGFloat = 6
    public static let titleLineHeight: CGFloat = 16
    public static let snippetLineHeight: CGFloat = 14
    public static let metaLineHeight: CGFloat = 13
    public static let toastLineGap: CGFloat = 2
    public static let headerHeight: CGFloat = 24
    public static let noResultsHeight: CGFloat = 80
    public static let footerHeight: CGFloat = 28
    public static let spinnerSize: CGFloat = 16
    public static let spinnerControlSize: NSControl.ControlSize = .small
    public static let searchSymbol = "magnifyingglass"
    public static let textSymbol = "text.alignleft"
    public static let noteSymbol = "doc.text"
    public static let successSymbol = "checkmark.circle.fill"
    public static let warningSymbol = "exclamationmark.triangle.fill"
    public static let sessionSymbol = "record.circle"
    public static let copiedSymbol = "doc.on.doc.fill"
    public static let successColor = brandAccent
    public static let warningColor = NSColor.systemOrange
    public static let sessionColor = NSColor.systemRed
    public static let copiedColor = NSColor.controlAccentColor
    public nonisolated static let defaultToastDuration: TimeInterval = 2
    public nonisolated static let warningToastDuration: TimeInterval = 3
    public static let queryDebounce: Duration = .milliseconds(60)
    public static let loadingDelay: Duration = .milliseconds(150)
    public static let galleryScale: CGFloat = 2
    static let footerHintGap: CGFloat = 16
    static let suggestionTitleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let suggestionIconSize: CGFloat = 16
    static let suggestionLeadingWidth: CGFloat = 20
    static let suggestionIconGap: CGFloat = 8
    static let suggestionTrailingInset: CGFloat = 12
    static let motionFrameInterval: Duration = .milliseconds(16)
    public static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
