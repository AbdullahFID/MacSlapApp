import AppKit
import IOKit
import IOKit.hid

/// What the sensor is doing right now, for the menu and the logs.
enum SensorStatus: Equatable {
    case stopped
    case starting
    case streaming(rate: Double)
    case stalled
    case unavailable(reason: String)

    var menuDescription: String {
        switch self {
        case .stopped: return "Sensor: Paused"
        case .starting: return "Sensor: Starting…"
        case .streaming(let rate): return "Sensor: Live (\(Int(rate.rounded())) Hz)"
        case .stalled: return "Sensor: Reconnecting…"
        case .unavailable(let reason): return "Sensor: \(reason)"
        }
    }
}

/// Reads raw accelerometer data from the MacBook's built-in Bosch BMI286 IMU.
///
/// Uses direct IOKit service matching for AppleSPUHIDDevice rather than
/// IOHIDManager (which requires Developer ID signing):
/// 1. Wake the accelerometer's AppleSPUHIDDriver (power + reporting state)
/// 2. Find the AppleSPUHIDDevice with vendor page 0xFF00, usage 3
/// 3. Open it and receive input reports on a dedicated thread's run loop
/// 4. A watchdog reopens the device if reports stop (sleep/wake, SPU resets)
///
/// Report format (BMI286): 22 bytes per report
///   - Bytes 0-5: header/metadata
///   - Bytes 6-9: X axis (little-endian int32, Q16 fixed-point)
///   - Bytes 10-13: Y axis
///   - Bytes 14-17: Z axis
@MainActor
final class AccelerometerReader {
    private static let targetUsagePage = 0xFF00  // Apple vendor page
    private static let targetUsage = 3           // Accelerometer

    /// No reports for this long while running means the stream died.
    private static let stallTimeout: TimeInterval = 3.0
    private static let watchdogInterval: TimeInterval = 1.0
    private static let maxRetryDelay: TimeInterval = 60.0
    /// If a targeted wake yields no reports in this window, wake every SPU driver.
    private static let targetedWakeGrace: TimeInterval = 1.5

    private(set) var status: SensorStatus = .stopped {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    /// Called on the sensor thread with (x, y, z) in g.
    var onSample: (@Sendable (_ x: Double, _ y: Double, _ z: Double) -> Void)?
    /// Called on the main thread roughly once a second with the measured rate.
    var onSampleRate: ((Double) -> Void)?
    /// Called on the main thread after the stream is (re)opened, before samples flow.
    var onSessionStart: (() -> Void)?
    var onStatusChange: ((SensorStatus) -> Void)?

    private var session: SensorSession?
    private var wantsRunning = false
    private var watchdog: Timer?
    private var retryDelay: TimeInterval = 1.0
    private var nextRetry: Date = .distantPast
    private var wokeAllDrivers = false
    private var sessionOpenedAt: Date = .distantPast
    private var wakeObservers: [NSObjectProtocol] = []

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        retryDelay = 1.0
        wokeAllDrivers = false
        observeSystemWake()
        openSession()
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        watchdog?.tolerance = 0.25
    }

    func stop() {
        guard wantsRunning else { return }
        wantsRunning = false
        watchdog?.invalidate()
        watchdog = nil
        for token in wakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        wakeObservers.removeAll()
        closeSession()
        status = .stopped
        log("Accelerometer stopped")
    }

    // MARK: - Session lifecycle

