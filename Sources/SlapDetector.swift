import Foundation

// MARK: - Configuration

/// Configuration for the slap detection algorithms
struct DetectorConfig {
    // STA/LTA parameters (3 timescales like spank)
    var staltaFast: STALTAConfig = STALTAConfig(staN: 3, ltaN: 100, onThreshold: 3.0, offThreshold: 1.5)
    var staltaMedium: STALTAConfig = STALTAConfig(staN: 15, ltaN: 500, onThreshold: 2.5, offThreshold: 1.3)
    var staltaSlow: STALTAConfig = STALTAConfig(staN: 50, ltaN: 2000, onThreshold: 2.0, offThreshold: 1.2)

    // CUSUM parameters
    var cusumK: Double = 0.0005       // sensitivity parameter
    var cusumH: Double = 0.01         // threshold

    // Kurtosis parameters
    var kurtosisThreshold: Double = 6.0
    var kurtosisWindowSize: Int = 100
    var kurtosisDecimation: Int = 10

    // PeakMAD parameters
    var peakMADSigmaThreshold: Double = 2.0
    var peakMADWindowSize: Int = 100

    // High-pass filter
    var highPassAlpha: Double = 0.95

    // General
    var warmupSamples: Int = 50
    var minCooldown: TimeInterval = 0.01  // 10ms between events (like spank)
    var minAmplitude: Double = 0.05       // minimum g-force to trigger
    var minDetectorCount: Int = 1         // how many detectors must agree
    var typingGuardWindow: TimeInterval = 1.5  // suppress if N small events in this window
    var typingGuardMaxEvents: Int = 0     // 0 = disabled
}

struct STALTAConfig {
    var staN: Int
    var ltaN: Int
    var onThreshold: Double
    var offThreshold: Double
}

// MARK: - Event Classification

/// Event severity levels based on how many detectors fired + amplitude
enum SlapSeverity: String {
    case majorShock = "MAJOR_SHOCK"     // 4+ detectors, amp > 0.05
    case mediumShock = "MEDIUM_SHOCK"   // 3+ detectors, amp > 0.02
    case microShock = "MICRO_SHOCK"     // Peak triggered, amp > 0.005
    case vibration = "VIBRATION"        // STA/LTA or CUSUM, amp > 0.003
    case lightVibration = "LIGHT_VIB"   // amp > 0.001
    case microVibration = "MICRO_VIB"   // anything else
}

/// Represents a detected slap event
struct SlapEvent {
    let magnitude: Double      // Raw amplitude in g
    let intensity: Double      // Normalized 0.0-1.0 for volume scaling
    let severity: SlapSeverity
    let sources: Set<String>   // Which detectors fired
    let timestamp: Date
}

// MARK: - Signal Processing Primitives

/// First-order IIR high-pass filter to remove gravity (DC offset)
struct HighPassFilter {
    let alpha: Double
    private var prevRaw: (x: Double, y: Double, z: Double) = (0, 0, 0)
    private var prevOut: (x: Double, y: Double, z: Double) = (0, 0, 0)
    private var initialized = false

    init(alpha: Double) {
        self.alpha = alpha
    }

    mutating func filter(x: Double, y: Double, z: Double) -> (x: Double, y: Double, z: Double) {
        if !initialized {
            prevRaw = (x, y, z)
            prevOut = (0, 0, 0)
            initialized = true
            return (0, 0, 0)
        }
        let outX = alpha * (prevOut.x + x - prevRaw.x)
        let outY = alpha * (prevOut.y + y - prevRaw.y)
        let outZ = alpha * (prevOut.z + z - prevRaw.z)
        prevRaw = (x, y, z)
        prevOut = (outX, outY, outZ)
        return (outX, outY, outZ)
    }
}

/// Ring buffer for storing recent samples
struct RingBuffer {
    private var buffer: [Double]
    private var writeIndex: Int = 0
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Double](repeating: 0, count: capacity)
    }

    mutating func push(_ value: Double) {
        buffer[writeIndex % capacity] = value
        writeIndex += 1
        count = min(count + 1, capacity)
    }

    func toArray() -> [Double] {
        guard count > 0 else { return [] }
        if count < capacity {
            return Array(buffer[0..<count])
        }
        let start = writeIndex % capacity
        return Array(buffer[start..<capacity]) + Array(buffer[0..<start])
    }

    var last: Double? {
        guard count > 0 else { return nil }
        return buffer[(writeIndex - 1 + capacity) % capacity]
    }
}

