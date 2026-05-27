import Foundation
import IOKit
import IOKit.hid

/// Reads raw accelerometer data from the MacBook's built-in Bosch BMI286 IMU.
///
/// Uses direct IOKit service matching for AppleSPUHIDDevice rather than
/// IOHIDManager (which requires Developer ID signing). This approach:
/// 1. Finds AppleSPUHIDDevice services via IOServiceGetMatchingServices
/// 2. Filters for the accelerometer (vendor page 0xFF00, usage 3)
/// 3. Creates an IOHIDDevice and registers an input report callback
/// 4. Wakes the sensor by setting ReportingState and PowerState
///
/// Report format (BMI286): 22 bytes per report
///   - Bytes 0-5: header/metadata
///   - Bytes 6-9: X axis (little-endian int32, Q16 fixed-point)
///   - Bytes 10-13: Y axis
///   - Bytes 14-17: Z axis
class AccelerometerReader {
    private var hidDevice: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var isListening = false
    private var decimationCounter = 0

    // Peak-hold over decimation window: captures brief slap spikes that
    // fall between sampled frames at the decimated rate.
    private var peakX: Double = 0
    private var peakY: Double = 0
    private var peakZ: Double = 0

    private let decimationFactor = 8      // 1kHz -> ~125Hz
    private let accelScale: Double = 65536.0  // Q16 fixed-point
    private let reportBufferSize = 256

    // Target device identifiers
    private let targetUsagePage = 0xFF00  // Apple vendor page
    private let targetUsage = 3           // Accelerometer

    /// Called with (x, y, z) accelerometer values in g
    var onSample: ((_ x: Double, _ y: Double, _ z: Double) -> Void)?

