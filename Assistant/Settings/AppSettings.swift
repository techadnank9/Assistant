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
    /// Play the call through the phone so you can hear the agent and the caller.
    var listenIn: Bool { didSet { save("listenIn", listenIn) } }
    var modelID: String { didSet { save("modelID", modelID) } }
    /// What tapping the orb does: talk to your assistant, or practise a call.
    var orbMode: String { didSet { save("orbMode", orbMode) } }
    /// The assistant's voice (an AVSpeechSynthesisVoice identifier); empty picks the best installed.
    var voiceID: String { didSet { save("voiceID", voiceID) } }

    var model: ModelOption {
        ModelOption.presets.first { $0.id == modelID } ?? ModelOption(id: modelID, label: modelID)
    }

    private init() {
        let d = UserDefaults.standard
        ownerName = d.string(forKey: "ownerName") ?? "Adnan"
        ownerProfile = d.string(forKey: "ownerProfile") ?? Self.bundledProfile
        twilioBaseURL = d.string(forKey: "twilioBaseURL") ?? ""
        twilioSecret = d.string(forKey: "twilioSecret") ?? ""
        listenIn = d.object(forKey: "listenIn") as? Bool ?? true
        modelID = d.string(forKey: "modelID") ?? ModelOption.default.id
        orbMode = d.string(forKey: "orbMode") ?? "owner"
        voiceID = d.string(forKey: "voiceID") ?? ""
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