// MARK: - Individual Detectors

/// STA/LTA (Short-Term Average / Long-Term Average)
/// Classic seismological algorithm. Computes ratio of short-term energy to
/// long-term energy. A sudden impact spikes the ratio.
class STALTADetector {
    let name: String
    private var staSum: Double = 0
    private var ltaSum: Double = 0
    private var staBuffer: [Double]
    private var ltaBuffer: [Double]
    private var staIdx = 0
    private var ltaIdx = 0
    private var staCount = 0
    private var ltaCount = 0
    private let staN: Int
    private let ltaN: Int
    private let onThreshold: Double
    private let offThreshold: Double
    private var isTriggered = false

    init(name: String, config: STALTAConfig) {
        self.name = name
        self.staN = config.staN
        self.ltaN = config.ltaN
        self.onThreshold = config.onThreshold
        self.offThreshold = config.offThreshold
        self.staBuffer = [Double](repeating: 0, count: config.staN)
        self.ltaBuffer = [Double](repeating: 0, count: config.ltaN)
    }

    /// Returns spike ratio if triggered, nil otherwise
    func process(_ magnitude: Double) -> Double? {
        let energy = magnitude * magnitude

        // Update STA (circular buffer with running sum)
        if staCount >= staN {
            staSum -= staBuffer[staIdx % staN]
        }
        staBuffer[staIdx % staN] = energy
        staSum += energy
        staIdx += 1
        staCount = min(staCount + 1, staN)

        // Update LTA
        if ltaCount >= ltaN {
            ltaSum -= ltaBuffer[ltaIdx % ltaN]
        }
        ltaBuffer[ltaIdx % ltaN] = energy
        ltaSum += energy
        ltaIdx += 1
        ltaCount = min(ltaCount + 1, ltaN)

        guard staCount >= staN, ltaCount >= ltaN else { return nil }

        let staAvg = staSum / Double(staN)
        let ltaAvg = ltaSum / Double(ltaN)
        guard ltaAvg > 1e-12 else { return nil }

        let ratio = staAvg / ltaAvg

        if !isTriggered && ratio > onThreshold {
            isTriggered = true
            return ratio
        } else if isTriggered && ratio < offThreshold {
            isTriggered = false
        }
        return nil
    }
}

/// CUSUM (Cumulative Sum) detector
/// Detects sustained shifts in the mean of the signal.
/// Classic change-point detection algorithm.
class CUSUMDetector {
    private var cusumPos: Double = 0
    private var cusumNeg: Double = 0
    private var meanEstimate: Double = 0
    private let meanAlpha: Double = 0.001  // slow EMA for baseline mean
    private let k: Double          // sensitivity (allowable slack)
    private let h: Double          // threshold
    private var sampleCount = 0
    private var lastTriggered = false

    init(k: Double = 0.0005, h: Double = 0.01) {
        self.k = k
        self.h = h
    }

    /// Returns CUSUM value if triggered, nil otherwise
    func process(_ magnitude: Double) -> Double? {
        sampleCount += 1

        // Update baseline mean estimate (exponential moving average)
        if sampleCount == 1 {
            meanEstimate = magnitude
        } else {
            meanEstimate = meanAlpha * magnitude + (1 - meanAlpha) * meanEstimate
        }

        // Update CUSUM accumulators
        cusumPos = max(0, cusumPos + magnitude - meanEstimate - k)
        cusumNeg = max(0, cusumNeg - magnitude + meanEstimate - k)

        let cusumVal = max(cusumPos, cusumNeg)

        if cusumVal > h {
            // Reset after trigger to prevent continuous firing
            let result = cusumVal
            cusumPos = 0
            cusumNeg = 0
            if !lastTriggered {
                lastTriggered = true
                return result
            }
            return nil
        } else {
            lastTriggered = false
        }
        return nil
    }
}

/// Kurtosis detector — measures the "peakedness" of the signal.
/// Normal distribution has excess kurtosis = 0. Sharp impacts create
/// heavy-tailed distributions with high positive kurtosis.
class KurtosisDetector {
    private var buffer: RingBuffer
    private let threshold: Double
    private let minSamples: Int
    private var decimationCounter = 0
    private let decimation: Int

