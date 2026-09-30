import AppKit

/// Flashes the screen with a translucent white overlay on impact.
@MainActor
final class ScreenFlash {
    /// Flash intensity multiplier (0.0 to 2.0, default 1.0)
    var intensityMultiplier: Double = 1.0

    private var flashWindows: [NSWindow] = []

    func flash(intensity: Double) {
        let scale = min(intensity * intensityMultiplier, 2.0)

        for screen in NSScreen.screens {
            let window = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.backgroundColor = NSColor.white.withAlphaComponent(CGFloat(scale) * 0.5)
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.sharingType = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.orderFrontRegardless()
            flashWindows.append(window)

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15 + (scale * 0.25)
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak window] in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    window.orderOut(nil)
                    self?.flashWindows.removeAll { $0 === window }
                }
            })
        }
    }
}
