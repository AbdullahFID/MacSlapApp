import AppKit
import CoreGraphics

/// Screen Recording (TCC) access, needed only by screen shake.
///
/// Since macOS 26.1 only app bundles appear in the Screen Recording list, and
/// on macOS 27 the system sometimes doesn't prompt at all — so after asking
/// once we send people straight to the right Settings pane.
@MainActor
enum ScreenCapturePermission {
    private static var hasRequested = false

    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts the first time; afterwards opens System Settings.
    static func request() {
        if !hasRequested {
            hasRequested = true
            NSApp.activate()
            if CGRequestScreenCaptureAccess() { return }
        }
        openSettings()
    }

    static func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }
}
