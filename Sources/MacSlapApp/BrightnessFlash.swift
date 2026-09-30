import Foundation
import CoreGraphics

/// Flashes the built-in display's backlight using the DisplayServices private API.
/// Adaptive: if brightness is already high, flashes DOWN (dim). If low, flashes UP.
/// Always noticeable regardless of current brightness level.
@MainActor
final class BrightnessFlash {
    /// Flash intensity multiplier (0.0 to 2.0, default 1.0)
    var intensityMultiplier: Double = 1.0

    private var isFlashing = false
    private let queue = DispatchQueue(label: "app.macslap.brightness", qos: .userInteractive)

    var isAvailable: Bool {
        DisplayServicesAPI.getBrightness != nil && DisplayServicesAPI.setBrightness != nil
            && DisplayServicesAPI.builtInDisplay() != nil
    }

    func flash(intensity: Double) {
        guard !isFlashing,
              let getBr = DisplayServicesAPI.getBrightness,
              let setBr = DisplayServicesAPI.setBrightness,
              let displayID = DisplayServicesAPI.builtInDisplay()
        else { return }

        var original: Float = 0
        guard getBr(displayID, &original) == 0 else { return }
        isFlashing = true

        let scale = Float(intensity * intensityMultiplier)
        let target: Float
        if original > 0.5 {
            // Dim flash: drop by 30-70% of current
            target = max(original - (0.3 + scale * 0.4) * original, 0.05)
        } else {
            // Bright flash: spike up
            target = min(original + 0.2 + scale * 0.5, 1.0)
        }

        queue.async { [weak self] in
            _ = setBr(displayID, target)
            usleep(60_000) // hold the flash

            let steps = 12
            for i in 1...steps {
                let t = Float(i) / Float(steps)
                let eased = 1.0 - pow(1.0 - t, 2.5) // ease-out
                _ = setBr(displayID, target + (original - target) * eased)
                usleep(22_000) // ~264ms total fade
            }
            _ = setBr(displayID, original)

            DispatchQueue.main.async { self?.isFlashing = false }
        }
    }
}
