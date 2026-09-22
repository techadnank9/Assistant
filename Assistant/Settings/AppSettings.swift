import Foundation
import Observation

/// User-editable settings, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var ownerName: String { didSet { save("ownerName", ownerName) } }
    /// What the assistant may tell callers about your work. Starts from OwnerProfile.txt if bundled.
    var ownerProfile: String { didSet { save("ownerProfile", ownerProfile) } }
    /// Base URL of the deployed Twilio Functions service, e.g. https://assistant-1234-dev.twil.io
    var twilioBaseURL: String { didSet { save("twilioBaseURL", twilioBaseURL) } }
    /// Shared secret the token function checks, so strangers can't mint tokens.
    var twilioSecret: String { didSet { save("twilioSecret", twilioSecret) } }
    /// Let the assistant pick up by itself, so calls are taken when the phone is in a pocket.
    var autoAnswer: Bool { didSet { save("autoAnswer", autoAnswer) } }
    /// Seconds the phone rings first, so the owner can take the call instead.
    var autoAnswerDelay: Double { didSet { save("autoAnswerDelay", autoAnswerDelay) } }
    /// Play the call through the phone so you can hear the agent and the caller.
    var listenIn: Bool { didSet { save("listenIn", listenIn) } }
    var modelID: String { didSet { save("modelID", modelID) } }
    /// What tapping the orb does: talk to your assistant, or practise a call.
    var orbMode: String { didSet { save("orbMode", orbMode) } }
    /// The assistant's voice (an AVSpeechSynthesisVoice identifier); empty picks the best installed.
    var voiceID: String { didSet { save("voiceID", voiceID) } }
    /// Use the downloaded neural voice (Kokoro) instead of Apple's voices.
    var naturalVoice: Bool { didSet { save("naturalVoice", naturalVoice) } }
    var kokoroVoice: String { didSet { save("kokoroVoice", kokoroVoice) } }
    /// Set once the setup screen has offered the "About you" step, so it isn't forced again.
    var profilePromptSeen: Bool { didSet { save("profilePromptSeen", profilePromptSeen) } }

    var model: ModelOption {
        ModelOption.presets.first { $0.id == modelID } ?? ModelOption(id: modelID, label: modelID)
    }

    private init() {
        let d = UserDefaults.standard
        ownerName = d.string(forKey: "ownerName") ?? "Adnan"
        // The built-in profile, unless the owner has written their own.
        let stored = d.string(forKey: "ownerProfile") ?? ""
        ownerProfile = stored.isEmpty ? Self.bundledProfile : stored
        // Falls back to TwilioConfig.plist, so a build comes ready to take calls with nothing to type.
        twilioBaseURL = Self.nonEmpty(d.string(forKey: "twilioBaseURL")) ?? Self.bundledTwilio("BaseURL")
        twilioSecret = Self.nonEmpty(d.string(forKey: "twilioSecret")) ?? Self.bundledTwilio("Secret")
        listenIn = d.object(forKey: "listenIn") as? Bool ?? true
        modelID = d.string(forKey: "modelID") ?? ModelOption.default.id
        orbMode = d.string(forKey: "orbMode") ?? "owner"
        voiceID = d.string(forKey: "voiceID") ?? ""
        naturalVoice = d.object(forKey: "naturalVoice") as? Bool ?? true
        autoAnswer = d.object(forKey: "autoAnswer") as? Bool ?? true
        autoAnswerDelay = d.object(forKey: "autoAnswerDelay") as? Double ?? 4
        kokoroVoice = d.string(forKey: "kokoroVoice") ?? "af_heart"
        profilePromptSeen = d.bool(forKey: "profilePromptSeen")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    /// The Twilio account this build was made for (TwilioConfig.plist, kept out of the public repo).
    private static func bundledTwilio(_ key: String) -> String {
        guard let url = Bundle.main.url(forResource: "TwilioConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return "" }
        return plist[key] ?? ""
    }

    private static var bundledProfile: String {
        guard let url = Bundle.main.url(forResource: "OwnerProfile", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