    init(windowSize: Int = 100, threshold: Double = 6.0, minSamples: Int = 50, decimation: Int = 10) {
        self.buffer = RingBuffer(capacity: windowSize)
        self.threshold = threshold
        self.minSamples = minSamples
        self.decimation = decimation
    }

    func process(_ magnitude: Double) -> Double? {
        decimationCounter += 1
        guard decimationCounter % decimation == 0 else { return nil }

        buffer.push(magnitude)
        guard buffer.count >= minSamples else { return nil }

        let values = buffer.toArray()
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
        guard variance > 1e-12 else { return nil }

        let fourthMoment = values.map { pow($0 - mean, 4) }.reduce(0, +) / n
        let kurtosis = fourthMoment / (variance * variance) - 3.0  // excess kurtosis

        if kurtosis > threshold {
            return kurtosis
        }
        return nil
    }
}

/// Peak/MAD (Median Absolute Deviation) outlier detector
/// More robust than standard deviation — resistant to outliers contaminating
/// the baseline. Triggers when current sample exceeds N sigma from median.
class PeakMADDetector {
    private var buffer: RingBuffer
    private let sigmaThreshold: Double
    private let minSamples: Int
    private let consistencyConstant: Double = 1.4826  // MAD to sigma conversion

    init(windowSize: Int = 100, sigmaThreshold: Double = 2.0, minSamples: Int = 50) {
        self.buffer = RingBuffer(capacity: windowSize)
        self.sigmaThreshold = sigmaThreshold
        self.minSamples = minSamples
    }

    func process(_ magnitude: Double) -> Double? {
        buffer.push(magnitude)
        guard buffer.count >= minSamples else { return nil }

        let values = buffer.toArray()
        let sorted = values.sorted()
        let n = sorted.count
        let median = (n % 2 == 0) ? (sorted[n/2 - 1] + sorted[n/2]) / 2.0 : sorted[n/2]

        let absDeviations = values.map { abs($0 - median) }.sorted()
        let mad = (absDeviations.count % 2 == 0)
            ? (absDeviations[absDeviations.count/2 - 1] + absDeviations[absDeviations.count/2]) / 2.0
            : absDeviations[absDeviations.count/2]

        let sigma = consistencyConstant * mad
        guard sigma > 1e-12 else { return nil }

        let modifiedZ = abs(magnitude - median) / sigma

        if modifiedZ > sigmaThreshold {
            return modifiedZ
        }
        return nil
    }
}

// MARK: - Main Slap Detector (Voting Ensemble)

/// "Five concurrent signal processing algorithms vote on whether you actually
/// slapped your laptop. Democracy, but for physical abuse."
///
/// Combines: High-Pass Filter → STA/LTA (3 timescales) + CUSUM + Kurtosis + Peak/MAD
/// Event classification based on how many detectors agree + amplitude.
class SlapDetector {
    private var config: DetectorConfig
    private var highPassFilter: HighPassFilter

    // The 5 detection algorithms
    private var staltaFast: STALTADetector
    private var staltaMedium: STALTADetector
    private var staltaSlow: STALTADetector
    private var cusumDetector: CUSUMDetector
    private var kurtosisDetector: KurtosisDetector
    private var peakMADDetector: PeakMADDetector

    private var samplesSeen: Int = 0
    private var lastEventTime: Date = .distantPast
    private var recentSmallEventTimes: [Date] = []  // for typing guard

    var onSlap: ((SlapEvent) -> Void)?

    init(config: DetectorConfig) {
        self.config = config
        self.highPassFilter = HighPassFilter(alpha: config.highPassAlpha)
        self.staltaFast = STALTADetector(name: "STA/LTA-fast", config: config.staltaFast)
        self.staltaMedium = STALTADetector(name: "STA/LTA-med", config: config.staltaMedium)
        self.staltaSlow = STALTADetector(name: "STA/LTA-slow", config: config.staltaSlow)
        self.cusumDetector = CUSUMDetector(k: config.cusumK, h: config.cusumH)
        self.kurtosisDetector = KurtosisDetector(
            windowSize: config.kurtosisWindowSize,
            threshold: config.kurtosisThreshold,
            decimation: config.kurtosisDecimation
        )
        self.peakMADDetector = PeakMADDetector(
            windowSize: config.peakMADWindowSize,
            sigmaThreshold: config.peakMADSigmaThreshold
        )
    }

