import AppKit
import SlapCore

/// Owns the menu bar item. The menu is rebuilt each time it opens
/// (NSMenuDelegate.menuNeedsUpdate) so it always reflects current state.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let settings: SettingsStore
    private let controller: SlapController
    private let updates: UpdateChecker
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private var flashRevert: DispatchWorkItem?
    private var volumeLabel: NSTextField?

    private static let idleEmoji = "👋"
    private static let slapEmoji = "💥"
    private static let pausedEmoji = "💤"

    init(settings: SettingsStore, controller: SlapController, updates: UpdateChecker) {
        self.settings = settings
        self.controller = controller
        self.updates = updates
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel(AppInfo.name)
        refreshButton()

        controller.onSlap = { [weak self] _ in self?.flashButton() }
        controller.onStateChange = { [weak self] in self?.refreshButton() }
        updates.onChange = { [weak self] in self?.refreshButton() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    // MARK: - Status bar button

    private func refreshButton(emoji: String? = nil) {
        if settings.snoozeUntil != nil && !settings.isSnoozed { settings.snoozeUntil = nil }
        let icon = emoji ?? (controller.isActive ? Self.idleEmoji : Self.pausedEmoji)
        let count = settings.showCountInMenuBar ? " \(settings.totalSlapCount.formatted())" : ""
        statusItem.button?.title = icon + count
    }

    private func flashButton() {
        flashRevert?.cancel()
        refreshButton(emoji: Self.slapEmoji)
        let revert = DispatchWorkItem { [weak self] in self?.refreshButton() }
        flashRevert = revert
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: revert)
    }

    // MARK: - Menu construction

    private func rebuild() {
        menu.removeAllItems()
        volumeLabel = nil
        if settings.snoozeUntil != nil && !settings.isSnoozed { settings.snoozeUntil = nil }

        if let release = updates.available {
            menu.addItem(action("Update Available: \(release.version)…", #selector(openAvailableUpdate)))
            menu.addItem(.separator())
        }

        menu.addItem(info(controller.accelerometer.status.menuDescription))
        menu.addItem(info(statsLine()))
        menu.addItem(.separator())

        menu.addItem(toggle("Enabled", settings.isEnabled, #selector(toggleEnabled)))
        menu.addItem(snoozeItem())
        menu.addItem(.separator())

        addSoundSection()
        menu.addItem(.separator())
        addEffectsSection()
        menu.addItem(.separator())

        let test = action("Test Slap", #selector(testSlap))
        test.keyEquivalent = "t"
        menu.addItem(test)
        menu.addItem(.separator())

        menu.addItem(toggle("Show Count in Menu Bar", settings.showCountInMenuBar, #selector(toggleShowCount)))
        if LoginItem.isSupported {
            if LoginItem.needsApproval {
                menu.addItem(action("Launch at Login (Needs Approval)…", #selector(openLoginItemSettings)))
            } else {
                menu.addItem(toggle("Launch at Login", LoginItem.isEnabled, #selector(toggleLaunchAtLogin)))
            }
        }
        menu.addItem(action("Reset Stats…", #selector(resetStats)))
        menu.addItem(.separator())

        menu.addItem(action("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(helpItem())
        menu.addItem(action("About \(AppInfo.name)", #selector(showAbout)))
        let quit = action("Quit \(AppInfo.name)", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func statsLine() -> String {
        let hardest = settings.hardestSlap > 0 ? String(format: "%.1f g", settings.hardestSlap) : "—"
        return "Slaps: \(settings.totalSlapCount.formatted())  ·  Today: \(settings.todayCount.formatted())"
            + "  ·  Hardest: \(hardest)"
    }

    private func snoozeItem() -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let title: String
        if let until = settings.snoozeUntil, settings.isSnoozed {
            title = "Snoozed Until \(Self.describe(until))"
            sub.addItem(action("Resume Now", #selector(resumeFromSnooze)))
            sub.addItem(.separator())
        } else {
            title = "Snooze"
        }
        for (index, option) in SnoozeOption.allCases.enumerated() {
            let item = action(option.displayName, #selector(snooze(_:)))
            item.tag = index
            sub.addItem(item)
        }
        return submenu(title, sub)
    }

    private func addSoundSection() {
        menu.addItem(.sectionHeader(title: "Sound"))

        let packs = NSMenu()
        packs.autoenablesItems = false
        for pack in VoicePack.filePacks {
            packs.addItem(packItem(pack))
        }
        packs.addItem(.separator())
        packs.addItem(.sectionHeader(title: "Built In"))
        for pack in VoicePack.builtInPacks {
            packs.addItem(packItem(pack))
        }
        packs.addItem(.separator())
        packs.addItem(action("Open Sounds Folder", #selector(openSoundsFolder)))
        packs.addItem(action("Choose Sounds Folder…", #selector(chooseSoundsFolder)))
        if settings.customSoundsFolder != nil {
            packs.addItem(action("Stop Using Custom Folder", #selector(clearSoundsFolder)))
        }
        packs.addItem(action("Reload Sounds", #selector(reloadSounds)))
        menu.addItem(submenu("Voice Pack: \(settings.voicePack.displayName)", packs))

        if controller.audioPlayer.isUsingFallback {
            menu.addItem(info("No \(settings.voicePack.displayName) sounds found — using Robot Voice", indent: 1))
        }

        let volume = sliderItem(label: volumeText(settings.volume), value: Double(settings.volume),
                                action: #selector(volumeChanged(_:)), indented: false)
        volumeLabel = volume.label
        menu.addItem(volume.item)
        menu.addItem(toggle("Dynamic Volume", settings.dynamicVolume, #selector(toggleDynamicVolume)))

        let sensitivity = NSMenu()
        for level in SensitivityLevel.allCases.reversed() {
            let item = toggle(level.displayName, settings.sensitivity == level, #selector(selectSensitivity(_:)))
            item.tag = level.rawValue
            sensitivity.addItem(item)
        }
        menu.addItem(submenu("Sensitivity: \(settings.sensitivity.displayName)", sensitivity))

        let cooldown = NSMenu()
        let currentCooldown = CooldownOption(rawValue: settings.cooldownInterval)
        for (index, option) in CooldownOption.allCases.enumerated() {
            let item = toggle(option.displayName, currentCooldown == option, #selector(selectCooldown(_:)))
            item.tag = index
            cooldown.addItem(item)
        }
        menu.addItem(submenu("Cooldown: \(currentCooldown?.displayName ?? "Custom")", cooldown))
    }

    private func packItem(_ pack: VoicePack) -> NSMenuItem {
        let item = toggle(pack.displayName, settings.voicePack == pack, #selector(selectVoicePack(_:)))
        item.representedObject = pack.rawValue
        if pack == .robot {
            item.badge = NSMenuItemBadge(string: "No files needed")
        } else {
            let count = controller.library.count(for: pack)
            item.badge = count > 0 ? NSMenuItemBadge(count: count) : NSMenuItemBadge(string: "No files")
        }
        return item
    }

    private func addEffectsSection() {
        menu.addItem(.sectionHeader(title: "Effects"))

        menu.addItem(toggle("Trackpad Haptics", settings.hapticFeedbackEnabled, #selector(toggleHaptics)))
        if settings.hapticFeedbackEnabled {
            menu.addItem(sliderItem(label: "Intensity", value: settings.hapticIntensity,
                                    action: #selector(hapticIntensityChanged(_:))).item)
        }

        menu.addItem(toggle("Screen Flash", settings.screenFlashEnabled, #selector(toggleScreenFlash)))
        if settings.screenFlashEnabled {
            menu.addItem(sliderItem(label: "Intensity", value: settings.screenFlashIntensity,
                                    action: #selector(screenFlashIntensityChanged(_:))).item)
        }

        menu.addItem(toggle("Screen Shake", settings.screenShakeEnabled, #selector(toggleScreenShake)))
        if settings.screenShakeEnabled {
            if ScreenCapturePermission.isGranted {
                menu.addItem(sliderItem(label: "Intensity", value: settings.shakeIntensity,
                                        action: #selector(shakeIntensityChanged(_:))).item)
            } else {
                let grant = action("Allow Screen Recording…", #selector(requestScreenRecording))
                grant.indentationLevel = 1
                menu.addItem(grant)
            }
        }

        let brightness = toggle("Brightness Flash", settings.brightnessFlashEnabled, #selector(toggleBrightness))
        if !controller.brightnessFlash.isAvailable {
            brightness.isEnabled = false
            brightness.badge = NSMenuItemBadge(string: "No built-in display")
        }
        menu.addItem(brightness)
        if settings.brightnessFlashEnabled && brightness.isEnabled {
            menu.addItem(sliderItem(label: "Intensity", value: settings.brightnessFlashIntensity,
                                    action: #selector(brightnessIntensityChanged(_:))).item)
        }

        menu.addItem(toggle("USB Moaner", settings.usbMoanerEnabled, #selector(toggleUSBMoaner)))
    }

    private func helpItem() -> NSMenuItem {
        let help = NSMenu()
        help.autoenablesItems = false
        help.addItem(action("Website", #selector(openWebsite)))
        help.addItem(action("GitHub", #selector(openGitHub)))
        help.addItem(action("Open Log File", #selector(openLog)))
        return submenu("Help", help)
    }

    // MARK: - Item factories

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ selector: Selector) -> NSMenuItem {
        let item = action(title, selector)
        item.state = on ? .on : .off
        return item
    }

    private func info(_ title: String, indent: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indent
        return item
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// `indented` sliders belong to the effect toggle above them.
    private func sliderItem(label: String, value: Double, action: Selector,
                            indented: Bool = true) -> (item: NSMenuItem, label: NSTextField) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        let text = NSTextField(labelWithString: label)
        text.font = .menuFont(ofSize: 0)
        text.textColor = .secondaryLabelColor
        text.frame = NSRect(x: indented ? 42 : 30, y: 5, width: 84, height: 16)
        let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: self, action: action)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.frame = NSRect(x: 118, y: 4, width: 128, height: 18)
        view.addSubview(text)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return (item, text)
    }

    private func volumeText(_ volume: Float) -> String {
        "Volume \(Int((volume * 100).rounded()))%"
    }

    private static func describe(_ date: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
        return date.formatted(style)
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        controller.setEnabled(!settings.isEnabled)
        refreshButton()
    }

    @objc private func snooze(_ sender: NSMenuItem) {
        guard SnoozeOption.allCases.indices.contains(sender.tag) else { return }
        controller.snooze(SnoozeOption.allCases[sender.tag])
        refreshButton()
    }

    @objc private func resumeFromSnooze() {
        controller.resumeFromSnooze()
        refreshButton()
    }

    @objc private func selectVoicePack(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let pack = VoicePack(rawValue: raw) else { return }
        controller.selectVoicePack(pack)
    }

    @objc private func openSoundsFolder() {
        let folder = settings.customSoundsFolder
            ?? controller.library.foldersWithSounds.first
            ?? SoundLibrary.appSupportFolder
        NSWorkspace.shared.open(folder)
    }

    @objc private func chooseSoundsFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Choose a folder of sounds"
        panel.message = "Files are matched by prefix: sexy_01.mp3, punch_3.wav, goat_a.m4a, 1_1.mp3 (combo announcer)…"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.customSoundsFolder ?? SoundLibrary.appSupportFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.setCustomSoundsFolder(url)
    }

    @objc private func clearSoundsFolder() {
        controller.setCustomSoundsFolder(nil)
    }

    @objc private func reloadSounds() {
        controller.reloadSounds()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        settings.volume = Float(sender.doubleValue)
        volumeLabel?.stringValue = volumeText(settings.volume)
    }

    @objc private func toggleDynamicVolume() {
        settings.dynamicVolume.toggle()
    }

    @objc private func selectSensitivity(_ sender: NSMenuItem) {
        guard let level = SensitivityLevel(rawValue: sender.tag) else { return }
        settings.sensitivity = level
        controller.updateDetectorConfig()
    }

    @objc private func selectCooldown(_ sender: NSMenuItem) {
        guard CooldownOption.allCases.indices.contains(sender.tag) else { return }
        settings.cooldownInterval = CooldownOption.allCases[sender.tag].interval
    }

    @objc private func toggleHaptics() { settings.hapticFeedbackEnabled.toggle() }
    @objc private func toggleScreenFlash() { settings.screenFlashEnabled.toggle() }
    @objc private func toggleBrightness() { settings.brightnessFlashEnabled.toggle() }

    @objc private func toggleScreenShake() {
        settings.screenShakeEnabled.toggle()
        if settings.screenShakeEnabled && !ScreenCapturePermission.isGranted {
            ScreenCapturePermission.request()
        }
    }

    @objc private func requestScreenRecording() {
        ScreenCapturePermission.request()
    }

    @objc private func toggleUSBMoaner() {
        controller.setUSBMoaner(!settings.usbMoanerEnabled)
    }

    @objc private func hapticIntensityChanged(_ sender: NSSlider) {
        settings.hapticIntensity = sender.doubleValue
        controller.applyIntensities()
    }

    @objc private func screenFlashIntensityChanged(_ sender: NSSlider) {
        settings.screenFlashIntensity = sender.doubleValue
        controller.applyIntensities()
    }

    @objc private func shakeIntensityChanged(_ sender: NSSlider) {
        settings.shakeIntensity = sender.doubleValue
        controller.applyIntensities()
    }

    @objc private func brightnessIntensityChanged(_ sender: NSSlider) {
        settings.brightnessFlashIntensity = sender.doubleValue
        controller.applyIntensities()
    }

    @objc private func testSlap() {
        controller.testSlap()
    }

    @objc private func toggleShowCount() {
        settings.showCountInMenuBar.toggle()
        refreshButton()
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        if LoginItem.needsApproval { LoginItem.openSettings() }
    }

    @objc private func openLoginItemSettings() {
        LoginItem.openSettings()
    }

    @objc private func resetStats() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Reset slap stats?"
        alert.informativeText = "Your total (\(settings.totalSlapCount.formatted())), today's count and hardest slap will be cleared."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.resetStats()
        refreshButton()
    }

    @objc private func checkForUpdates() {
        Task { await updates.check(userInitiated: true) }
    }

    @objc private func openAvailableUpdate() {
        guard let release = updates.available else { return }
        updates.promptToDownload(release)
    }

    @objc private func openWebsite() { NSWorkspace.shared.open(AppInfo.websiteURL) }
    @objc private func openGitHub() { NSWorkspace.shared.open(AppInfo.repoURL) }

    @objc private func openLog() {
        NSWorkspace.shared.open(AppLog.fileURL)
    }

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "Slap your MacBook and it screams back.\nFree and open source.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .credits: credits,
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
