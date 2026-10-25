import Foundation
import SlapCore

/// Wires motion or microphone detection to the same reactions:
/// audio (with escalation), trackpad haptics, screen flash,
/// screen shake, brightness flash — plus the USB moaner.
@MainActor
final class SlapController {
    let settings: SettingsStore
    let library: SoundLibrary
    let audioPlayer: AudioPlayer
    let accelerometer = AccelerometerReader()
    let microphone = MicrophoneReader()
    private let hasMotionSensor = AccelerometerReader.isAvailable
    private var resumeTimer: Timer?
    private var suppressMicrophoneUntil = 0.0
    let usbMonitor = USBMonitor()
    let screenFlash = ScreenFlash()
    let screenShaker = ScreenShaker()
    let brightnessFlash = BrightnessFlash()
    let hapticFeedback = HapticFeedback()

    private let detector: SlapDetector
    private var lastSlapTime: Date = .distantPast

    /// Fired on the main thread after a slap has been handled.
    var onSlap: ((SlapEvent) -> Void)?
    /// Fired when anything shown in the menu changes (sensor status, sounds).
    var onStateChange: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        self.library = SoundLibrary(customFolder: settings.customSoundsFolder)
        self.audioPlayer = AudioPlayer(library: library)
        self.detector = SlapDetector(config: settings.sensitivity.detectorConfig)

        library.rescan()
        audioPlayer.load(pack: settings.voicePack)
        applyIntensities()

        // Sensor thread → detector directly; only real slaps hop to main.
        let detector = self.detector
        detector.onSlap = { [weak self] event in
            DispatchQueue.main.async {
                guard let self, !self.usesMicrophone else { return }
                self.handleSlap(event, isTest: false)
            }
        }
        accelerometer.onSample = { x, y, z in
            detector.processSample(x: x, y: y, z: z)
        }
        accelerometer.onSampleRate = { hz in
            detector.updateSampleRate(hz)
        }
        accelerometer.onSessionStart = {
            detector.reset()
        }
        accelerometer.onStatusChange = { [weak self] status in
            log(status.menuDescription)
            self?.onStateChange?()
        }

        microphone.sensitivity = settings.sensitivity
        microphone.onStateChange = { [weak self] in self?.onStateChange?() }
        microphone.shouldSuppress = { [weak self] in
            guard let self else { return true }
            if self.audioPlayer.isPlaying {
                self.suppressMicrophoneUntil = ProcessInfo.processInfo.systemUptime + 0.4
                return true
            }
            return !self.isActive || ProcessInfo.processInfo.systemUptime < self.suppressMicrophoneUntil
        }
        microphone.onTap = { [weak self] intensity in
            let event = SlapEvent(magnitude: 0, intensity: intensity, severity: .microShock,
                                  sources: ["microphone"])
            self?.handleSlap(event, isTest: false)
        }

