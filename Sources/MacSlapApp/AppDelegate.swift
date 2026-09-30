import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore?
    private var controller: SlapController?
    private var menuController: MenuController?
    private var updates: UpdateChecker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.isOnlyInstance() else {
            log("Another copy is already running — exiting")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)

        let os = ProcessInfo.processInfo.operatingSystemVersion
        log("\(AppInfo.name) \(AppInfo.version) starting on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            + (AppInfo.isBundled ? "" : " (unbundled dev build)"))

        let settings = SettingsStore()
        self.settings = settings

        if AppInfo.isInstalled {
            migrateFromLegacyInstall(settings)
        }

        let controller = SlapController(settings: settings)
        let updates = UpdateChecker(settings: settings)
        self.controller = controller
        self.updates = updates
        menuController = MenuController(settings: settings, controller: controller, updates: updates)

        controller.start()
        updates.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    /// Replaces the 2.x LaunchAgent with an SMAppService login item, and turns
    /// launch at login on for first-time installs (2.x did this in `make install`).
    private func migrateFromLegacyInstall(_ settings: SettingsStore) {
        let hadLegacyAgent = LegacyInstall.removeLaunchAgent()
        LegacyInstall.terminateLegacyProcesses()

        if !settings.loginItemConfigured {
            settings.loginItemConfigured = true
            if hadLegacyAgent || !LoginItem.isEnabled {
                LoginItem.setEnabled(true)
            }
        }
    }
}
