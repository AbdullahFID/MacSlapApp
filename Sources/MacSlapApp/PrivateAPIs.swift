import Foundation
import CoreGraphics
import IOKit

// Private frameworks are loaded at runtime with dlopen/dlsym instead of being
// linked, so if Apple moves or removes one the app still launches and only the
// affected effect degrades.

private func loadFramework(_ name: String) -> UnsafeMutableRawPointer? {
    let path = "/System/Library/PrivateFrameworks/\(name).framework/\(name)"
    let handle = dlopen(path, RTLD_LAZY)
    if handle == nil { log("dlopen failed for \(name)") }
    return handle
}

private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
    guard let handle, let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: type)
}

// MARK: - DisplayServices (hardware backlight)

enum DisplayServicesAPI {
    typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightnessFunc = @convention(c) (CGDirectDisplayID) -> Bool

    private static let handle = loadFramework("DisplayServices")

    static let getBrightness = symbol(handle, "DisplayServicesGetBrightness", as: GetBrightnessFunc.self)
    static let setBrightness = symbol(handle, "DisplayServicesSetBrightness", as: SetBrightnessFunc.self)
    static let canChangeBrightness = symbol(handle, "DisplayServicesCanChangeBrightness",
                                            as: CanChangeBrightnessFunc.self)

    /// The built-in panel, which is the only display DisplayServices can dim.
    /// Falls back to the main display if no built-in panel is online (clamshell).
    static func builtInDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        let online = ids.prefix(Int(count))
        let candidate: CGDirectDisplayID = online.first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
        if let canChange = canChangeBrightness, !canChange(candidate) { return nil }
        return candidate
    }
}

// MARK: - MultitouchSupport (Force Touch trackpad actuator)

/// Drives the trackpad's Taptic Engine directly. Unlike NSHapticFeedbackManager,
/// which only plays while a finger is resting on the trackpad, the actuator
/// fires regardless — so a slap on the lid can still be felt.
enum MultitouchAPI {
    typealias CreateFunc = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    typealias OpenFunc = @convention(c) (CFTypeRef) -> Int32
    typealias CloseFunc = @convention(c) (CFTypeRef) -> Int32
    typealias ActuateFunc = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    private static let handle = loadFramework("MultitouchSupport")

    static let createActuator = symbol(handle, "MTActuatorCreateFromDeviceID", as: CreateFunc.self)
    static let open = symbol(handle, "MTActuatorOpen", as: OpenFunc.self)
    static let close = symbol(handle, "MTActuatorClose", as: CloseFunc.self)
    static let actuate = symbol(handle, "MTActuatorActuate", as: ActuateFunc.self)

    static var isAvailable: Bool {
        createActuator != nil && open != nil && close != nil && actuate != nil
    }

    /// Multitouch ID of the built-in trackpad, if it supports actuation.
    static func builtInTrackpadID() -> UInt64? {
        guard let matching = IOServiceMatching("AppleMultitouchDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var fallback: UInt64?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  (dict["ActuationSupported"] as? Bool) == true,
                  let id = (dict["Multitouch ID"] as? NSNumber)?.uint64Value, id != 0
            else { continue }
            if (dict["MT Built-In"] as? Bool) == true { return id }
            fallback = fallback ?? id
        }
        return fallback
    }
}
