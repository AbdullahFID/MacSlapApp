import Foundation

// MARK: - Configuration
//
// Impact detector tuned from real on-device captures (Mac17,2 / M5):
//   • hard typing tops out around   linMag ≤ 0.12 g  with jerk ≤ ~18 g/s,
//     and crucially its high-amplitude moments have LOW jerk (the chassis
//     rocking), while its high-jerk moments have LOW amplitude. They never
//     co-occur.
//   • a real slap produces HIGH amplitude AND HIGH jerk in the same instant
//     (medium ~0.5–0.7 g @ 40+ g/s, hard 2–5 g @ 100–940 g/s).
//
// So the detector fires on  (linMag ≥ ampThreshold AND jerk ≥ jerkThreshold)
// OR an unambiguous big hit (linMag ≥ hardAmpThreshold), with an adaptive
// noise floor, a short peak-hold to capture true peak force, and a refractory
// period so one slap's ringing can't retrigger.
//
// Every window is expressed in seconds and converted using the measured sample
// rate. The IMU normally streams at ~805 Hz once woken, but it has been seen
// idling at ~100 Hz on some machines; sample-count constants tuned at 805 Hz
// would stretch 8× in time there (a 0.14 s refractory becoming 1.1 s).

public struct DetectorConfig: Sendable, Equatable {
    /// Peak linear-acceleration (gravity removed) to qualify as a slap, in g.
    public var ampThreshold: Double
    /// Jerk "performance index" = Σ|d(accel)/dt| across axes, in g/s.
    public var jerkThreshold: Double
    /// Amplitude so high we accept it even without the jerk test, in g.
    public var hardAmpThreshold: Double

    /// Adaptive floor: linMag must also exceed noiseFloor + sigmaMult·noiseDev.
    public var sigmaMult: Double = 7.0
    /// Gravity low-pass time constant.
    public var gravityTimeConstant: TimeInterval = 0.5
    /// Noise-floor tracker time constant.
    public var noiseTimeConstant: TimeInterval = 1.25
    /// Settling time before any detection (gravity estimate converges).
    public var warmup: TimeInterval = 0.3
    /// Ignore window after a detection so chassis ringing can't retrigger.
    public var refractory: TimeInterval = 0.14
    /// Peak-hold window to capture the true peak force of an impact.
    public var impactWindow: TimeInterval = 0.05

    /// Force→volume mapping (absolute, so volume reflects actual force,
    /// independent of the sensitivity setting).
    public var intensityLowG: Double = 0.15
    public var intensityHighG: Double = 1.8

    public init(ampThreshold: Double, jerkThreshold: Double, hardAmpThreshold: Double) {
        self.ampThreshold = ampThreshold
        self.jerkThreshold = jerkThreshold
        self.hardAmpThreshold = hardAmpThreshold
    }
}

// MARK: - Event

public enum SlapSeverity: String, Sendable {
    case majorShock = "MAJOR_SHOCK"     // peak ≥ 1.0 g
    case mediumShock = "MEDIUM_SHOCK"   // peak ≥ 0.4 g
    case microShock = "MICRO_SHOCK"     // below that, but still a real impact
}

public struct SlapEvent: Sendable {
    public let magnitude: Double      // peak linear-accel of the impact, in g
    public let intensity: Double      // 0..1 for volume scaling
    public let severity: SlapSeverity
    public let sources: Set<String>   // which gates fired (impact/jerk/bigHit)
    public let timestamp: Date

    public init(magnitude: Double, intensity: Double, severity: SlapSeverity,
                sources: Set<String>, timestamp: Date = Date()) {
        self.magnitude = magnitude
        self.intensity = intensity
        self.severity = severity
        self.sources = sources
        self.timestamp = timestamp
    }
}

// MARK: - Impact Detector

/// Single-pass impact detector. Gravity is removed with a slow EMA; we then
/// gate on simultaneous high amplitude + high jerk (the empirically clean
/// separator between slaps and typing), refine the peak with a short hold,
/// and enforce a refractory period.
///
/// Thread-safe: samples arrive on the sensor thread while configuration
/// changes come from the main thread.
public final class SlapDetector: @unchecked Sendable {
    public static let defaultSampleRate = 805.0
    /// Rates outside this range are treated as measurement glitches.
    public static let sampleRateRange = 25.0...4000.0

    private var config: DetectorConfig
    private var sampleRate: Double

    // Derived from config + sampleRate; see recomputeDerived().
    private var gravityAlpha = 0.0
    private var noiseAlpha = 0.0
    private var warmupSamples = 0
    private var refractorySamples = 0
    private var impactWindowSamples = 1

    // Gravity estimate (per axis) and previous linear sample for jerk.
    private var gx = 0.0, gy = 0.0, gz = 0.0
    private var gravInit = false
    private var prevLx = 0.0, prevLy = 0.0, prevLz = 0.0
    private var havePrev = false

    // Adaptive baseline noise floor.
    private var noiseFloor = 0.0
    private var noiseDev = 0.0
    private var noiseInit = false

    // Impact state machine.
    private enum State { case idle, inImpact }
    private var state: State = .idle
    private var peakAmp = 0.0
    private var peakJerk = 0.0
    private var impactSamples = 0
    private var refractoryCount = 0
    private var warmupCount = 0

    private let lock = NSLock()

    /// Invoked on the thread that called `processSample`, outside the lock.
    public var onSlap: (@Sendable (SlapEvent) -> Void)?

    public init(config: DetectorConfig, sampleRate: Double = SlapDetector.defaultSampleRate) {
        self.config = config
        self.sampleRate = SlapDetector.clampRate(sampleRate)
        recomputeDerived()
    }

