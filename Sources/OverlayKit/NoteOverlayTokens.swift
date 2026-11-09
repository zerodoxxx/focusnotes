import AppKit

/// Metrics and colours for the quick-note cards (Actions and Browse).
public extension OverlayTheme {
    // Shared card surface
    static let cardFill = NSColor(name: NSColor.Name("OverlayKit.cardFill"), dynamicProvider: { appearance in
        let dark = OverlayTheme.isDark(appearance)
        return dark ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1) : NSColor(white: 1, alpha: 1)
    })
    static let cardBorder = NSColor(name: NSColor.Name("OverlayKit.cardBorder"), dynamicProvider: { appearance in
        let dark = OverlayTheme.isDark(appearance)
        return NSColor(white: dark ? 1 : 0, alpha: 0.10)
    })
    static let cardRadius: CGFloat = 12
    static let cardFieldHeight: CGFloat = 36
    static let cardFieldInset: CGFloat = 12
    static let cardFieldFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let cardVerticalPadding: CGFloat = 4
    /// Distance from the panel's right edge and from the band to the open card.
    static let cardEdgeMargin: CGFloat = 8
    static let cardTopGap: CGFloat = 2
    static let menuShadowRadius: CGFloat = 12
    static let menuShadowOpacity: Float = 0.25
    static let menuShadowOffset = CGSize(width: 0, height: -4)
    static let menuSelectedFill = NSColor(name: NSColor.Name("OverlayKit.menuSelectedFill"), dynamicProvider: { _ in
        NSColor.labelColor.withAlphaComponent(0.08)
    })
    static let menuRowInset: CGFloat = 4
    static let menuRowRadius: CGFloat = 6
    static let menuContentInset: CGFloat = 12
    /// Content inset inside a menu row, which itself sits menuRowInset inside the card.
    static let menuRowContentInset: CGFloat = menuContentInset - menuRowInset
    static let menuIconSize: CGFloat = 14
    static let menuIconGap: CGFloat = 8
    static let menuDisabledAlpha: CGFloat = 0.4
    static let menuFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    // Actions card
    static let menuWidth: CGFloat = 280
    static let menuRowHeight: CGFloat = 32
    static let menuGroupMargin: CGFloat = 4
    static let keycapBoxMin: CGFloat = 18
    static let keycapBoxPadding: CGFloat = 5
    static let keycapBoxRadius: CGFloat = 4
    static let keycapBoxGap: CGFloat = 3
    static let keycapBoxBorder = NSColor.labelColor.withAlphaComponent(0.18)
    static let keycapGlyphFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    // Browse card
    static let browseMaxRows = 200
    static let browseCardWidth: CGFloat = 320
    static let browseVisibleRows = 7
    static let browseRowHeight: CGFloat = 40
    static let browseHeaderHeight: CGFloat = 24
    static let browseEmptyHeight: CGFloat = 56
    static let browseFooterHeight: CGFloat = 28
    static let browseFooterInset: CGFloat = 12
    static let browseHeaderFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let browseTitleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let browseIconSize: CGFloat = 14
    static let browsePinSize: CGFloat = 9
    static let browseRowTextInset: CGFloat = 10
    static let browseDetailGap: CGFloat = 2
}
