import Foundation

enum VoicePack: String, CaseIterable {
    case sexy, comboHit, male, fart, gentleman, yamete, goat
    case systemSounds = "system"
    case robot

    var displayName: String {
        switch self {
        case .sexy: return "Sexy"
        case .comboHit: return "Combo Hit"
        case .male: return "Male"
        case .fart: return "Fart"
        case .gentleman: return "Gentleman"
        case .yamete: return "Yamete"
        case .goat: return "Goat"
        case .systemSounds: return "macOS Sounds"
        case .robot: return "Robot Voice"
        }
    }

    /// Filename prefix (before the first "_") for packs backed by sound files.
    var filePrefix: String? {
        switch self {
        case .comboHit: return "punch"
        case .systemSounds, .robot: return nil
        default: return rawValue
        }
    }

    /// Built-in packs work with no sound files installed.
    var isBuiltIn: Bool { filePrefix == nil }

    /// Packs that escalate through files with sustained slapping
    var usesEscalation: Bool {
        switch self {
        case .sexy, .yamete: return true
        default: return false
        }
    }

    static var filePacks: [VoicePack] { allCases.filter { !$0.isBuiltIn } }
    static var builtInPacks: [VoicePack] { allCases.filter(\.isBuiltIn) }
}

/// Finds sound files across every place they might live and groups them by
/// voice-pack prefix. Earlier folders win when two share a filename.
@MainActor
final class SoundLibrary {
    static let supportedExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf"]
    static let comboTiers = 1...9

    /// Primary location: ~/Library/Application Support/MacSlapApp/Sounds
    static let appSupportFolder: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }()

    /// Where versions before 3.0 told everyone to put their sounds.
    static let legacyFolder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/slapmac/audio", isDirectory: true)

    static let systemSoundsFolder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    var customFolder: URL?

    private(set) var filesByPrefix: [String: [URL]] = [:]
    private(set) var foldersWithSounds: [URL] = []

    init(customFolder: URL?) {
        self.customFolder = customFolder
        try? FileManager.default.createDirectory(at: Self.appSupportFolder, withIntermediateDirectories: true)
    }

    /// Search order: user-chosen folder, Application Support, legacy Desktop
    /// folder, then sounds bundled inside the app.
    var searchFolders: [URL] {
        var folders: [URL] = []
        if let customFolder { folders.append(customFolder) }
        folders.append(Self.appSupportFolder)
        folders.append(Self.legacyFolder)
        if let resources = Bundle.main.resourceURL {
            folders.append(resources.appendingPathComponent("Sounds", isDirectory: true))
        }
        return folders
    }

    func rescan() {
        let fm = FileManager.default
        var seen = Set<String>()
        var grouped: [String: [URL]] = [:]
        var contributing: [URL] = []

        for folder in searchFolders {
            guard let entries = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            var contributed = false
            for url in entries where Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                let name = url.lastPathComponent.lowercased()
                guard !seen.contains(name), let underscore = name.firstIndex(of: "_") else { continue }
                seen.insert(name)
                grouped[String(name[..<underscore]), default: []].append(url)
                contributed = true
            }
            if contributed { contributing.append(folder) }
        }

        for key in grouped.keys {
            grouped[key]?.sort {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }
        filesByPrefix = grouped
        foldersWithSounds = contributing

        let summary = VoicePack.filePacks.map { "\($0.displayName)=\(count(for: $0))" }.joined(separator: " ")
        let sources = contributing.isEmpty ? "no folders" : contributing.map(\.path).joined(separator: ", ")
        log("Sounds scanned from \(sources): \(summary) combo=\(comboAnnouncerCount)")
    }

    func files(for pack: VoicePack) -> [URL] {
        if pack == .systemSounds { return Self.systemSounds() }
        guard let prefix = pack.filePrefix else { return [] }
        return filesByPrefix[prefix] ?? []
    }

    func count(for pack: VoicePack) -> Int {
        switch pack {
        case .robot: return RobotVoice.phraseCount
        default: return files(for: pack).count
        }
    }

    /// Announcer clips grouped by combo tier: index 0 holds every "1_*" file,
    /// index 8 every "9_*" file. Tiers with no files are empty arrays.
    func comboAnnouncerTiers() -> [[URL]] {
        Self.comboTiers.map { filesByPrefix[String($0)] ?? [] }
    }

    var comboAnnouncerCount: Int { comboAnnouncerTiers().reduce(0) { $0 + $1.count } }

    private static func systemSounds() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: systemSoundsFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
