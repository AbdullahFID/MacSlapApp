import Foundation

/// A local acoustic onset heuristic. It cannot distinguish every clap or key
/// click from a chassis tap. Feed peak/RMS for short (roughly 10–25 ms) windows.
/// All state belongs to the caller's serial queue.
public struct MicrophoneTapDetector {
    public var sensitivity: SensitivityLevel = .medium
    private var noise = 0.002
    private var previousRMS = 0.002
    private var elapsed = 0.0
    private var lastHit = -Double.infinity

    public init() {}

    public mutating func process(peak: Double, rms: Double, duration: Double,
                                 suppressed: Bool = false) -> Double? {
        guard peak.isFinite, rms.isFinite, duration.isFinite,
              duration > 0, duration <= 0.25, peak >= 0, rms >= 0 else { return nil }
        elapsed += duration
        defer { previousRMS = rms }
        if suppressed {
            // Do not teach the background tracker our own voice/effects,
            // including during startup calibration.
            lastHit = elapsed
            return nil
        }
        // Calibrate to the room before accepting any onsets.
        if elapsed < 0.6 {
            noise += min(1, duration / 0.15) * (rms - noise)
            return nil
        }
        let threshold: Double
        switch sensitivity {
        case .veryHigh: threshold = 0.035
        case .high: threshold = 0.055
        case .medium: threshold = 0.085
        case .low: threshold = 0.14
        case .veryLow: threshold = 0.22
        }
        let onset = rms > max(noise * 3.5, previousRMS * 2.5)
        let transient = peak > max(rms * 2.0, noise * 8)
        let hit = peak >= threshold && onset && transient
        if !hit {
            // Slow upwards adaptation keeps one loud frame from hiding a tap.
            let timeConstant = rms > noise ? 2.0 : 0.4
            noise += min(1, duration / timeConstant) * (rms - noise)
        }
        guard hit, elapsed - lastHit >= 0.35 else { return nil }
        lastHit = elapsed
        return min(1, max(0.1, log(1 + peak * 40) / log(41)))
    }
}