    /// Wake the SPU driver before opening any devices.
    /// spank uses this approach: set properties on AppleSPUHIDDriver (not the HIDDevice)
    /// so the sensor is powered up before we try to read from it.
    private func wakeSPUDrivers() {
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var svc = IOIteratorNext(it)
        while svc != 0 {
            IORegistryEntrySetCFProperty(svc, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(svc, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(svc, "ReportInterval" as CFString, 1000 as CFNumber)
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
    }

    func start() -> Bool {
        guard !isListening else { return true }

        // Wake the driver first — must happen before opening the HIDDevice
        wakeSPUDrivers()

        // Step 1: Find AppleSPUHIDDevice services
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else {
            log("Failed to create matching dictionary")
            return false
        }

        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            log("No AppleSPUHIDDevice services found")
            return false
        }
        defer { IOObjectRelease(iterator) }

        // Step 2: Find the accelerometer device (page=0xFF00, usage=3)
        var accelService: io_service_t = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
            if let dict = props?.takeRetainedValue() as? [String: Any] {
                let page = dict["PrimaryUsagePage"] as? Int ?? 0
                let usage = dict["PrimaryUsage"] as? Int ?? 0
                if page == targetUsagePage && usage == targetUsage {
                    accelService = service
                    break
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        guard accelService != 0 else {
            log("No accelerometer device found among SPU devices")
            return false
        }
        defer { IOObjectRelease(accelService) }

        // Step 3: Create IOHIDDevice from the service
        let device = IOHIDDeviceCreate(kCFAllocatorDefault, accelService)
        guard let device = device else {
            log("Failed to create IOHIDDevice")
            return false
        }

        // Step 4: Open the device
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            log("Failed to open accelerometer: \(openResult) (0x\(String(format: "%x", UInt32(bitPattern: openResult))))")
            return false
        }

        self.hidDevice = device

        // Step 5: Allocate report buffer and register callback
        reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer!,
            reportBufferSize,
            { context, result, sender, type, reportID, report, reportLength in
                guard let context = context else { return }
                let reader = Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue()
                reader.handleReport(report: report, length: reportLength)
            },
            context
        )

        // Step 6: Schedule on a dedicated background run loop thread (macOS 26: main RunLoop
        // no longer delivers IOHIDDevice reports reliably — move to background thread)
        let thread = Thread {
            guard let rl = CFRunLoopGetCurrent() else { return }
            IOHIDDeviceScheduleWithRunLoop(device, rl, CFRunLoopMode.defaultMode.rawValue)
            CFRunLoopRun()
        }
        thread.name = "com.slapmacpro.accel"
        thread.start()

        // Step 7: Wake the sensor (after scheduling so properties take effect)
        IOHIDDeviceSetProperty(device, "ReportInterval" as CFString, 1000 as CFNumber)
        IOHIDDeviceSetProperty(device, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
        IOHIDDeviceSetProperty(device, "SensorPropertyPowerState" as CFString, 1 as CFNumber)

        isListening = true
        log("Accelerometer started (~\(1000/decimationFactor)Hz after decimation)")
        return true
    }

    func stop() {
        guard isListening else { return }
        if let device = hidDevice {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidDevice = nil
        if let buf = reportBuffer {
            buf.deallocate()
            reportBuffer = nil
        }
        isListening = false
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: Int) {
        decimationCounter += 1

        // M5 DIAGNOSTIC: log every 125th report (once per second) so we can see raw data
        if decimationCounter % 125 == 0 {
            let data = UnsafeBufferPointer(start: report, count: length)
            let hex = (0..<min(length, 22)).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
            let x32 = length >= 18 ? readInt32LE(data, offset: 6) : 0
            let y32 = length >= 18 ? readInt32LE(data, offset: 10) : 0
            let z32 = length >= 18 ? readInt32LE(data, offset: 14) : 0
            let mag32 = sqrt(pow(Double(x32)/accelScale, 2) + pow(Double(y32)/accelScale, 2) + pow(Double(z32)/accelScale, 2))
            log("[DIAG] len=\(length) hex=[\(hex)] int32-mag=\(String(format: "%.4f", mag32))g (raw x=\(x32) y=\(y32) z=\(z32))")
        }

        let data = UnsafeBufferPointer(start: report, count: length)

        // Try BMI286 format: 22-byte reports, int32 XYZ at offset 6
        if length >= 18 {
            let x = readInt32LE(data, offset: 6)
            let y = readInt32LE(data, offset: 10)
            let z = readInt32LE(data, offset: 14)

            let gx = Double(x) / accelScale
            let gy = Double(y) / accelScale
            let gz = Double(z) / accelScale

            let mag = sqrt(gx * gx + gy * gy + gz * gz)
            if mag > 0.3 && mag < 10.0 {
                // Track peak magnitude in each decimation window.
                // A slap is a brief high-amplitude spike — without this, 7 of
                // every 8 samples are discarded and the peak is usually missed.
                if abs(gx) > abs(peakX) { peakX = gx }
                if abs(gy) > abs(peakY) { peakY = gy }
                if abs(gz) > abs(peakZ) { peakZ = gz }

                if decimationCounter % decimationFactor == 0 {
                    let (px, py, pz) = (peakX, peakY, peakZ)
                    peakX = gx; peakY = gy; peakZ = gz  // reset to current
                    onSample?(px, py, pz)
                }
                return
            }
        }

        // Fallback: int16 format (no peak-hold — less critical path)
        guard decimationCounter % decimationFactor == 0 else { return }
        guard length >= 6 else { return }
        for offset in 0..<min(4, length - 5) {
            let rawX = Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
            let rawY = Int16(bitPattern: UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8))
            let rawZ = Int16(bitPattern: UInt16(data[offset + 4]) | (UInt16(data[offset + 5]) << 8))

            let gx = Double(rawX) / 16384.0
            let gy = Double(rawY) / 16384.0
            let gz = Double(rawZ) / 16384.0

            let mag = sqrt(gx * gx + gy * gy + gz * gz)
            if mag > 0.3 && mag < 10.0 {
                onSample?(gx, gy, gz)
                return
            }
        }
    }

    private func readInt32LE(_ data: UnsafeBufferPointer<UInt8>, offset: Int) -> Int32 {
        guard offset + 3 < data.count else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return Int32(bitPattern: b0 | b1 | b2 | b3)
    }
}
