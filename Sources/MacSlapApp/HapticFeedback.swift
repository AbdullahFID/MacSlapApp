import AppKit

/// Buzzes the trackpad on impact. Prefers the Taptic Engine actuator (works
/// without a finger on the trackpad) and falls back to NSHapticFeedbackManager.
@MainActor
final class HapticFeedback {
    /// Haptic intensity multiplier (0.0 to 2.0, default 1.0)
    var intensityMultiplier: Double = 1.0

    // Actuation waveforms observed on Force Touch trackpads: 6 is the strongest
    // click, 4 medium, 3 a light tick.
    private enum Waveform: Int32 {
        case strong = 6, medium = 4, light = 3
    }

    private var actuator: CFTypeRef?
    private var actuatorFailed = false

    init() {
        log("Trackpad haptics: \(MultitouchAPI.isAvailable ? "Taptic actuator" : "NSHapticFeedbackManager fallback")")
    }

    func buzz(intensity: Double) {
        let scale = intensity * intensityMultiplier
        let pattern: [(Waveform, TimeInterval)]
        if scale > 0.8 {
            pattern = [(.strong, 0), (.strong, 0.045), (.strong, 0.09)]
        } else if scale > 0.5 {
            pattern = [(.strong, 0), (.medium, 0.05)]
        } else if scale > 0.2 {
            pattern = [(.medium, 0)]
        } else {
            pattern = [(.light, 0)]
        }

        for (waveform, delay) in pattern {
            if delay == 0 {
                fire(waveform)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.fire(waveform)
                }
            }
        }
    }

    private func fire(_ waveform: Waveform) {
        if !actuatorFailed, fireActuator(waveform) { return }
        NSHapticFeedbackManager.defaultPerformer.perform(
            waveform == .light ? .alignment : .generic, performanceTime: .now
        )
    }

    /// Returns false if the actuator is unavailable so the caller can fall back.
    private func fireActuator(_ waveform: Waveform) -> Bool {
        guard let actuate = MultitouchAPI.actuate, let actuator = openActuator() else { return false }
        if actuate(actuator, waveform.rawValue, 0, 0, 2.0) == 0 { return true }

        // The actuator handle goes stale across sleep; reopen once and retry.
        closeActuator()
        guard let reopened = openActuator(), actuate(reopened, waveform.rawValue, 0, 0, 2.0) == 0 else {
            log("Taptic actuator failed — using NSHapticFeedbackManager")
            actuatorFailed = true
            closeActuator()
            return false
        }
        return true
    }

    private func openActuator() -> CFTypeRef? {
        if let actuator { return actuator }
        guard MultitouchAPI.isAvailable,
              let id = MultitouchAPI.builtInTrackpadID(),
              let created = MultitouchAPI.createActuator?(id)?.takeRetainedValue(),
              MultitouchAPI.open?(created) == 0
        else { return nil }
        actuator = created
        return created
    }

    private func closeActuator() {
        if let actuator { _ = MultitouchAPI.close?(actuator) }
        actuator = nil
    }

    func shutdown() {
        closeActuator()
    }
}
