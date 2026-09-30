import Foundation
import IOKit
import IOKit.usb
import AppKit

/// Monitors USB/Thunderbolt device plug/unplug events.
/// Uses multiple strategies for Apple Silicon USB-C compatibility:
/// 1. IOKit publish/terminated notifications for IOUSBHostDevice
/// 2. NSWorkspace DiskMount/Unmount notifications
/// 3. Polling IOServiceGetMatchingServices as a fallback
///
/// One physical plug usually trips several of these (and publishes a device
/// plus its interfaces), so events are debounced into a single reaction.
@MainActor
final class USBMonitor {
    private static let debounceInterval: TimeInterval = 1.5

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var isRunning = false
    private var pollTimer: Timer?
    private var lastDeviceCount: Int = 0
    private var lastEventTime: Date = .distantPast

    var onUSBEvent: (() -> Void)?

    func start() {
        guard !isRunning else { return }

        // Strategy 1: IOKit notifications
        setupIOKitNotifications()

        // Strategy 2: NSWorkspace volume mount/unmount (catches USB drives)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(deviceMounted), name: NSWorkspace.didMountNotification, object: nil)
        ws.addObserver(self, selector: #selector(deviceMounted), name: NSWorkspace.didUnmountNotification, object: nil)

        // Strategy 3: Poll for device count changes every 2 seconds
        // This is the most reliable fallback for M5 Thunderbolt USB-C
        lastDeviceCount = countUSBDevices()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForDeviceChanges() }
        }
        pollTimer?.tolerance = 0.5

        isRunning = true
        log("USB monitor started (IOKit + NSWorkspace + polling)")
    }

    func stop() {
        guard isRunning else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        for iter in iterators { IOObjectRelease(iter) }
        iterators.removeAll()
        if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isRunning = false
        log("USB monitor stopped")
    }

    private func emit(_ source: String) {
        // Keep the device count in sync so the poller doesn't re-report this change.
        lastDeviceCount = countUSBDevices()
        let now = Date()
        guard now.timeIntervalSince(lastEventTime) >= Self.debounceInterval else { return }
        lastEventTime = now
        log("USB event (\(source))")
        onUSBEvent?()
    }

    private func setupIOKitNotifications() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else { return }

        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let watchClasses = ["IOUSBHostDevice", "IOUSBHostInterface"]

        for className in watchClasses {
            for notification in [kIOPublishNotification, kIOTerminatedNotification] {
                guard let matching = IOServiceMatching(className) else { continue }
                var iter: io_iterator_t = 0
                let kr = IOServiceAddMatchingNotification(
                    notifyPort, notification, matching,
                    { (refcon, iterator) in
                        var found = false
                        var entry = IOIteratorNext(iterator)
                        while entry != 0 {
                            found = true
                            IOObjectRelease(entry)
                            entry = IOIteratorNext(iterator)
                        }
                        guard found, let refcon else { return }
                        // Delivered on the main run loop (source added above).
                        let monitor = Unmanaged<USBMonitor>.fromOpaque(refcon).takeUnretainedValue()
                        MainActor.assumeIsolated { monitor.emit("IOKit notification") }
                    },
                    selfPtr, &iter
                )
                if kr == KERN_SUCCESS {
                    // Drain the initial matches so existing devices don't fire.
                    var e = IOIteratorNext(iter)
                    while e != 0 { IOObjectRelease(e); e = IOIteratorNext(iter) }
                    iterators.append(iter)
                }
            }
        }
    }

    @objc private func deviceMounted(_ notification: Notification) {
        emit("volume mount/unmount")
    }

    private func countUSBDevices() -> Int {
        var total = 0
        for cls in ["IOUSBHostDevice", "IOUSBHostInterface", "AppleUSBHostPort"] {
            var iter: io_iterator_t = 0
            guard let matching = IOServiceMatching(cls) else { continue }
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS {
                var svc = IOIteratorNext(iter)
                while svc != 0 { total += 1; IOObjectRelease(svc); svc = IOIteratorNext(iter) }
                IOObjectRelease(iter)
            }
        }
        return total
    }

    private func checkForDeviceChanges() {
        let current = countUSBDevices()
        guard current != lastDeviceCount else { return }
        let previous = lastDeviceCount
        emit("poll: \(previous) -> \(current) devices")
    }
}
