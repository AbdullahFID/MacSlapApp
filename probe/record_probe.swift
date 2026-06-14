import Foundation
import IOKit
import IOKit.hid

// Records linear-accel magnitude + jerk "performance index" from the IMU so we
// can empirically separate typing from real slaps.
// usage: record_probe <label> <seconds>

let args = CommandLine.arguments
let label = args.count > 1 ? args[1] : "data"
let seconds = args.count > 2 ? (Double(args[2]) ?? 10.0) : 10.0
let csvPath = "/tmp/slap_rec_\(label).csv"

let NATIVE_RATE = 805.0  // measured ~805 Hz

func wakeDrivers() {
    guard let m = IOServiceMatching("AppleSPUHIDDriver") else { return }
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(it) }
    var svc = IOIteratorNext(it)
    while svc != 0 {
        for (k, v) in [("SensorPropertyReportingState", Int32(1)),
                       ("SensorPropertyPowerState", Int32(1)),
                       ("ReportInterval", Int32(1000))] {
            var val = v
            let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &val)
            IORegistryEntrySetCFProperty(svc, k as CFString, num)
        }
        IOObjectRelease(svc)
        svc = IOIteratorNext(it)
    }
}

func i32(_ b: UnsafePointer<UInt8>, _ o: Int) -> Int32 {
    let v = UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
    return Int32(bitPattern: v)
}

final class Rec {
    var gx = 0.0, gy = 0.0, gz = 0.0
    var inited = false
    var prevLx = 0.0, prevLy = 0.0, prevLz = 0.0
    var havePrev = false
    var linMag: [Double] = []
    var pi: [Double] = []          // jerk performance index (g/s)
    var top: [(Double, Double)] = []   // (linMag, pi) of biggest hits
    let gAlpha = 0.9975            // gravity EMA (~0.5s tau @ 805Hz)
    var n = 0
    var secPeak = 0.0
    var secPeakJerk = 0.0

    func add(_ x: Double, _ y: Double, _ z: Double) {
        n += 1
        if !inited { gx = x; gy = y; gz = z; inited = true }
        gx = gAlpha * gx + (1 - gAlpha) * x
        gy = gAlpha * gy + (1 - gAlpha) * y
        gz = gAlpha * gz + (1 - gAlpha) * z
        let lx = x - gx, ly = y - gy, lz = z - gz
        let mag = (lx*lx + ly*ly + lz*lz).squareRoot()
        var p = 0.0
        if havePrev {
            p = (abs(lx - prevLx) + abs(ly - prevLy) + abs(lz - prevLz)) * NATIVE_RATE
        }
        prevLx = lx; prevLy = ly; prevLz = lz; havePrev = true
        linMag.append(mag)
        pi.append(p)
        if mag > secPeak { secPeak = mag; secPeakJerk = p }
        if mag > 0.04 { top.append((mag, p)) }
    }
}
let rec = Rec()

func pct(_ a: [Double], _ q: Double) -> Double {
    if a.isEmpty { return 0 }
    let s = a.sorted()
    let idx = Int(q * Double(s.count - 1))
    return s[idx]
}
func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0,+)/Double(a.count) }
func std(_ a: [Double]) -> Double {
    if a.count < 2 { return 0 }
    let m = mean(a); return (a.map{($0-m)*($0-m)}.reduce(0,+)/Double(a.count)).squareRoot()
}

// ---- open device ----
wakeDrivers()
guard let matching = IOServiceMatching("AppleSPUHIDDevice") else { exit(1) }
var iter: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { exit(1) }
var accel: io_service_t = 0
var s = IOIteratorNext(iter)
while s != 0 {
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0)
    if let d = props?.takeRetainedValue() as? [String: Any],
       (d["PrimaryUsagePage"] as? Int) == 0xFF00, (d["PrimaryUsage"] as? Int) == 3 {
        accel = s; IOObjectRetain(s)
    }
    IOObjectRelease(s); s = IOIteratorNext(iter)
}
IOObjectRelease(iter)
guard accel != 0, let device = IOHIDDeviceCreate(kCFAllocatorDefault, accel) else { print("no device"); exit(1) }
guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { print("open failed"); exit(1) }
wakeDrivers()

let bufSize = 256
let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
IOHIDDeviceRegisterInputReportCallback(device, buffer, bufSize, { _,_,_,_,_, report, length in
    if Int(length) >= 18 {
        let x = Double(i32(report, 6)) / 65536.0
        let y = Double(i32(report, 10)) / 65536.0
        let z = Double(i32(report, 14)) / 65536.0
        let m = (x*x+y*y+z*z).squareRoot()
        if m > 0.3 && m < 16.0 { rec.add(x, y, z) }
    }
}, nil)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

print("=== RECORDING '\(label)' for \(Int(seconds))s — GO ===")
let start = Date()
var tick = 0
while Date().timeIntervalSince(start) < seconds {
    CFRunLoopRunInMode(.defaultMode, 0.2, true)
    let e = Int(Date().timeIntervalSince(start))
    if e != tick {
        tick = e
        print(String(format: "  t=%2ds  peak1s=%.4fg  jerk@peak=%.1f", e, rec.secPeak, rec.secPeakJerk))
        rec.secPeak = 0; rec.secPeakJerk = 0
    }
}
IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

// ---- CSV ----
var csv = "i,linMag,pi\n"
for i in 0..<rec.linMag.count { csv += "\(i),\(rec.linMag[i]),\(rec.pi[i])\n" }
try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8)

// ---- summary ----
let dur = Date().timeIntervalSince(start)
print("\n=== STATS [\(label)] ===")
print(String(format: "samples=%d  dur=%.1fs  rate=%.0fHz  csv=%@", rec.n, dur, Double(rec.n)/dur, csvPath))
print("linMag(g):  mean=\(String(format: "%.4f", mean(rec.linMag)))  std=\(String(format: "%.4f", std(rec.linMag)))")
print(String(format: "  p50=%.4f p90=%.4f p99=%.4f p99.9=%.4f MAX=%.4f",
             pct(rec.linMag,0.50), pct(rec.linMag,0.90), pct(rec.linMag,0.99), pct(rec.linMag,0.999), pct(rec.linMag,1.0)))
print("jerkPI(g/s): mean=\(String(format: "%.2f", mean(rec.pi)))  std=\(String(format: "%.2f", std(rec.pi)))")
print(String(format: "  p50=%.2f p90=%.2f p99=%.2f p99.9=%.2f MAX=%.2f",
             pct(rec.pi,0.50), pct(rec.pi,0.90), pct(rec.pi,0.99), pct(rec.pi,0.999), pct(rec.pi,1.0)))
let topSorted = rec.top.sorted { $0.0 > $1.0 }.prefix(8)
print("top hits (linMag g, jerkPI g/s):")
for t in topSorted { print(String(format: "   %.4f   %.1f", t.0, t.1)) }
print("[DONE]")
