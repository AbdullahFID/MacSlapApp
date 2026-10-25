import AppKit
import AVFoundation
import SlapCore

/// Keeps raw audio inside the input tap; only amplitude measurements reach UI.
@MainActor
final class MicrophoneReader {
    private let engine = AVAudioEngine()
    private var wantsRunning = false
    private var hasTap = false
    private var isSleeping = false
    private var generation = 0
    private var detector = MicrophoneTapDetector()
    private var observers: [NSObjectProtocol] = []
    private var wakeObservers: [NSObjectProtocol] = []
    var sensitivity: SensitivityLevel = .medium
    var shouldSuppress: (() -> Bool)?
    var onTap: ((Double) -> Void)?
    var onStateChange: (() -> Void)?
    private(set) var status = "Microphone: Paused" {
        didSet {
            if status != oldValue {
                log(status)
                onStateChange?()
            }
        }
    }

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning, !self.isSleeping, !self.engine.isRunning else { return }
                self.restart()
            }
        })
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSleeping = true
                guard self.wantsRunning else { return }
                self.closeEngine()
                self.status = "Microphone: Sleeping"
            }
        })
        wakeObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSleeping = false
                guard self.wantsRunning else { return }
                self.restart()
            }
        })
    }

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        guard AppInfo.isBundled else {
            status = "Microphone: Open the .app bundle to allow access"
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: openEngine()
        case .notDetermined:
            status = "Microphone: Waiting for permission…"
            let permissionSession = generation
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning, !self.isSleeping,
                          self.generation == permissionSession else { return }
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                        self.openEngine()
                    } else {
                        self.status = "Microphone: Permission denied — open Microphone Settings"
                    }
                }
            }
        default: status = "Microphone: Permission denied — open Microphone Settings"
        }
    }

    func stop() {
        wantsRunning = false
        closeEngine()
        status = "Microphone: Paused"
    }

    func restart() {
        stop()
        start()
    }

    private func openEngine() {
        guard wantsRunning, !isSleeping else { return }
        closeEngine()
        detector = MicrophoneTapDetector()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            status = "Microphone: No usable input — check Sound Settings, then Retry"
            return
        }
        let session = generation
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            // Use the first input channel; request the built-in microphone in
            // Sound Settings for best chassis-tap pickup.
            let samples = channels[0]
            let windowSize = max(1, Int(buffer.format.sampleRate * 0.01))
            let capturedAt = ProcessInfo.processInfo.systemUptime
            for offset in stride(from: 0, to: Int(buffer.frameLength), by: windowSize) {
                let end = min(offset + windowSize, Int(buffer.frameLength))
                var peak = 0.0
                var sum = 0.0
                for i in offset..<end {
                    let value = Double(samples[i])
                    peak = max(peak, abs(value))
                    sum += value * value
                }
                let rms = sqrt(sum / Double(end - offset))
                let duration = Double(end - offset) / buffer.format.sampleRate
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.wantsRunning, self.generation == session,
                          ProcessInfo.processInfo.systemUptime - capturedAt < 0.2 else { return }
                    self.detector.sensitivity = self.sensitivity
                    if let intensity = self.detector.process(peak: peak, rms: rms, duration: duration,
                                                             suppressed: self.shouldSuppress?() ?? false) {
                        self.onTap?(intensity)
                    }
                }
            }
        }
        hasTap = true
        do {
            engine.prepare()
            try engine.start()
            status = "Microphone: Listening (local tap detection)"
        } catch {
            closeEngine()
            status = "Microphone: Failed to start — Retry Microphone"
            log("Microphone start failed: \(error.localizedDescription)")
        }
    }

    private func closeEngine() {
        generation += 1
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in wakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
