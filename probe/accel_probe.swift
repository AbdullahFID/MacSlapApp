import Foundation
import IOKit
import IOKit.hid

// =====================================================================
// SlapMac Accelerometer Probe
// Standalone diagnostic: confirms whether raw HID reports flow from the
// built-in Bosch BMI286 IMU, and dumps raw bytes so we can decode the
// real per-axis layout on this machine (Mac17,2 / M5 / macOS 26).
// =====================================================================

let RUN_SECONDS = 8.0

// ---- shared state touched by the C report callback ----
final class Capture {
    var count = 0
    var lengths = Set<Int>()
    var raw: [[UInt8]] = []          // keep first N raw reports
    let keepFirst = 24
    var appParseMagMin = Double.greatestFiniteMagnitude
    var appParseMagMax = 0.0
    var appParseMagSum = 0.0
    var appParseMagN = 0
    var lastReport: [UInt8] = []
}
let cap = Capture()

func readInt32LE(_ b: [UInt8], _ o: Int) -> Int32 {
    guard o + 3 < b.count else { return 0 }
    let v = UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
    return Int32(bitPattern: v)
}
func readInt16LE(_ b: [UInt8], _ o: Int) -> Int16 {
    guard o + 1 < b.count else { return 0 }
    return Int16(bitPattern: UInt16(b[o]) | (UInt16(b[o+1]) << 8))
}
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

// Wake the sensor by setting power/reporting properties on the DRIVER
// (AppleSPUHIDDriver) service — NOT the HID device object. This is the fix.
func wakeDrivers() {
    guard let m = IOServiceMatching("AppleSPUHIDDriver") else { print("[WAKE] no matching dict"); return }
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == KERN_SUCCESS else {
        print("[WAKE] IOServiceGetMatchingServices failed"); return
    }
    defer { IOObjectRelease(it) }
    var count = 0
    var okSets = 0
    var svc = IOIteratorNext(it)
    while svc != 0 {
        for (k, v) in [("SensorPropertyReportingState", Int32(1)),
                       ("SensorPropertyPowerState", Int32(1)),
                       ("ReportInterval", Int32(1000))] {
            var val = v
            let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &val)
            let kr = IORegistryEntrySetCFProperty(svc, k as CFString, num)
            if kr == KERN_SUCCESS { okSets += 1 }
        }
        IOObjectRelease(svc)
        svc = IOIteratorNext(it)
        count += 1
    }
    print("[WAKE] AppleSPUHIDDriver services=\(count) successful property sets=\(okSets)")
}

func handle(_ bytes: [UInt8]) {
    cap.count += 1
    cap.lengths.insert(bytes.count)
    cap.lastReport = bytes
    if cap.raw.count < cap.keepFirst { cap.raw.append(bytes) }
    // Reproduce the app's exact parse: int32 LE at 6/10/14, scale 65536
    if bytes.count >= 18 {
        let gx = Double(readInt32LE(bytes, 6)) / 65536.0
        let gy = Double(readInt32LE(bytes, 10)) / 65536.0
        let gz = Double(readInt32LE(bytes, 14)) / 65536.0
        let mag = (gx*gx + gy*gy + gz*gz).squareRoot()
        cap.appParseMagMin = min(cap.appParseMagMin, mag)
        cap.appParseMagMax = max(cap.appParseMagMax, mag)
        cap.appParseMagSum += mag
        cap.appParseMagN += 1
    }
}

// ---------------------------------------------------------------------
print("=== SlapMac Accelerometer Probe ===\n")

// 1. TCC / Input Monitoring access
let chk = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
let chkStr: String
switch chk {
case kIOHIDAccessTypeGranted: chkStr = "GRANTED"
case kIOHIDAccessTypeDenied:  chkStr = "DENIED"
default:                       chkStr = "UNKNOWN(\(chk.rawValue))"
}
print("[TCC] IOHIDCheckAccess(ListenEvent) = \(chkStr)")
let req = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
print("[TCC] IOHIDRequestAccess(ListenEvent) = \(req ? "true(granted)" : "false(denied/prompted)")\n")

// 1b. Wake the SPU sensor drivers (the real fix)
wakeDrivers()
print("")

// 2. Enumerate AppleSPUHIDDevice services
guard let matching = IOServiceMatching("AppleSPUHIDDevice") else {
    print("FATAL: could not create matching dict"); exit(1)
}
var iter: io_iterator_t = 0
let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
guard kr == KERN_SUCCESS else { print("FATAL: IOServiceGetMatchingServices kr=\(kr)"); exit(1) }

