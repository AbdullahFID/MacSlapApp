import Foundation
import Testing
@testable import SlapCore

// Synthetic signals modelled on the on-device captures documented in
// SlapDetector.swift: typing is either low-amplitude/high-jerk (key clicks) or
// higher-amplitude/low-jerk (chassis rocking); slaps are both at once.

/// Deterministic RNG so noise is reproducible across runs.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A decaying sinusoid on one axis, starting at `start` seconds.
struct Impulse {
    var start: TimeInterval
    var amplitude: Double      // g
    var frequency: Double      // Hz
    var decay: TimeInterval    // e-folding time, s
    var axis: Int = 2

    func value(at t: TimeInterval) -> Double {
        let dt = t - start
        guard dt >= 0, dt < decay * 12 else { return 0 }
        return amplitude * exp(-dt / decay) * sin(2 * .pi * frequency * dt)
    }
}

/// Runs a signal through a detector and returns the times of detections.
func detections(
    level: SensitivityLevel,
    rate: Double,
    duration: TimeInterval,
    impulses: [Impulse],
    noise: Double = 0.003,
    detectorRate: Double? = nil
) -> [(time: TimeInterval, event: SlapEvent)] {
    let detector = SlapDetector(config: level.detectorConfig, sampleRate: detectorRate ?? rate)
    var rng = SplitMix64(state: 42)
    func gaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &rng), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    var hits: [(TimeInterval, SlapEvent)] = []
    let count = Int(duration * rate)
    for i in 0..<count {
        let t = Double(i) / rate
        var axes = [0.0, 0.0, -1.0]  // resting flat: gravity on -Z
        for imp in impulses { axes[imp.axis] += imp.value(at: t) }
        for k in 0..<3 { axes[k] += gaussian() * noise }
        if let e = detector.processSample(x: axes[0], y: axes[1], z: axes[2]) {
            hits.append((t, e))
        }
    }
    return hits
}

/// Hard typing: a keystroke every 110 ms alternating the two typing signatures.
func typingImpulses(from start: TimeInterval, until end: TimeInterval) -> [Impulse] {
    var out: [Impulse] = []
    var t = start
    var i = 0
    while t < end {
        if i % 2 == 0 {
            // Chassis rocking: up to 0.12 g but slow (≈ 0.12·2π·18 ≈ 14 g/s).
            out.append(Impulse(start: t, amplitude: 0.12, frequency: 18, decay: 0.03, axis: i % 3))
        } else {
            // Key click: fast but tiny.
            out.append(Impulse(start: t, amplitude: 0.03, frequency: 300, decay: 0.004, axis: 2))
        }
        t += 0.11
        i += 1
    }
    return out
}

@Suite("SlapDetector")
struct SlapDetectorTests {