    public var currentSampleRate: Double {
        lock.lock(); defer { lock.unlock() }
        return sampleRate
    }

    public func updateConfig(_ newConfig: DetectorConfig) {
        lock.lock(); defer { lock.unlock() }
        config = newConfig
        recomputeDerived()
        state = .idle
        refractoryCount = 0
    }

    /// Adopts a newly measured sample rate. Changes under 10% are ignored so
    /// normal jitter in the measurement doesn't churn the filter constants.
    public func updateSampleRate(_ hz: Double) {
        guard hz.isFinite, SlapDetector.sampleRateRange.contains(hz) else { return }
        lock.lock(); defer { lock.unlock() }
        guard abs(hz - sampleRate) / sampleRate >= 0.10 else { return }
        sampleRate = hz
        recomputeDerived()
    }

    /// Forgets all filter state. Call after the sensor restarts so a stale
    /// gravity estimate from before the gap can't read as an impact.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        gravInit = false
        havePrev = false
        noiseInit = false
        state = .idle
        refractoryCount = 0
        warmupCount = 0
    }

    /// Feeds one accelerometer sample (in g). Returns the event if this sample
    /// completed an impact; `onSlap` is also invoked in that case.
    @discardableResult
    public func processSample(x: Double, y: Double, z: Double) -> SlapEvent? {
        lock.lock()
        let event = step(x: x, y: y, z: z)
        let callback = onSlap
        lock.unlock()
        if let event { callback?(event) }
        return event
    }

    // MARK: - Internals (caller holds lock)

    private static func clampRate(_ hz: Double) -> Double {
        guard hz.isFinite else { return defaultSampleRate }
        return min(max(hz, sampleRateRange.lowerBound), sampleRateRange.upperBound)
    }

    private func recomputeDerived() {
        let dt = 1.0 / sampleRate
        gravityAlpha = exp(-dt / config.gravityTimeConstant)
        noiseAlpha = exp(-dt / config.noiseTimeConstant)
        warmupSamples = Int((config.warmup * sampleRate).rounded())
        refractorySamples = Int((config.refractory * sampleRate).rounded())
        impactWindowSamples = max(1, Int((config.impactWindow * sampleRate).rounded()))
    }

    private func step(x: Double, y: Double, z: Double) -> SlapEvent? {
        // 1) Track gravity, derive linear acceleration + magnitude.
        if !gravInit { gx = x; gy = y; gz = z; gravInit = true }
        let a = gravityAlpha
        gx = a * gx + (1 - a) * x
        gy = a * gy + (1 - a) * y
        gz = a * gz + (1 - a) * z
        let lx = x - gx, ly = y - gy, lz = z - gz
        let linMag = (lx * lx + ly * ly + lz * lz).squareRoot()

        // 2) Jerk performance index (Σ|Δaccel|·rate across axes).
        var jerk = 0.0
        if havePrev {
            jerk = (abs(lx - prevLx) + abs(ly - prevLy) + abs(lz - prevLz)) * sampleRate
        }
        prevLx = lx; prevLy = ly; prevLz = lz; havePrev = true

        // 3) Warm up so the gravity estimate settles before we detect anything.
        if warmupCount < warmupSamples { warmupCount += 1; return nil }

        // 4) Adaptive noise floor — frozen while the signal is elevated so a
        //    slap (or its ringing) can't inflate the baseline.
        let elevated = linMag > (noiseFloor + 4 * noiseDev + 0.02)
        if !noiseInit {
            noiseFloor = linMag; noiseDev = 0.01; noiseInit = true
        } else if !elevated {
            let nA = noiseAlpha
            noiseFloor = nA * noiseFloor + (1 - nA) * linMag
            noiseDev = nA * noiseDev + (1 - nA) * abs(linMag - noiseFloor)
        }
        let dynAmp = max(config.ampThreshold, noiseFloor + config.sigmaMult * noiseDev)

        // 5) Refractory: swallow samples after a detection.
        if refractoryCount > 0 { refractoryCount -= 1; return nil }

        // 6) State machine.
        switch state {
        case .idle:
            let impulsive = (linMag >= dynAmp && jerk >= config.jerkThreshold)
            let bigHit = (linMag >= config.hardAmpThreshold)
            if impulsive || bigHit {
                state = .inImpact
                peakAmp = linMag
                peakJerk = jerk
                impactSamples = 0
            }
            return nil

        case .inImpact:
            impactSamples += 1
            if linMag > peakAmp { peakAmp = linMag }
            if jerk > peakJerk { peakJerk = jerk }
            let ended = (linMag < dynAmp * 0.5) || (impactSamples >= impactWindowSamples)
            guard ended else { return nil }
            state = .idle
            refractoryCount = refractorySamples
            return makeEvent()
        }
    }

    private func makeEvent() -> SlapEvent {
        let amp = peakAmp
        let lo = config.intensityLowG
        let hi = config.intensityHighG
        let t = max(0.0, min(1.0, (amp - lo) / (hi - lo)))
        let intensity = log(1 + t * 99) / log(100)   // logarithmic loudness curve

        let severity: SlapSeverity = amp >= 1.0 ? .majorShock
            : (amp >= 0.4 ? .mediumShock : .microShock)

        var sources: Set<String> = ["impact"]
        if peakJerk >= config.jerkThreshold { sources.insert("jerk") }
        if amp >= config.hardAmpThreshold { sources.insert("bigHit") }

        return SlapEvent(magnitude: amp, intensity: intensity, severity: severity, sources: sources)
    }
}