    func updateConfig(_ newConfig: DetectorConfig) {
        self.config = newConfig
        self.highPassFilter = HighPassFilter(alpha: newConfig.highPassAlpha)
        self.staltaFast = STALTADetector(name: "STA/LTA-fast", config: newConfig.staltaFast)
        self.staltaMedium = STALTADetector(name: "STA/LTA-med", config: newConfig.staltaMedium)
        self.staltaSlow = STALTADetector(name: "STA/LTA-slow", config: newConfig.staltaSlow)
        self.cusumDetector = CUSUMDetector(k: newConfig.cusumK, h: newConfig.cusumH)
        self.kurtosisDetector = KurtosisDetector(
            windowSize: newConfig.kurtosisWindowSize,
            threshold: newConfig.kurtosisThreshold,
            decimation: newConfig.kurtosisDecimation
        )
        self.peakMADDetector = PeakMADDetector(
            windowSize: newConfig.peakMADWindowSize,
            sigmaThreshold: newConfig.peakMADSigmaThreshold
        )
        samplesSeen = 0
        recentSmallEventTimes.removeAll()
    }

    func processSample(x: Double, y: Double, z: Double) {
        samplesSeen += 1

        // Step 1: High-pass filter to strip gravity
        let filtered = highPassFilter.filter(x: x, y: y, z: z)
        let magnitude = sqrt(filtered.x * filtered.x + filtered.y * filtered.y + filtered.z * filtered.z)

        // Skip warmup while baseline stabilizes
        guard samplesSeen > config.warmupSamples else { return }

        // Enforce minimum inter-event cooldown
        let now = Date()
        guard now.timeIntervalSince(lastEventTime) > config.minCooldown else { return }

        // Step 2: Run all 5 detection algorithms and collect votes
        var sources = Set<String>()

        if staltaFast.process(magnitude) != nil { sources.insert("STA/LTA") }
        if staltaMedium.process(magnitude) != nil { sources.insert("STA/LTA") }
        if staltaSlow.process(magnitude) != nil { sources.insert("STA/LTA") }
        if cusumDetector.process(magnitude) != nil { sources.insert("CUSUM") }
        if kurtosisDetector.process(magnitude) != nil { sources.insert("KURTOSIS") }
        if peakMADDetector.process(magnitude) != nil { sources.insert("PEAK") }

        guard !sources.isEmpty else { return }

        // Typing guard: track small sub-threshold events; if there are too many in a
        // short window it's almost certainly keyboard vibration, not a slap.
        if config.typingGuardMaxEvents > 0 && magnitude < config.minAmplitude * 2.0 {
            recentSmallEventTimes.append(now)
            recentSmallEventTimes = recentSmallEventTimes.filter {
                now.timeIntervalSince($0) < config.typingGuardWindow
            }
            if recentSmallEventTimes.count >= config.typingGuardMaxEvents { return }
        }

        // Require minimum number of distinct detector types to agree
        guard sources.count >= config.minDetectorCount else { return }

        // Step 3: Classify event severity based on votes + amplitude
        let numSources = sources.count
        let severity: SlapSeverity
        let amplitude = magnitude

        switch true {
        case numSources >= 4 && amplitude > 0.05:
            severity = .majorShock
        case numSources >= 3 && amplitude > 0.02:
            severity = .mediumShock
        case sources.contains("PEAK") && amplitude > 0.005:
            severity = .microShock
        case (sources.contains("STA/LTA") || sources.contains("CUSUM")) && amplitude > 0.003:
            severity = .vibration
        case amplitude > 0.001:
            severity = .lightVibration
        default:
            severity = .microVibration
        }

        // Only trigger on actual slaps (not micro vibrations)
        guard amplitude >= config.minAmplitude else { return }
        guard severity == .majorShock || severity == .mediumShock || severity == .microShock else { return }

        // Step 4: Normalize intensity for volume scaling
        // Log curve: maps amplitude range [0.05, 0.80] -> [0.0, 1.0]
        let minAmp = 0.05
        let maxAmp = 0.80
        let clamped = min(max(amplitude, minAmp), maxAmp)
        let t = (clamped - minAmp) / (maxAmp - minAmp)
        let intensity = log(1 + t * 99) / log(100)  // logarithmic scaling

        recentSmallEventTimes.removeAll()  // clear typing buffer on confirmed slap
        lastEventTime = now
        let event = SlapEvent(
            magnitude: amplitude,
            intensity: intensity,
            severity: severity,
            sources: sources,
            timestamp: now
        )
        onSlap?(event)
    }
}
