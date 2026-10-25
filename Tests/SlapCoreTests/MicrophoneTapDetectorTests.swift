import Testing
@testable import SlapCore

@Suite("Microphone tap detection")
struct MicrophoneTapDetectorTests {
    private func calibrated(noise: Double = 0.002) -> MicrophoneTapDetector {
        var detector = MicrophoneTapDetector()
        for _ in 0..<100 {
            _ = detector.process(peak: noise * 2, rms: noise, duration: 0.01)
        }
        return detector
    }

    @Test("Calibrates before accepting taps, then detects an isolated transient")
    func calibrationAndTap() {
        var detector = MicrophoneTapDetector()
        #expect(detector.process(peak: 0.7, rms: 0.1, duration: 0.01) == nil)
        detector = calibrated()
        let intensity = detector.process(peak: 0.4, rms: 0.07, duration: 0.01)
        #expect(intensity != nil)
        #expect((0.1...1).contains(intensity ?? -1))
    }

    @Test("Rejects quiet typing and steady loud audio")
    func background() {
        var detector = calibrated()
        for _ in 0..<100 {
            #expect(detector.process(peak: 0.025, rms: 0.006, duration: 0.01) == nil)
            #expect(detector.process(peak: 0.004, rms: 0.002, duration: 0.01) == nil)
        }
        // High RMS without a sharp crest isn't an impact.
        for _ in 0..<100 {
            #expect(detector.process(peak: 0.3, rms: 0.2, duration: 0.01) == nil)
        }
    }

    @Test("Uses the ambient floor and sensitivity setting")
    func sensitivityAndNoise() {
        var quiet = calibrated()
        quiet.sensitivity = .veryHigh
        #expect(quiet.process(peak: 0.06, rms: 0.012, duration: 0.01) != nil)
        var strict = calibrated()
        strict.sensitivity = .veryLow
        #expect(strict.process(peak: 0.06, rms: 0.012, duration: 0.01) == nil)
        var noisy = calibrated(noise: 0.04)
        #expect(noisy.process(peak: 0.15, rms: 0.06, duration: 0.01) == nil)
    }

    @Test("Ringing counts once and a later tap counts again")
    func refractory() {
        var detector = calibrated()
        #expect(detector.process(peak: 0.4, rms: 0.07, duration: 0.01) != nil)
        for _ in 0..<10 {
            _ = detector.process(peak: 0.004, rms: 0.002, duration: 0.01)
            #expect(detector.process(peak: 0.4, rms: 0.07, duration: 0.01) == nil)
        }
        for _ in 0..<100 {
            _ = detector.process(peak: 0.004, rms: 0.002, duration: 0.01)
        }
        #expect(detector.process(peak: 0.4, rms: 0.07, duration: 0.01) != nil)
    }

    @Test("Playback suppression ignores audio and its immediate tail")
    func suppression() {
        var detector = calibrated()
        for _ in 0..<100 {
            #expect(detector.process(peak: 0.7, rms: 0.1, duration: 0.01, suppressed: true) == nil)
        }
        _ = detector.process(peak: 0.004, rms: 0.002, duration: 0.01)
        #expect(detector.process(peak: 0.4, rms: 0.07, duration: 0.01) == nil)
        for _ in 0..<100 {
            _ = detector.process(peak: 0.004, rms: 0.002, duration: 0.01)
        }
        #expect(detector.process(peak: 0.4, rms: 0.07, duration: 0.01) != nil)
    }

    @Test("Suppressed playback during warmup cannot poison the noise floor")
    func warmupSuppression() {
        var detector = MicrophoneTapDetector()
        for _ in 0..<100 {
            #expect(detector.process(peak: 0.9, rms: 0.3, duration: 0.01, suppressed: true) == nil)
        }
        for _ in 0..<40 {
            _ = detector.process(peak: 0.004, rms: 0.002, duration: 0.01)
        }
        #expect(detector.process(peak: 0.12, rms: 0.02, duration: 0.01) != nil)
    }

    @Test("Calibration and refractory timing work across audio window sizes",
          arguments: [0.005, 0.01, 0.02])
    func windowTiming(duration: Double) {
        var detector = MicrophoneTapDetector()
        for _ in 0..<Int(1.0 / duration) {
            _ = detector.process(peak: 0.004, rms: 0.002, duration: duration)
        }
        #expect(detector.process(peak: 0.4, rms: 0.07, duration: duration) != nil)
        for _ in 0..<Int(0.1 / duration) {
            _ = detector.process(peak: 0.004, rms: 0.002, duration: duration)
        }
        #expect(detector.process(peak: 0.4, rms: 0.07, duration: duration) == nil)
        for _ in 0..<Int(0.4 / duration) {
            _ = detector.process(peak: 0.004, rms: 0.002, duration: duration)
        }
        #expect(detector.process(peak: 0.4, rms: 0.07, duration: duration) != nil)
    }

    @Test("Invalid input cannot poison state")
    func invalidInput() {
        var detector = calibrated()
        #expect(detector.process(peak: .nan, rms: 0, duration: 0.01) == nil)
        #expect(detector.process(peak: 0.4, rms: .infinity, duration: 0.01) == nil)
        #expect(detector.process(peak: 0.4, rms: 0.07, duration: -1) == nil)
        #expect(detector.process(peak: 0.4, rms: 0.07, duration: 0.01) != nil)
    }
}
