import AVFoundation

/// A voice pack that needs no sound files: the Mac complains out loud using
/// the system speech synthesizer. Harder and faster slaps get angrier lines
/// and a higher pitch.
@MainActor
final class RobotVoice {
    private static let light = [
        "Hey.", "Ow.", "Excuse me?", "Rude.", "I felt that.", "Hmm?", "Careful.",
    ]
    private static let medium = [
        "Ouch!", "Hey! Stop that!", "Ow! Why?", "Not cool!", "That hurt!",
        "Watch it!", "Hands off!", "What did I do?",
    ]
    private static let hard = [
        "Ow! What is wrong with you?", "Seriously?", "I have feelings!",
        "My screen! My beautiful screen!", "That's going on your permanent record!",
        "I'm telling the Genius Bar!",
    ]
    private static let spamming = [
        "Okay, okay, I get it!", "Please stop!", "I'm calling AppleCare.",
        "Is this how you treat all your computers?", "Combo breaker!",
    ]

    static var phraseCount: Int { light.count + medium.count + hard.count + spamming.count }

    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
        ?? AVSpeechSynthesisVoice(language: "en-US")
    private var lastPhrase = ""

    /// - Parameters:
    ///   - intensity: 0...1 slap force.
    ///   - streak: recent-slap escalation score (1 = first slap in a while).
    ///   - volume: 0...1 output volume.
    func speak(intensity: Double, streak: Double, volume: Float) {
        let pool: [String]
        if streak >= 5 {
            pool = Self.spamming
        } else if intensity > 0.75 {
            pool = Self.hard
        } else if intensity > 0.35 {
            pool = Self.medium
        } else {
            pool = Self.light
        }
        var phrase = pool.randomElement() ?? "Ouch!"
        if phrase == lastPhrase, pool.count > 1 {
            phrase = pool.filter { $0 != lastPhrase }.randomElement() ?? phrase
        }
        lastPhrase = phrase

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = voice
        utterance.volume = volume
        utterance.pitchMultiplier = Float(0.9 + intensity * 0.7)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(1.0 + min(streak, 6) * 0.04)

        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
}
