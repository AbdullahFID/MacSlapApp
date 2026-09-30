import AppKit
import SlapCore

/// Checks GitHub Releases for a newer version once a day and surfaces it in the menu.
@MainActor
final class UpdateChecker {
    struct Release {
        let version: String
        let url: URL
    }

    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let apiURL = URL(string: "https://api.github.com/repos/\(AppInfo.githubRepo)/releases/latest")!

    private let settings: SettingsStore
    private var timer: Timer?
    private(set) var available: Release?
    private(set) var isChecking = false

    var onChange: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Dev builds have no version to compare, so they never check.
    var isEnabled: Bool { AppInfo.isBundled && VersionComparison.components(AppInfo.version) != nil }

    func start() {
        guard isEnabled else { return }
        // Delay the first check so it never competes with launch.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIfDue()
                self?.timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkIfDue() }
                }
            }
        }
    }

    private func checkIfDue() {
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard isEnabled, !isChecking else {
            if userInitiated && !isEnabled {
                showAlert(title: "Updates are checked in release builds",
                          message: "This copy was built from source (version \(AppInfo.version)).")
            }
            return
        }
        isChecking = true
        defer { isChecking = false }

        let result = await fetchLatest()
        settings.lastUpdateCheck = Date()

        switch result {
        case .success(let release):
            let newer = VersionComparison.isNewer(release.version, than: AppInfo.version)
            available = newer ? release : nil
            onChange?()
            log("Update check: latest \(release.version), running \(AppInfo.version)\(newer ? " — update available" : "")")
            if userInitiated {
                if newer {
                    promptToDownload(release)
                } else {
                    showAlert(title: "You're up to date",
                              message: "\(AppInfo.name) \(AppInfo.version) is the latest version.")
                }
            }
        case .failure(let error):
            log("Update check failed: \(error.localizedDescription)")
            if userInitiated {
                showAlert(title: "Couldn't check for updates", message: error.localizedDescription)
            }
        }
    }

    private func fetchLatest() async -> Result<Release, Error> {
        var request = URLRequest(url: Self.apiURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse, userInfo: [
                    NSLocalizedDescriptionKey: "GitHub returned HTTP \(http.statusCode).",
                ])
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return .success(Release(version: payload.tag_name, url: payload.html_url))
        } catch {
            return .failure(error)
        }
    }

    func promptToDownload(_ release: Release) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(AppInfo.name) \(release.version) is available"
        alert.informativeText = "You're running \(AppInfo.version). Download the new version from GitHub?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.url)
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