        usbMonitor.onUSBEvent = { [weak self] in
            guard let self, self.settings.usbMoanerEnabled, self.isActive else { return }
            self.suppressMicrophoneUntil = ProcessInfo.processInfo.systemUptime + 0.6
            self.audioPlayer.playRandom(baseVolume: self.settings.volume)
        }
    }

    /// Enabled and not snoozed.
    var isActive: Bool { settings.isEnabled && !settings.isSnoozed }

    var usesMicrophone: Bool {
        settings.detectionSource == .microphone
            || (settings.detectionSource == .automatic && !hasMotionSensor)
    }

    var detectionStatus: String {
        usesMicrophone ? microphone.status : accelerometer.status.menuDescription
    }

    func selectDetectionSource(_ source: DetectionSource) {
        accelerometer.stop()
        microphone.stop()
        settings.detectionSource = source
        syncDetection()
        onStateChange?()
    }

    private func syncDetection() {
        if isActive {
            if usesMicrophone { microphone.start() } else { accelerometer.start() }
        } else {
            microphone.stop()
            accelerometer.stop()
        }
    }

    func start() {
        syncDetection()
        // Snoozing releases the microphone; resume automatically when it expires.
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncDetection() }
        }
        if settings.usbMoanerEnabled {
            usbMonitor.start()
        }
    }

    func shutdown() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        microphone.stop()
        accelerometer.stop()
        usbMonitor.stop()
        hapticFeedback.shutdown()
    }

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        syncDetection()
    }

    func setUSBMoaner(_ enabled: Bool) {
        settings.usbMoanerEnabled = enabled
        if enabled { usbMonitor.start() } else { usbMonitor.stop() }
    }

    func snooze(_ option: SnoozeOption) {
        settings.snoozeUntil = option.endDate()
        syncDetection()
        log("Snoozed until \(settings.snoozeUntil!)")
    }

    func resumeFromSnooze() {
        settings.snoozeUntil = nil
        syncDetection()
    }

    func selectVoicePack(_ pack: VoicePack) {
        settings.voicePack = pack
        audioPlayer.load(pack: pack)
    }

    func setCustomSoundsFolder(_ url: URL?) {
        settings.customSoundsFolder = url
        library.customFolder = url
        reloadSounds()
    }

    func reloadSounds() {
        library.rescan()
        audioPlayer.load(pack: settings.voicePack)
        onStateChange?()
    }

    func updateDetectorConfig() {
        detector.updateConfig(settings.sensitivity.detectorConfig)
        microphone.sensitivity = settings.sensitivity
    }

    /// Slider values are 0...1 and map to multipliers of 0...2.
    func applyIntensities() {
        screenShaker.intensityMultiplier = settings.shakeIntensity * 2.0
        brightnessFlash.intensityMultiplier = settings.brightnessFlashIntensity * 2.0
        screenFlash.intensityMultiplier = settings.screenFlashIntensity * 2.0
        hapticFeedback.intensityMultiplier = settings.hapticIntensity * 2.0
    }

    /// Plays every enabled reaction at a medium-hard intensity without touching stats.
    func testSlap() {
        let event = SlapEvent(magnitude: 1.2, intensity: 0.75, severity: .majorShock, sources: ["test"])
        handleSlap(event, isTest: true)
    }

    private func handleSlap(_ event: SlapEvent, isTest: Bool) {
        if !isTest {
            guard isActive else { return }
            // Enforce user-facing cooldown
            let now = Date()
            guard now.timeIntervalSince(lastSlapTime) >= settings.cooldownInterval else { return }
            lastSlapTime = now
        }

        // Cover playback startup latency and haptics, then extend this while
        // speech or clips are playing and for a short acoustic tail afterwards.
        suppressMicrophoneUntil = ProcessInfo.processInfo.systemUptime + 0.6
        audioPlayer.play(
            intensity: event.intensity,
            dynamicVolume: settings.dynamicVolume,
            baseVolume: settings.volume
        )
        if settings.hapticFeedbackEnabled {
            hapticFeedback.buzz(intensity: event.intensity)
        }
        if settings.screenShakeEnabled {
            screenShaker.shake(intensity: event.intensity)
        }
        if settings.brightnessFlashEnabled {
            brightnessFlash.flash(intensity: event.intensity)
        }
        if settings.screenFlashEnabled {
            screenFlash.flash(intensity: event.intensity)
        }

        if !isTest {
            settings.recordSlap(magnitude: event.sources.contains("microphone") ? 0 : event.magnitude)
        }
        onSlap?(event)

        let measurement = event.sources.contains("microphone")
            ? "acoustic intensity=\(String(format: "%.2f", event.intensity))"
            : "amp=\(String(format: "%.3f", event.magnitude))g"
        log("\(isTest ? "TEST" : event.severity.rawValue) \(measurement) " +
            "vol=\(String(format: "%.0f%%", event.intensity * 100)) " +
            "detectors=\(event.sources.sorted().joined(separator: "+")) " +
            "total=\(settings.totalSlapCount)")
    }
}
