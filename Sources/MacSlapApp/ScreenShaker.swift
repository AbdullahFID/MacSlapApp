import AppKit
import QuartzCore
import ScreenCaptureKit

/// Shakes the screen on impact: captures every display with ScreenCaptureKit,
/// covers each one with a borderless window showing the capture, and jiggles
/// those windows with a Core Animation keyframe animation.
///
/// Needs Screen Recording permission. Without it the capture would contain only
/// the wallpaper, so the effect is skipped instead of flashing a blank desktop.
@MainActor
final class ScreenShaker {
    /// Shake intensity multiplier (0.0 to 2.0, default 1.0)
    var intensityMultiplier: Double = 1.0

    private var isShaking = false
    private var cachedContent: SCShareableContent?
    private var cachedAt: Date = .distantPast
    private static let contentCacheLifetime: TimeInterval = 30

    func shake(intensity: Double) {
        guard !isShaking else { return }
        guard ScreenCapturePermission.isGranted else {
            log("Screen shake skipped: Screen Recording permission not granted")
            return
        }
        isShaking = true

        let scale = intensity * intensityMultiplier
        Task { @MainActor in
            defer { isShaking = false }
            let captures = await captureDisplays()
            guard !captures.isEmpty else { return }
            await animate(captures, scale: scale)
        }
    }

    // MARK: - Capture

    private func shareableContent() async throws -> SCShareableContent {
        if let cachedContent, Date().timeIntervalSince(cachedAt) < Self.contentCacheLifetime {
            return cachedContent
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = content
        cachedAt = Date()
        return content
    }

    private func captureDisplays() async -> [(NSScreen, CGImage)] {
        let content: SCShareableContent
        do {
            content = try await shareableContent()
        } catch {
            log("Screen shake capture unavailable: \(error.localizedDescription)")
            cachedContent = nil
            return []
        }

        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var results: [(NSScreen, CGImage)] = []

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value })
            else { continue }

            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best

            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                results.append((screen, image))
            } catch {
                log("Screen shake capture failed for display \(display.displayID): \(error.localizedDescription)")
                // Displays may have changed since the cached content was fetched.
                cachedContent = nil
            }
        }
        return results
    }

    // MARK: - Animation

    private func animate(_ captures: [(NSScreen, CGImage)], scale: Double) async {
        let maxOffset = 6.0 + scale * 20.0
        let shakeCount = 5 + Int(scale * 7)
        let frameDuration = 0.018

        // Alternating, decaying offsets — same motion as 2.x, now GPU-driven.
        var offsets: [NSValue] = []
        for i in 0..<shakeCount {
            let decay = 1.0 - Double(i) / Double(shakeCount)
            let dx = maxOffset * decay * (i.isMultiple(of: 2) ? 1 : -1)
            let dy = maxOffset * decay * 0.35 * cos(Double(i) * .pi * 1.4)
            offsets.append(NSValue(point: NSPoint(x: dx, y: dy)))
        }
        offsets.append(NSValue(point: .zero))
        let duration = frameDuration * Double(offsets.count)

        var windows: [NSWindow] = []
        for (screen, image) in captures {
            let window = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.sharingType = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            container.wantsLayer = true
            let imageLayer = CALayer()
            imageLayer.frame = container.bounds
            imageLayer.contents = image
            imageLayer.contentsGravity = .resize
            container.layer?.addSublayer(imageLayer)
            window.contentView = container
            window.orderFrontRegardless()

            let animation = CAKeyframeAnimation(keyPath: "position")
            let base = imageLayer.position
            animation.values = offsets.map {
                let p = $0.pointValue
                return NSValue(point: NSPoint(x: base.x + p.x, y: base.y + p.y))
            }
            animation.duration = duration
            animation.calculationMode = .linear
            imageLayer.add(animation, forKey: "shake")
            windows.append(window)
        }

        try? await Task.sleep(for: .seconds(duration))
        for window in windows { window.orderOut(nil) }
    }
}
