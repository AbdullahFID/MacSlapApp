import Foundation
import SlapCore

enum CooldownOption: Double, CaseIterable {
    case none = 0.0
    case fast = 0.35
    case medium = 0.75
    case long = 1.0
    case veryLong = 2.0

    var displayName: String {
        switch self {
        case .none: return "None"
        case .fast: return "Fast (0.35s)"
        case .medium: return "Medium (0.75s)"
        case .long: return "Slow (1.0s)"
        case .veryLong: return "Very Slow (2.0s)"
        }
    }

    var interval: Double { rawValue }
}

enum SnoozeOption: CaseIterable {
    case fifteenMinutes, oneHour, untilTomorrow

    var displayName: String {
        switch self {
        case .fifteenMinutes: return "For 15 Minutes"
        case .oneHour: return "For 1 Hour"
        case .untilTomorrow: return "Until Tomorrow"
        }
    }

    func endDate(from now: Date = Date()) -> Date {
        switch self {
        case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            let cal = Calendar.current
            return cal.nextDate(after: now, matching: DateComponents(hour: 6), matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(12 * 60 * 60)
        }
    }
}

/// UserDefaults-backed settings. Keys from 2.x are kept so existing values carry over.
@MainActor
final class SettingsStore {
    private let defaults: UserDefaults

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.isEnabled) } }
    var voicePack: VoicePack { didSet { defaults.set(voicePack.rawValue, forKey: Key.voicePack) } }
    var sensitivity: SensitivityLevel { didSet { defaults.set(sensitivity.rawValue, forKey: Key.sensitivity) } }
    var cooldownInterval: Double { didSet { defaults.set(cooldownInterval, forKey: Key.cooldown) } }
    var dynamicVolume: Bool { didSet { defaults.set(dynamicVolume, forKey: Key.dynamicVolume) } }
    var showCountInMenuBar: Bool { didSet { defaults.set(showCountInMenuBar, forKey: Key.showCount) } }
    var volume: Float { didSet { defaults.set(volume, forKey: Key.volume) } }

    var screenFlashEnabled: Bool { didSet { defaults.set(screenFlashEnabled, forKey: Key.screenFlash) } }
    var screenShakeEnabled: Bool { didSet { defaults.set(screenShakeEnabled, forKey: Key.screenShake) } }
    var brightnessFlashEnabled: Bool { didSet { defaults.set(brightnessFlashEnabled, forKey: Key.brightness) } }
    var hapticFeedbackEnabled: Bool { didSet { defaults.set(hapticFeedbackEnabled, forKey: Key.haptic) } }
    var usbMoanerEnabled: Bool { didSet { defaults.set(usbMoanerEnabled, forKey: Key.usbMoaner) } }

    var shakeIntensity: Double { didSet { defaults.set(shakeIntensity, forKey: Key.shakeIntensity) } }
    var brightnessFlashIntensity: Double { didSet { defaults.set(brightnessFlashIntensity, forKey: Key.brightnessIntensity) } }
    var screenFlashIntensity: Double { didSet { defaults.set(screenFlashIntensity, forKey: Key.flashIntensity) } }
    var hapticIntensity: Double { didSet { defaults.set(hapticIntensity, forKey: Key.hapticIntensity) } }

    var customSoundsFolder: URL? {
        didSet { defaults.set(customSoundsFolder?.path, forKey: Key.customSoundsPath) }
    }
    var snoozeUntil: Date? { didSet { defaults.set(snoozeUntil, forKey: Key.snoozeUntil) } }
    var lastUpdateCheck: Date? { didSet { defaults.set(lastUpdateCheck, forKey: Key.lastUpdateCheck) } }
    /// Set once the first-launch login item registration has happened, so a
    /// user who later turns it off isn't re-enrolled.
    var loginItemConfigured: Bool { didSet { defaults.set(loginItemConfigured, forKey: Key.loginItemConfigured) } }

    // Stats
    private(set) var totalSlapCount: Int { didSet { defaults.set(totalSlapCount, forKey: Key.totalSlapCount) } }
    private(set) var hardestSlap: Double { didSet { defaults.set(hardestSlap, forKey: Key.hardestSlap) } }
    private var todayCountStorage: Int { didSet { defaults.set(todayCountStorage, forKey: Key.todayCount) } }
    private var todayKey: String { didSet { defaults.set(todayKey, forKey: Key.todayKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyDomains(into: defaults)

        let d = defaults
        isEnabled = d.object(forKey: Key.isEnabled) as? Bool ?? true
        voicePack = VoicePack(rawValue: d.string(forKey: Key.voicePack) ?? "") ?? .sexy
        sensitivity = SensitivityLevel(rawValue: d.object(forKey: Key.sensitivity) as? Int ?? -1) ?? .medium
        cooldownInterval = d.object(forKey: Key.cooldown) as? Double ?? 0.75
        dynamicVolume = d.object(forKey: Key.dynamicVolume) as? Bool ?? true
        showCountInMenuBar = d.object(forKey: Key.showCount) as? Bool ?? true
        volume = d.object(forKey: Key.volume) as? Float ?? 0.8

        screenFlashEnabled = d.object(forKey: Key.screenFlash) as? Bool ?? false
        screenShakeEnabled = d.object(forKey: Key.screenShake) as? Bool ?? false
        brightnessFlashEnabled = d.object(forKey: Key.brightness) as? Bool ?? false
        hapticFeedbackEnabled = d.object(forKey: Key.haptic) as? Bool ?? true
        usbMoanerEnabled = d.object(forKey: Key.usbMoaner) as? Bool ?? false

        shakeIntensity = d.object(forKey: Key.shakeIntensity) as? Double ?? 0.7
        brightnessFlashIntensity = d.object(forKey: Key.brightnessIntensity) as? Double ?? 0.5
        screenFlashIntensity = d.object(forKey: Key.flashIntensity) as? Double ?? 0.5
        hapticIntensity = d.object(forKey: Key.hapticIntensity) as? Double ?? 0.7

        customSoundsFolder = d.string(forKey: Key.customSoundsPath).map { URL(fileURLWithPath: $0, isDirectory: true) }
        snoozeUntil = d.object(forKey: Key.snoozeUntil) as? Date
        lastUpdateCheck = d.object(forKey: Key.lastUpdateCheck) as? Date
        loginItemConfigured = d.bool(forKey: Key.loginItemConfigured)

        totalSlapCount = d.integer(forKey: Key.totalSlapCount)
        hardestSlap = d.double(forKey: Key.hardestSlap)
        todayCountStorage = d.integer(forKey: Key.todayCount)
        todayKey = d.string(forKey: Key.todayKey) ?? ""
    }

    // MARK: - Derived state

    var isSnoozed: Bool {
        guard let until = snoozeUntil else { return false }
        return until > Date()
    }

    var todayCount: Int {
        todayKey == Self.dayKey(for: Date()) ? todayCountStorage : 0
    }

    func recordSlap(magnitude: Double) {
        let key = Self.dayKey(for: Date())
        if key != todayKey {
            todayKey = key
            todayCountStorage = 0
        }
        todayCountStorage += 1
        totalSlapCount += 1
        if magnitude > hardestSlap { hardestSlap = magnitude }
    }

    func resetStats() {
        totalSlapCount = 0
        hardestSlap = 0
        todayCountStorage = 0
    }

    private static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Migration

    /// 2.x ran as a bare executable, so its defaults live in domains named
    /// after the binary. Copy them into the app's domain once, preferring the
    /// install with the most slaps.
    private static func migrateLegacyDomains(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: Key.migratedLegacyDomains) else { return }
        defer { defaults.set(true, forKey: Key.migratedLegacyDomains) }

        let current = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let candidates = ["SlapMacPro", "SlapMacClone"]
            .filter { $0 != current }
            .compactMap { UserDefaults.standard.persistentDomain(forName: $0) }
            .sorted { ($0[Key.totalSlapCount] as? Int ?? 0) > ($1[Key.totalSlapCount] as? Int ?? 0) }

        guard let best = candidates.first else { return }
        var imported = 0
        for (key, value) in best where Key.migratable.contains(key) && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            imported += 1
        }
        log("Imported \(imported) settings from a previous SlapMacPro install")
    }

    private enum Key {
        static let isEnabled = "isEnabled"
        static let voicePack = "voicePack"
        static let sensitivity = "sensitivity"
        static let cooldown = "cooldown"
        static let dynamicVolume = "dynamicVolume"
        static let totalSlapCount = "totalSlapCount"
        static let showCount = "showCountInMenuBar"
        static let screenFlash = "screenFlashEnabled"
        static let usbMoaner = "usbMoanerEnabled"
        static let screenShake = "screenShakeEnabled"
        static let brightness = "brightnessFlashEnabled"
        static let haptic = "hapticFeedbackEnabled"
        static let shakeIntensity = "shakeIntensity"
        static let brightnessIntensity = "brightnessFlashIntensity"
        static let flashIntensity = "screenFlashIntensity"
        static let hapticIntensity = "hapticIntensity"
        static let volume = "volume"

        static let customSoundsPath = "customSoundsPath"
        static let snoozeUntil = "snoozeUntil"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let loginItemConfigured = "loginItemConfigured"
        static let hardestSlap = "hardestSlap"
        static let todayCount = "todayCount"
        static let todayKey = "todayKey"
        static let migratedLegacyDomains = "migratedLegacyDomains"

        /// Every key 2.x wrote.
        static let migratable: Set<String> = [
            isEnabled, voicePack, sensitivity, cooldown, dynamicVolume, totalSlapCount, showCount,
            screenFlash, usbMoaner, screenShake, brightness, haptic, shakeIntensity,
            brightnessIntensity, flashIntensity, hapticIntensity, volume,
        ]
    }
}
