import Foundation
import SlapCore

/// Wires the accelerometer to the slap detector and fans each slap out to
/// every reaction: audio (with escalation), trackpad haptics, screen flash,
/// screen shake, brightness flash — plus the USB moaner.
@MainActor
final class SlapController {
    let settings: SettingsStore
    let library: SoundLibrary
    let audioPlayer: AudioPlayer
    let accelerometer = AccelerometerReader()
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
            DispatchQueue.main.async { self?.handleSlap(event, isTest: false) }
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

        usbMonitor.onUSBEvent = { [weak self] in
            guard let self, self.settings.usbMoanerEnabled, self.isActive else { return }
            self.audioPlayer.playRandom(baseVolume: self.settings.volume)
        }
    }

    /// Enabled and not snoozed.
    var isActive: Bool { settings.isEnabled && !settings.isSnoozed }

    func start() {
        if settings.isEnabled {
            accelerometer.start()
        } else {
            log("Starting disabled — sensor stays off until re-enabled")
        }
        if settings.usbMoanerEnabled {
            usbMonitor.start()
        }
    }

    func shutdown() {
        accelerometer.stop()
        usbMonitor.stop()
        hapticFeedback.shutdown()
    }

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        if enabled {
            accelerometer.start()
        } else {
            accelerometer.stop()
        }
    }

    func setUSBMoaner(_ enabled: Bool) {
        settings.usbMoanerEnabled = enabled
        if enabled { usbMonitor.start() } else { usbMonitor.stop() }
    }

    func snooze(_ option: SnoozeOption) {
        settings.snoozeUntil = option.endDate()
        log("Snoozed until \(settings.snoozeUntil!)")
    }

    func resumeFromSnooze() {
        settings.snoozeUntil = nil
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
            settings.recordSlap(magnitude: event.magnitude)
        }
        onSlap?(event)

        log("\(isTest ? "TEST" : event.severity.rawValue) amp=\(String(format: "%.3f", event.magnitude))g " +
            "vol=\(String(format: "%.0f%%", event.intensity * 100)) " +
            "detectors=\(event.sources.sorted().joined(separator: "+")) " +
            "total=\(settings.totalSlapCount)")
    }
}
