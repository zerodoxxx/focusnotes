import Foundation

enum AppInfo {
    private static var infoDictionary: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    static var name: String {
        infoDictionary["CFBundleDisplayName"] as? String ?? "dev"
    }

    static var bundleIdentifier: String {
        infoDictionary["CFBundleIdentifier"] as? String ?? "dev"
    }
}
