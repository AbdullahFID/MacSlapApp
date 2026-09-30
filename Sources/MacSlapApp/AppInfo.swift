import Foundation

enum AppInfo {
    static let name = "MacSlapApp"
    static let bundleIdentifier = "app.macslap.MacSlapApp"
    static let githubRepo = "AbdullahFID/MacSlapApp"
    static let repoURL = URL(string: "https://github.com/\(githubRepo)")!
    static let releasesURL = URL(string: "https://github.com/\(githubRepo)/releases")!
    static let websiteURL = URL(string: "https://macslap.app")!

    /// "dev" when running a bare `swift build` binary.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Login items, Screen Recording permission and update checks all need a real .app bundle.
    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// Running from /Applications or ~/Applications rather than a build folder.
    /// One-time install work (login item, 2.x cleanup) only happens here so a
    /// dev build in dist/ never registers itself as the login item.
    static var isInstalled: Bool {
        guard isBundled else { return false }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").standardizedFileURL.path
        return parent == "/Applications" || parent == userApps
    }
}