    private func openSession() {
        closeSession()
        status = .starting

        if wokeAllDrivers {
            Self.wakeDrivers(onlyAccelerometer: false)
        } else {
            Self.wakeDrivers(onlyAccelerometer: true)
        }

        let service: io_service_t
        switch Self.findAccelerometerService() {
        case .success(let s): service = s
        case .failure(let reason):
            status = .unavailable(reason: reason.message)
            log("Accelerometer unavailable: \(reason.message)")
            scheduleRetry(permanent: reason.isPermanent)
            return
        }
        defer { IOObjectRelease(service) }

        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
            status = .unavailable(reason: "Couldn't create HID device")
            log("IOHIDDeviceCreate failed")
            scheduleRetry(permanent: false)
            return
        }

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            let code = String(format: "0x%08x", UInt32(bitPattern: openResult))
            status = .unavailable(reason: "Couldn't open sensor (\(code))")
            log("IOHIDDeviceOpen failed: \(code)")
            scheduleRetry(permanent: false)
            return
        }

        // Wake again now the device is open. Power/reporting state lives on the
        // AppleSPUHIDDriver service; IOHIDDeviceSetProperty on the device is
        // silently ignored on Apple Silicon and the IMU never streams.
        Self.wakeDrivers(onlyAccelerometer: !wokeAllDrivers)

        onSessionStart?()
        let sampleHandler = onSample
        let newSession = SensorSession(device: device, onSample: sampleHandler) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        newSession.start()
        session = newSession
        sessionOpenedAt = Date()
        log("Accelerometer opened (\(wokeAllDrivers ? "all SPU drivers" : "accelerometer driver") woken)")
    }

    private func closeSession() {
        session?.cancel()
        session = nil
    }

    private func handle(_ event: SensorSession.Event) {
        guard wantsRunning else { return }
        switch event {
        case .firstSample(let magnitude):
            retryDelay = 1.0
            log("Accelerometer streaming OK — first sample mag=\(String(format: "%.3f", magnitude))g")
            if case .streaming = status {} else { status = .streaming(rate: SlapRateDefaults.nominal) }
        case .rate(let hz):
            onSampleRate?(hz)
            if case .streaming(let old) = status, abs(old - hz) / max(old, 1) < 0.02 { return }
            status = .streaming(rate: hz)
        }
    }

    private func checkHealth() {
        guard wantsRunning else { return }

        guard let session else {
            if Date() >= nextRetry { openSession() }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let last = session.lastSampleUptime
        let sinceOpen = Date().timeIntervalSince(sessionOpenedAt)

        if last == 0 {
            // Never got a sample. Escalate the wake once, then back off.
            if !wokeAllDrivers && sinceOpen >= Self.targetedWakeGrace {
                log("No reports after targeted wake — waking all SPU drivers")
                wokeAllDrivers = true
                Self.wakeDrivers(onlyAccelerometer: false)
                sessionOpenedAt = Date()
            } else if sinceOpen >= Self.stallTimeout {
                log("Accelerometer opened but never streamed — reopening")
                status = .stalled
                reopenWithBackoff()
            }
        } else if now - last >= Self.stallTimeout {
            log(String(format: "Accelerometer stalled (%.1fs without reports) — reopening", now - last))
            status = .stalled
            reopenWithBackoff()
        }
    }

    private func reopenWithBackoff() {
        closeSession()
        scheduleRetry(permanent: false)
    }

    private func scheduleRetry(permanent: Bool) {
        // Hardware that doesn't exist won't appear later; only retry on wake.
        let delay = permanent ? Self.maxRetryDelay * 10 : retryDelay
        nextRetry = Date().addingTimeInterval(delay)
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
    }

    private func observeSystemWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            }
            wakeObservers.append(token)
        }
    }

    private func systemDidWake() {
        guard wantsRunning else { return }
        log("System woke — re-waking sensor")
        // The SPU can drop the power/reporting state across sleep.
        Self.wakeDrivers(onlyAccelerometer: !wokeAllDrivers)
        retryDelay = 1.0
        if session == nil { nextRetry = .distantPast }
    }

    // MARK: - IORegistry helpers

    private struct LookupFailure: Error {
        let message: String
        let isPermanent: Bool
    }

    private static func findAccelerometerService() -> Result<io_service_t, LookupFailure> {
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else {
            return .failure(LookupFailure(message: "IOKit matching failed", isPermanent: false))
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return .failure(LookupFailure(message: "No motion sensor on this Mac", isPermanent: true))
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if usage(of: service) == (targetUsagePage, targetUsage) {
                return .success(service)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return .failure(LookupFailure(message: "No motion sensor (needs an Apple Silicon MacBook)",
                                      isPermanent: true))
    }

    private static func usage(of service: io_service_t) -> (Int, Int) {
        func intProperty(_ key: String) -> Int {
            let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
            return (value as? NSNumber)?.intValue ?? -1
        }
        return (intProperty("PrimaryUsagePage"), intProperty("PrimaryUsage"))
    }

    /// Powers on the IMU by setting reporting/power-state properties on the
    /// accelerometer's `AppleSPUHIDDriver` service (or on every SPU driver as a
    /// fallback for models where the accelerometer node isn't enough).
    ///
    /// On Apple Silicon the SPU driver owns the sensor's power/reporting state;
    /// the IOHIDDevice wrapper does not. We set:
    ///   - SensorPropertyReportingState = 1  (start emitting reports)
    ///   - SensorPropertyPowerState     = 1  (power the sensor on)
    ///   - ReportInterval = 1000 (µs)        (request ~1kHz; HW clamps to ~800Hz)
    /// Properties must be CFNumber(SInt32) and set via IORegistryEntrySetCFProperty.
    /// Waking only the accelerometer avoids pushing the gyro, lid-angle and
    /// ambient-light sensors to 1 kHz too.
    private static func wakeDrivers(onlyAccelerometer: Bool) {
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if !onlyAccelerometer || usage(of: service) == (targetUsagePage, targetUsage) {
                for (key, value) in [("SensorPropertyReportingState", Int32(1)),
                                     ("SensorPropertyPowerState", Int32(1)),
                                     ("ReportInterval", Int32(1000))] {
                    var v = value
                    if let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) {
                        IORegistryEntrySetCFProperty(service, key as CFString, num)
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}

enum SlapRateDefaults {
    static let nominal = 805.0
}

// MARK: - Session

/// One open HID connection. Owns its report buffer and tears everything down on
/// its own thread after cancellation, so a stop/start cycle can never free
/// memory that a late input-report callback still references.
private final class SensorSession: @unchecked Sendable {
    enum Event {
        case firstSample(magnitude: Double)
        case rate(Double)
    }

    private static let bufferSize = 256
    private static let accelScale = 65536.0  // Q16 fixed-point
    private static let rateWindow: TimeInterval = 1.0

    private let device: IOHIDDevice
    private let buffer: UnsafeMutablePointer<UInt8>
    private let onSample: (@Sendable (Double, Double, Double) -> Void)?
    private let onEvent: @Sendable (Event) -> Void

    private let lock = NSLock()
    private var cancelled = false
    private var _lastSampleUptime: TimeInterval = 0

    // Touched only on the session thread.
    private var sampleCount = 0
    private var windowStart: TimeInterval = 0
    private var windowCount = 0

    init(device: IOHIDDevice,
         onSample: (@Sendable (Double, Double, Double) -> Void)?,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.device = device
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
        self.onSample = onSample
        self.onEvent = onEvent
    }

    var lastSampleUptime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return _lastSampleUptime
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func start() {
        // The context retains the session until the thread has closed the device.
        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, Self.bufferSize,
            { context, _, _, _, _, report, length in
                guard let context else { return }
                Unmanaged<SensorSession>.fromOpaque(context).takeUnretainedValue()
                    .handleReport(report, length: length)
            },
            context
        )

        // Service the callback on a DEDICATED thread's run loop. The main run
        // loop stalls during menu tracking and effect animations, which would
        // pause sensor delivery and drop fast slaps.
        let thread = Thread { [device, buffer] in
            let runLoop: CFRunLoop = CFRunLoopGetCurrent()
            IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            while !self.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, true)
            }
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            buffer.deallocate()
            Unmanaged<SensorSession>.fromOpaque(context).release()
        }
        thread.name = "app.macslap.accelerometer"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard let (x, y, z) = Self.decode(UnsafeBufferPointer(start: report, count: length)) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); _lastSampleUptime = now; lock.unlock()

        sampleCount += 1
        if sampleCount == 1 {
            windowStart = now
            onEvent(.firstSample(magnitude: (x * x + y * y + z * z).squareRoot()))
        } else {
            windowCount += 1
            let elapsed = now - windowStart
            if elapsed >= Self.rateWindow {
                onEvent(.rate(Double(windowCount) / elapsed))
                windowStart = now
                windowCount = 0
            }
        }

        onSample?(x, y, z)
    }

    /// Returns acceleration in g, or nil for reports that don't look like a
    /// resting-plausible accelerometer frame.
    private static func decode(_ data: UnsafeBufferPointer<UInt8>) -> (Double, Double, Double)? {
        func plausible(_ x: Double, _ y: Double, _ z: Double) -> Bool {
            let mag = (x * x + y * y + z * z).squareRoot()
            return mag > 0.2 && mag < 25.0
        }

        // BMI286: int32 Q16 XYZ at offset 6.
        if data.count >= 18 {
            let x = Double(readInt32LE(data, offset: 6)) / accelScale
            let y = Double(readInt32LE(data, offset: 10)) / accelScale
            let z = Double(readInt32LE(data, offset: 14)) / accelScale
            if plausible(x, y, z) { return (x, y, z) }
        }

        // Fallback for older layouts: int16 XYZ (1 g = 16384) near the start.
        guard data.count >= 6 else { return nil }
        for offset in 0..<min(4, data.count - 5) {
            let x = Double(readInt16LE(data, offset: offset)) / 16384.0
            let y = Double(readInt16LE(data, offset: offset + 2)) / 16384.0
            let z = Double(readInt16LE(data, offset: offset + 4)) / 16384.0
            if plausible(x, y, z) { return (x, y, z) }
        }
        return nil
    }

    private static func readInt32LE(_ data: UnsafeBufferPointer<UInt8>, offset: Int) -> Int32 {
        guard offset + 3 < data.count else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return Int32(bitPattern: b0 | b1 | b2 | b3)
    }

    private static func readInt16LE(_ data: UnsafeBufferPointer<UInt8>, offset: Int) -> Int16 {
        Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
    }
}
