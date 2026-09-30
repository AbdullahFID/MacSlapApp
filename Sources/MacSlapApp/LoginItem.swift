import AppKit
import ServiceManagement

/// Launch at login via SMAppService (shows up under System Settings > General >
/// Login Items). Requires running from an .app bundle.
@MainActor
enum LoginItem {
    static var isSupported: Bool { AppInfo.isBundled }

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isSupported else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            log("Launch at login \(enabled ? "enabled" : "disabled") (status: \(describe(status)))")
            return true
        } catch {
            log("Launch at login change failed: \(error.localizedDescription) (status: \(describe(status)))")
            return false
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}

/// Cleans up after 2.x, which ran a bare binary from a LaunchAgent. Left alone,
/// the old agent would start a second copy at login and both would scream.
@MainActor
enum LegacyInstall {
    static let agentLabel = "com.slapmacpro"
    static let agentPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    private static let legacyExecutableNames: Set<String> = ["SlapMacPro", "SlapMacClone"]

    /// Unloads and deletes the 2.x LaunchAgent. Returns true if one existed,
    /// meaning the user had launch at login turned on.
    static func removeLaunchAgent() -> Bool {
        guard FileManager.default.fileExists(atPath: agentPlist.path) else { return false }

        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
        launchctl.standardOutput = FileHandle.nullDevice
        launchctl.standardError = FileHandle.nullDevice
        do {
            try launchctl.run()
            launchctl.waitUntilExit()
        } catch {
            log("launchctl bootout failed to run: \(error.localizedDescription)")
        }

        do {
            try FileManager.default.removeItem(at: agentPlist)
            log("Removed legacy LaunchAgent \(agentPlist.path)")
        } catch {
            log("Couldn't remove legacy LaunchAgent: \(error.localizedDescription)")
        }
        return true
    }

    /// Quits any 2.x binary that is still running (started by hand, not launchd).
    static func terminateLegacyProcesses() {
        let me = NSRunningApplication.current
        for app in NSWorkspace.shared.runningApplications where app != me {
            guard let name = app.executableURL?.lastPathComponent, legacyExecutableNames.contains(name) else {
                continue
            }
            log("Quitting legacy \(name) (pid \(app.processIdentifier))")
            if !app.terminate() { app.forceTerminate() }
        }
    }
}

enum SingleInstance {
    /// False if another copy of this bundle is already running.
    @MainActor
    static func isOnlyInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0 != NSRunningApplication.current && !$0.isTerminated }
        return others.isEmpty
    }
}
