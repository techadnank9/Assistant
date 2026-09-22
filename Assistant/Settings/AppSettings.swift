import Foundation
import Observation

/// User-editable settings, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var ownerName: String { didSet { save("ownerName", ownerName) } }
    /// Base URL of the deployed Twilio Functions service, e.g. https://assistant-1234-dev.twil.io
    var twilioBaseURL: String { didSet { save("twilioBaseURL", twilioBaseURL) } }
    /// Shared secret the token function checks, so strangers can't mint tokens.
    var twilioSecret: String { didSet { save("twilioSecret", twilioSecret) } }
    /// Play the call through the phone so you can hear the agent and the caller.
    var listenIn: Bool { didSet { save("listenIn", listenIn) } }
    var modelID: String { didSet { save("modelID", modelID) } }

    var model: ModelOption {
        ModelOption.presets.first { $0.id == modelID } ?? ModelOption(id: modelID, label: modelID)
    }

    private init() {
        let d = UserDefaults.standard
        ownerName = d.string(forKey: "ownerName") ?? "Adnan"
        twilioBaseURL = d.string(forKey: "twilioBaseURL") ?? ""
        twilioSecret = d.string(forKey: "twilioSecret") ?? ""
        listenIn = d.object(forKey: "listenIn") as? Bool ?? true
        modelID = d.string(forKey: "modelID") ?? ModelOption.base.id
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
