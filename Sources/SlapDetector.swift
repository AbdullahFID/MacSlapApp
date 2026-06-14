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

struct DetectorConfig {
    /// Peak linear-acceleration (gravity removed) to qualify as a slap, in g.
    var ampThreshold: Double
    /// Jerk "performance index" = Σ|d(accel)/dt| across axes, in g/s.
    var jerkThreshold: Double
    /// Amplitude so high we accept it even without the jerk test, in g.
    var hardAmpThreshold: Double

    /// Adaptive floor: linMag must also exceed noiseFloor + sigmaMult·noiseDev.
    var sigmaMult: Double = 7.0
    /// IMU delivery rate (post-AccelerometerReader, ~805 Hz, no decimation).
    var sampleRate: Double = 805.0
    /// Gravity EMA factor (~0.5 s time constant at 805 Hz).
    var gravityAlpha: Double = 0.9975
    /// Ignore window after a detection so chassis ringing can't retrigger.
    var refractory: TimeInterval = 0.14
    /// Peak-hold window to capture the true peak force of an impact.
    var impactWindow: TimeInterval = 0.05

    /// Force→volume mapping (absolute, so volume reflects actual force,
    /// independent of the sensitivity setting).
    var intensityLowG: Double = 0.15
    var intensityHighG: Double = 1.8

    init(ampThreshold: Double,
         jerkThreshold: Double,
         hardAmpThreshold: Double,
         sigmaMult: Double = 7.0,
         sampleRate: Double = 805.0,
         gravityAlpha: Double = 0.9975,
         refractory: TimeInterval = 0.14,
         impactWindow: TimeInterval = 0.05,
         intensityLowG: Double = 0.15,
         intensityHighG: Double = 1.8) {
        self.ampThreshold = ampThreshold
        self.jerkThreshold = jerkThreshold
        self.hardAmpThreshold = hardAmpThreshold
        self.sigmaMult = sigmaMult
        self.sampleRate = sampleRate
        self.gravityAlpha = gravityAlpha
        self.refractory = refractory
        self.impactWindow = impactWindow
        self.intensityLowG = intensityLowG
        self.intensityHighG = intensityHighG
    }
}

// MARK: - Event

enum SlapSeverity: String {
    case majorShock = "MAJOR_SHOCK"     // peak ≥ 1.0 g
    case mediumShock = "MEDIUM_SHOCK"   // peak ≥ 0.4 g
    case microShock = "MICRO_SHOCK"     // below that, but still a real impact
}

struct SlapEvent {
    let magnitude: Double      // peak linear-accel of the impact, in g
    let intensity: Double      // 0..1 for volume scaling
    let severity: SlapSeverity
    let sources: Set<String>   // which gates fired (impact/jerk/bigHit)
    let timestamp: Date
}

// MARK: - Impact Detector

/// Single-pass impact detector. Gravity is removed with a slow EMA; we then
/// gate on simultaneous high amplitude + high jerk (the empirically clean
/// separator between slaps and typing), refine the peak with a short hold,
/// and enforce a refractory period.
final class SlapDetector {
    private var config: DetectorConfig

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

    // processSample runs on the accelerometer's background thread; updateConfig
    // is called from the menu (main thread). Guard shared state with a lock.
    private let lock = NSLock()

    var onSlap: ((SlapEvent) -> Void)?

    init(config: DetectorConfig) {
        self.config = config
    }

    func updateConfig(_ newConfig: DetectorConfig) {
        lock.lock(); defer { lock.unlock() }
        config = newConfig
        state = .idle
        refractoryCount = 0
    }

    func processSample(x: Double, y: Double, z: Double) {
        lock.lock(); defer { lock.unlock() }
        // 1) Track gravity, derive linear acceleration + magnitude.
        if !gravInit { gx = x; gy = y; gz = z; gravInit = true }
        let a = config.gravityAlpha
        gx = a * gx + (1 - a) * x
        gy = a * gy + (1 - a) * y
        gz = a * gz + (1 - a) * z
        let lx = x - gx, ly = y - gy, lz = z - gz
        let linMag = (lx * lx + ly * ly + lz * lz).squareRoot()

        // 2) Jerk performance index (Σ|Δaccel|·rate across axes).
        var jerk = 0.0
        if havePrev {
            jerk = (abs(lx - prevLx) + abs(ly - prevLy) + abs(lz - prevLz)) * config.sampleRate
        }
        prevLx = lx; prevLy = ly; prevLz = lz; havePrev = true

        // 3) Warm up so the gravity estimate settles before we detect anything.
        warmupCount += 1
        if warmupCount < Int(config.sampleRate * 0.3) { return }

        // 4) Adaptive noise floor — frozen while the signal is elevated so a
        //    slap (or its ringing) can't inflate the baseline.
        let elevated = linMag > (noiseFloor + 4 * noiseDev + 0.02)
        if !noiseInit {
            noiseFloor = linMag; noiseDev = 0.01; noiseInit = true
        } else if !elevated {
            let nA = 0.999
            noiseFloor = nA * noiseFloor + (1 - nA) * linMag
            noiseDev = nA * noiseDev + (1 - nA) * abs(linMag - noiseFloor)
        }
        let dynAmp = max(config.ampThreshold, noiseFloor + config.sigmaMult * noiseDev)

        // 5) Refractory: swallow samples after a detection.
        if refractoryCount > 0 { refractoryCount -= 1; return }

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

        case .inImpact:
            impactSamples += 1
            if linMag > peakAmp { peakAmp = linMag }
            if jerk > peakJerk { peakJerk = jerk }
            let windowSamples = max(1, Int(config.impactWindow * config.sampleRate))
            let ended = (linMag < dynAmp * 0.5) || (impactSamples >= windowSamples)
            if ended {
                emit()
                state = .idle
                refractoryCount = Int(config.refractory * config.sampleRate)
            }
        }
    }

    private func emit() {
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

        onSlap?(SlapEvent(magnitude: amp,
                          intensity: intensity,
                          severity: severity,
                          sources: sources,
                          timestamp: Date()))
    }
}
