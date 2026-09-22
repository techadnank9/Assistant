import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var calls = CallManager.shared
    @State private var customModel = ""
    @State private var reloading = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $settings.ownerName)
                } header: {
                    Text("Owner")
                } footer: {
                    Text("The assistant tells callers it's answering for this name.")
                }

                Section {
                    TextField("https://assistant-1234.twil.io", text: $settings.twilioBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Secret", text: $settings.twilioSecret)
                    LabeledContent("Status") { registrationStatus }
                    Button("Register for calls") { Task { await calls.register() } }
                        .disabled(!TokenService.isConfigured || calls.registration == .registering)
                    Toggle("Listen in on calls", isOn: $settings.listenIn)
                } header: {
                    Text("Phone number")
                } footer: {
                    Text("Your Twilio Functions URL and the APP_SECRET you deployed with. Once registered, calls to your Twilio number ring this iPhone. Tap Answer and the assistant takes it.")
                }

                Section {
                    Picker("Model", selection: $settings.modelID) {
                        ForEach(ModelOption.presets) { Text($0.label).tag($0.id) }
                        if !ModelOption.presets.contains(where: { $0.id == settings.modelID }) {
                            Text(settings.modelID).tag(settings.modelID)
                        }
                    }
                    HStack {
                        TextField("Hugging Face repo, e.g. you/qwen3-assistant", text: $customModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Use") {
                            settings.modelID = customModel.trimmingCharacters(in: .whitespaces)
                            customModel = ""
                        }
                        .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button(reloading ? "Loading…" : "Load selected model") {
                        reloading = true
                        Task {
                            try? await LLMEngine.shared.load(settings.model)
                            reloading = false
                        }
                    }
                    .disabled(reloading)
                } header: {
                    Text("Model")
                } footer: {
                    Text("Your fine-tuned model from Phase 5 goes here. Restart the app after switching so Chat picks it up.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder private var registrationStatus: some View {
        switch calls.registration {
        case .notConfigured: Text("Not set up").foregroundStyle(.secondary)
        case .waitingForPushToken: Text("Waiting for push token").foregroundStyle(.secondary)
        case .registering: ProgressView()
        case .registered: Label("Ready for calls", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Text(message).foregroundStyle(.red).font(.footnote)
        }
    }
}
