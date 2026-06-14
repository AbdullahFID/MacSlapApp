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
    private var acceptedSamples = 0

    private let decimationFactor = 1      // full native rate (~805Hz) for the impact detector
    private let accelScale: Double = 65536.0  // Q16 fixed-point
    private let reportBufferSize = 256

    // Target device identifiers
    private let targetUsagePage = 0xFF00  // Apple vendor page
    private let targetUsage = 3           // Accelerometer

    /// Called with (x, y, z) accelerometer values in g
    var onSample: ((_ x: Double, _ y: Double, _ z: Double) -> Void)?

    func start() -> Bool {
        guard !isListening else { return true }

        // Step 0: Wake the SPU sensor drivers up front so the IMU is already
        // streaming by the time we open the device and attach our callback.
        wakeSensorDrivers()

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

        // Step 5: Wake the sensor AGAIN now that the device is open.
        // CRITICAL: power/reporting state lives on the AppleSPUHIDDriver service,
        // NOT on the IOHIDDevice object. Setting these via IOHIDDeviceSetProperty
        // is silently ignored on Apple Silicon and the IMU never streams a single
        // report (open succeeds, but the input-report callback never fires).
        wakeSensorDrivers()

        // Step 6: Allocate report buffer and register callback
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

        // Step 7: Schedule on run loop
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        isListening = true
        log("Accelerometer started (~805Hz full rate)")
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

    /// Powers on the IMU by setting reporting/power-state properties on every
    /// `AppleSPUHIDDriver` service in the IORegistry.
    ///
    /// This is THE step that makes the sensor stream. On Apple Silicon the SPU
    /// driver owns the sensor's power/reporting state; the IOHIDDevice wrapper
    /// does not. We set:
    ///   - SensorPropertyReportingState = 1  (start emitting reports)
    ///   - SensorPropertyPowerState     = 1  (power the sensor on)
    ///   - ReportInterval = 1000 (µs)        (request ~1kHz; HW clamps to ~800Hz)
    /// Properties must be CFNumber(SInt32) and set via IORegistryEntrySetCFProperty.
    private func wakeSensorDrivers() {
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            for (key, value) in [("SensorPropertyReportingState", Int32(1)),
                                 ("SensorPropertyPowerState", Int32(1)),
                                 ("ReportInterval", Int32(1000))] {
                var v = value
                if let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) {
                    IORegistryEntrySetCFProperty(service, key as CFString, num)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: Int) {
        decimationCounter += 1
        guard decimationCounter % decimationFactor == 0 else { return }

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
            if mag > 0.2 && mag < 25.0 {
                noteStreaming(mag)
                onSample?(gx, gy, gz)
                return
            }
        }

        // Fallback: int16 format
        guard length >= 6 else { return }
        for offset in 0..<min(4, length - 5) {
            let rawX = Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
            let rawY = Int16(bitPattern: UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8))
            let rawZ = Int16(bitPattern: UInt16(data[offset + 4]) | (UInt16(data[offset + 5]) << 8))

            let gx = Double(rawX) / 16384.0
            let gy = Double(rawY) / 16384.0
            let gz = Double(rawZ) / 16384.0

            let mag = sqrt(gx * gx + gy * gy + gz * gz)
            if mag > 0.2 && mag < 25.0 {
                noteStreaming(mag)
                onSample?(gx, gy, gz)
                return
            }
        }
    }

    /// Logs the first streamed sample and a sparse keep-alive so /tmp/slapmacpro.log
    /// positively confirms the IMU is delivering data.
    private func noteStreaming(_ mag: Double) {
        acceptedSamples += 1
        if acceptedSamples == 1 {
            log("Accelerometer streaming OK — first sample mag=\(String(format: "%.3f", mag))g")
        } else if acceptedSamples % 48000 == 0 {
            log("Accelerometer alive: \(acceptedSamples) samples")
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