    @Test("Resting noise never triggers, even at the most sensitive level")
    func restingIsSilent() {
        for level in SensitivityLevel.allCases {
            #expect(detections(level: level, rate: 805, duration: 5, impulses: []).isEmpty,
                    "false positive at \(level)")
        }
    }

    @Test("Hard typing is rejected at every sensitivity level")
    func typingIsRejected() {
        let typing = typingImpulses(from: 1.0, until: 6.0)
        for level in SensitivityLevel.allCases {
            let hits = detections(level: level, rate: 805, duration: 6.5, impulses: typing)
            #expect(hits.isEmpty, "typing triggered \(hits.count)x at \(level)")
        }
    }

    @Test("A medium slap is detected once at medium sensitivity")
    func mediumSlapDetected() {
        let slap = Impulse(start: 1.0, amplitude: 0.7, frequency: 150, decay: 0.01)
        let hits = detections(level: .medium, rate: 805, duration: 2, impulses: [slap])
        #expect(hits.count == 1)
        if let first = hits.first {
            #expect(first.time >= 1.0 && first.time < 1.1, "detected late at \(first.time)s")
        }
    }

    @Test("A hard slap is a major shock with high intensity")
    func hardSlapIsMajor() throws {
        let slap = Impulse(start: 1.0, amplitude: 4.0, frequency: 180, decay: 0.012)
        let hits = detections(level: .veryLow, rate: 805, duration: 2, impulses: [slap])
        #expect(hits.count == 1)
        let event = try #require(hits.first?.event)
        #expect(event.severity == .majorShock)
        #expect(event.intensity > 0.9)
        #expect(event.sources.contains("bigHit"))
    }

    @Test("Harder slaps map to higher intensity")
    func intensityIsMonotonic() throws {
        var last = -1.0
        for amp in [0.5, 0.9, 1.4, 2.5] {
            let slap = Impulse(start: 1.0, amplitude: amp, frequency: 160, decay: 0.01)
            let hits = detections(level: .high, rate: 805, duration: 2, impulses: [slap])
            let event = try #require(hits.first?.event, "no detection at \(amp) g")
            #expect(event.intensity > last, "intensity not increasing at \(amp) g")
            last = event.intensity
        }
    }

    @Test("Long chassis ringing after one slap doesn't retrigger")
    func ringingIsOneEvent() {
        let slap = Impulse(start: 1.0, amplitude: 2.0, frequency: 120, decay: 0.06)
        for level in SensitivityLevel.allCases {
            let hits = detections(level: level, rate: 805, duration: 3, impulses: [slap])
            #expect(hits.count <= 1, "ringing retriggered \(hits.count)x at \(level)")
        }
    }

    @Test("Slaps are still detected while typing")
    func slapDuringTyping() {
        var impulses = typingImpulses(from: 0.5, until: 4.0)
        impulses.append(Impulse(start: 2.03, amplitude: 1.2, frequency: 150, decay: 0.01))
        let hits = detections(level: .medium, rate: 805, duration: 4.5, impulses: impulses)
        #expect(hits.count == 1)
    }

    @Test("Detection works when the sensor runs at 100 Hz")
    func lowRateSensor() {
        // At 100 Hz the IMU's own filtering smears the impulse; model it slower.
        let slap = Impulse(start: 1.0, amplitude: 1.5, frequency: 30, decay: 0.03)
        let hits = detections(level: .medium, rate: 100, duration: 2, impulses: [slap])
        #expect(hits.count == 1)
    }

    @Test("Refractory period is measured in seconds, not samples")
    func refractoryScalesWithRate() {
        // Two slaps 0.4 s apart: both must register at 100 Hz. With sample-count
        // constants tuned for 805 Hz the refractory would last ~1.1 s and eat
        // the second slap.
        let slaps = [
            Impulse(start: 1.0, amplitude: 1.5, frequency: 30, decay: 0.02),
            Impulse(start: 1.4, amplitude: 1.5, frequency: 30, decay: 0.02),
        ]
        let hits = detections(level: .medium, rate: 100, duration: 2.5, impulses: slaps)
        #expect(hits.count == 2)
    }

    @Test("updateSampleRate ignores jitter and out-of-range values")
    func sampleRateUpdates() {
        let d = SlapDetector(config: SensitivityLevel.medium.detectorConfig)
        #expect(d.currentSampleRate == 805)
        d.updateSampleRate(790)          // < 10% change: ignored
        #expect(d.currentSampleRate == 805)
        d.updateSampleRate(.nan)
        d.updateSampleRate(0)
        d.updateSampleRate(1_000_000)
        #expect(d.currentSampleRate == 805)
        d.updateSampleRate(100)
        #expect(d.currentSampleRate == 100)
    }

    @Test("reset() re-arms warmup so a gravity jump isn't read as a slap")
    func resetAfterGap() {
        let d = SlapDetector(config: SensitivityLevel.veryHigh.detectorConfig)
        for _ in 0..<805 { d.processSample(x: 0, y: 0, z: -1) }
        d.reset()
        // Machine picked up and tilted during a sensor gap: gravity moved axes.
        var hits = 0
        for _ in 0..<805 { if d.processSample(x: 0, y: -0.7, z: -0.7) != nil { hits += 1 } }
        #expect(hits == 0)
    }

    @Test("onSlap fires with the same event that processSample returns")
    func callbackMatchesReturn() {
        let d = SlapDetector(config: SensitivityLevel.medium.detectorConfig)
        nonisolated(unsafe) var fromCallback: [Double] = []
        d.onSlap = { fromCallback.append($0.magnitude) }
        let slap = Impulse(start: 0.5, amplitude: 1.0, frequency: 150, decay: 0.01)
        var returned: [Double] = []
        for i in 0..<805 {
            let t = Double(i) / 805
            if let e = d.processSample(x: 0, y: 0, z: -1 + slap.value(at: t)) {
                returned.append(e.magnitude)
            }
        }
        #expect(returned.count == 1)
        #expect(returned == fromCallback)
    }
}
