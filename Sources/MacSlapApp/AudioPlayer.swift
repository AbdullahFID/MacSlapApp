import Foundation
import AVFoundation

/// Audio player with voice pack support, escalation tracking, and logarithmic
/// volume scaling. For packs like "sexy" and "yamete", sustained slapping
/// escalates through increasingly intense sound files.
@MainActor
final class AudioPlayer {
    private let library: SoundLibrary
    private let robot = RobotVoice()

    private var players: [AVAudioPlayer] = []
    private var announcerTiers: [[AVAudioPlayer]] = []

    /// The pack the user picked.
    private(set) var selectedPack: VoicePack = .sexy
    /// The pack actually playing: the selection, or Robot Voice if the
    /// selected pack has no sound files installed.
    private(set) var activePack: VoicePack = .robot

    // Escalation tracking (inspired by spank's slapTracker)
    private var escalationScore: Double = 0
    private var lastSlapTime: Date = .distantPast
    private let escalationDecayHalfLife: TimeInterval = 30.0  // seconds

    // Decoding dozens of files takes over a second on first use (Core Audio
    // spin-up), so packs load off the main thread. The generation guards
    // against a slow load finishing after the user already picked another pack.
    private let loadQueue = DispatchQueue(label: "app.macslap.audio-load", qos: .userInitiated)
    private var loadGeneration = 0

    init(library: SoundLibrary) {
        self.library = library
    }

    var isUsingFallback: Bool { activePack != selectedPack }

    func load(pack: VoicePack) {
        selectedPack = pack
        players.removeAll()
        announcerTiers.removeAll()
        escalationScore = 0
        loadGeneration += 1
        let generation = loadGeneration

        let files = library.files(for: pack)
        activePack = (pack == .robot || !files.isEmpty) ? pack : .robot
        guard activePack != .robot else {
            if pack != .robot {
                log("No sound files for '\(pack.displayName)' — falling back to Robot Voice")
            }
            return
        }

        let tierFiles = pack == .comboHit ? library.comboAnnouncerTiers() : []
        loadQueue.async { [weak self] in
            let loaded = files.compactMap(AudioPlayer.makePlayer)
            let tiers = tierFiles.map { $0.compactMap(AudioPlayer.makePlayer) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.players = loaded
                self.announcerTiers = tiers
                let comboClips = tiers.reduce(0) { $0 + $1.count }
                log("Loaded \(loaded.count) sounds for '\(pack.displayName)'" +
                    (comboClips == 0 ? "" : " + \(comboClips) combo clips"))
            }
        }
    }

    /// Play a sound from the current pack
    func play(intensity: Double, dynamicVolume: Bool, baseVolume: Float) {
        // Update escalation score with time decay
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSlapTime)
        let decayFactor = pow(0.5, elapsed / escalationDecayHalfLife)
        escalationScore = escalationScore * decayFactor + 1.0
        lastSlapTime = now

        // Logarithmic volume scaling (like spank): intensity [0, 1] maps to
        // [1/8, 1] of the master volume.
        let volume: Float
        if dynamicVolume {
            let minVol: Float = 0.125
            volume = baseVolume * (minVol + Float(intensity) * (1.0 - minVol))
        } else {
            volume = baseVolume
        }

        if activePack == .robot {
            robot.speak(intensity: intensity, streak: escalationScore, volume: volume)
            return
        }
        guard !players.isEmpty else { return }

        let player: AVAudioPlayer
        if activePack.usesEscalation && players.count > 1 {
            // Map escalation score to file index using an exponential curve:
            // higher score = later (more intense) files.
            let normalized = 1.0 - exp(-(escalationScore - 1) / 5.0)
            let index = min(Int(normalized * Double(players.count)), players.count - 1)
            player = players[index]
        } else {
            player = players.randomElement()!
        }
        start(player, volume: volume)

        // Combo announcer calls out the current streak tier (1...9).
        if activePack == .comboHit {
            let tier = min(max(Int(escalationScore), 1), announcerTiers.count)
            if tier >= 1, let announcer = announcerTiers[tier - 1].randomElement() {
                start(announcer, volume: baseVolume * 0.7)
            }
        }
    }

    /// Play a random sound for USB events (no escalation)
    func playRandom(baseVolume: Float) {
        if activePack == .robot {
            robot.speak(intensity: 0.5, streak: 1, volume: baseVolume)
            return
        }
        guard let player = players.randomElement() else { return }
        start(player, volume: baseVolume)
    }

    private func start(_ player: AVAudioPlayer, volume: Float) {
        player.volume = volume
        player.currentTime = 0
        if !player.play() {
            log("Playback failed for \(player.url?.lastPathComponent ?? "sound")")
        }
    }

    nonisolated private static func makePlayer(_ url: URL) -> AVAudioPlayer? {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            log("Failed to load \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