var accelService: io_service_t = 0
print("[SCAN] AppleSPUHIDDevice nodes:")
var svc = IOIteratorNext(iter)
while svc != 0 {
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0)
    if let d = props?.takeRetainedValue() as? [String: Any] {
        let page = d["PrimaryUsagePage"] as? Int ?? -1
        let usage = d["PrimaryUsage"] as? Int ?? -1
        let size = d["MaxInputReportSize"] as? Int ?? -1
        let vid = d["VendorID"] as? Int ?? -1
        print(String(format: "   page=0x%04x usage=%-3d reportSize=%-4d vid=%d", page, usage, size, vid))
        if page == 0xFF00 && usage == 3 && accelService == 0 {
            accelService = svc
            IOObjectRetain(svc)   // keep it; we release the iterator's ref below
        }
    }
    IOObjectRelease(svc)
    svc = IOIteratorNext(iter)
}
IOObjectRelease(iter)

guard accelService != 0 else { print("\nFATAL: no accel device (page 0xFF00 usage 3) found"); exit(1) }
print("\n[OK] accelerometer service matched (page 0xFF00 usage 3)\n")

// 3. Create IOHIDDevice + open
guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, accelService) else {
    print("FATAL: IOHIDDeviceCreate returned nil"); exit(1)
}
let openRes = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
print(String(format: "[OPEN] IOHIDDeviceOpen = 0x%08x (%@)", UInt32(bitPattern: openRes),
             openRes == kIOReturnSuccess ? "success" : "FAILURE"))

// 4. (sensor already woken via driver above; re-wake after open too, belt & suspenders)
wakeDrivers()

// 5. Register input report callback + schedule on runloop
let bufSize = 256
let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
IOHIDDeviceRegisterInputReportCallback(
    device, buffer, bufSize,
    { _, _, _, _, _, report, length in
        let n = Int(length)
        var b = [UInt8](repeating: 0, count: n)
        for i in 0..<n { b[i] = report[i] }
        handle(b)
    },
    nil
)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

// 6. Run loop for RUN_SECONDS, printing progress each second
print("[RUN] listening \(Int(RUN_SECONDS))s — move/tap the laptop now...\n")
let start = Date()
var lastTick = 0
while Date().timeIntervalSince(start) < RUN_SECONDS {
    CFRunLoopRunInMode(.defaultMode, 0.25, true)
    let elapsed = Int(Date().timeIntervalSince(start))
    if elapsed != lastTick {
        lastTick = elapsed
        print("   t=\(elapsed)s  reports=\(cap.count)")
    }
}

// 7. Results
print("\n=== RESULTS ===")
print("total reports : \(cap.count)")
print("report length(s): \(cap.lengths.sorted())")
if cap.appParseMagN > 0 {
    let avg = cap.appParseMagSum / Double(cap.appParseMagN)
    print(String(format: "app-parse magnitude (int32@6/10/14 /65536): min=%.4f avg=%.4f max=%.4f g",
                 cap.appParseMagMin, avg, cap.appParseMagMax))
    print("  (at rest a CORRECT parse should sit near ~1.0g)")
}

if cap.raw.isEmpty {
    print("\nNO REPORTS RECEIVED. Either the sensor isn't streaming to our client,")
    print("or access is blocked. See [TCC] line above.")
} else {
    print("\n--- raw report hex (first \(cap.raw.count)) ---")
    for (i, r) in cap.raw.enumerated() { print(String(format: "#%02d [%2d] %@", i, r.count, hex(r))) }

    // Decode-assist on the last (at-rest) report: scan offsets for ~1g axis
    let b = cap.lastReport
    print("\n--- decode-assist on last report (\(b.count) bytes) ---")
    print("hex: \(hex(b))")
    print("int16 LE candidates (value, /16384 g, /1024 g, /2048 g):")
    var o = 0
    while o + 1 < b.count {
        let v = readInt16LE(b, o)
        print(String(format: "  off %2d: %7d   %+.3f   %+.3f   %+.3f", o, v,
                     Double(v)/16384.0, Double(v)/1024.0, Double(v)/2048.0))
        o += 2
    }
    print("int32 LE candidates (value, /65536 g, /1e6 g):")
    o = 0
    while o + 3 < b.count {
        let v = readInt32LE(b, o)
        print(String(format: "  off %2d: %12d   %+.4f   %+.4f", o, v,
                     Double(v)/65536.0, Double(v)/1_000_000.0))
        o += 1
    }
}

IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
print("\n[DONE]")
