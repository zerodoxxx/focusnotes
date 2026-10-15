import AppKit
import Foundation
import os
import Sparkle

/// Owns Sparkle's standard updater. Dormant (no controller, no menu item) when the
/// bundle has no SUFeedURL or SUPublicEDKey, which is the case for dev builds.
@MainActor
final class AppUpdater {
    private static let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "updates")

    private let updaterController: SPUStandardUpdaterController?
    let menuItem: NSMenuItem?

    init() {
        guard Self.infoString(forKey: "SUFeedURL") != nil,
              Self.infoString(forKey: "SUPublicEDKey") != nil else {
            Self.logger.info("updates disabled: no feed or key")
            updaterController = nil
            menuItem = nil
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = controller
        updaterController = controller
        menuItem = item
    }

    private static func infoString(forKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
