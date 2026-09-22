import AVFoundation
import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var calls = CallManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $settings.ownerName)
                    TextField("What you do, for callers who ask", text: $settings.ownerProfile, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.footnote)
                } header: {
                    Text("Owner")
                } footer: {
                    Text("The assistant answers for this name and can tell recruiters and collaborators about your work. It never shares personal details.")
                }

                Section {
                    TextField("Twilio Functions URL", text: $settings.twilioBaseURL)
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

                ModelSection(settings: settings)
                VoiceSection(settings: settings)
            }
            .navigationTitle("Settings")
            .toolbar {
                NavigationLink { LogsView() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
            }
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


/// Settings → Model: which model, whether it's on this iPhone, and download / re-download / delete.
private struct ModelSection: View {
    @Bindable var settings: AppSettings
    @State private var status = ModelStatus.shared
    @State private var downloaded: [ModelFiles.Downloaded] = []
    @State private var customModel = ""
    @State private var busy = false
    @State private var confirmDelete: String?

    private var selected: ModelOption { settings.model }
    private var selectedOnPhone: ModelFiles.Downloaded? { downloaded.first { $0.id == selected.id } }

    var body: some View {
        Group { sections }
            .task { refresh() }
            .onChange(of: status.state) { refresh() }
            .confirmationDialog(
                "Delete this model from your iPhone?",
                isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                titleVisibility: .visible,
                presenting: confirmDelete
            ) { id in
                Button("Delete", role: .destructive) {
                    run {
                        if await LLMEngine.shared.currentModelID == id { await LLMEngine.shared.unload() }
                        try ModelFiles.delete(id)
                    }
                }
            } message: { _ in
                Text("It frees the space. The assistant downloads it again the next time it's needed.")
            }
    }

    @ViewBuilder private var sections: some View {
        Section {
            Picker("Model", selection: $settings.modelID) {
                ForEach(ModelOption.presets) { Text($0.label).tag($0.id) }
                if !ModelOption.presets.contains(where: { $0.id == settings.modelID }) {
                    Text(settings.modelID).tag(settings.modelID)
                }
            }

            LabeledContent("Status") { statusView }

            if case .downloading(let fraction) = status.state {
                ProgressView(value: fraction)
            }

            Button(selectedOnPhone == nil ? "Download" : "Load", systemImage: "arrow.down.circle") {
                run { try await LLMEngine.shared.load(selected) }
            }
            .disabled(busy || isReady)

            Button("Re-download", systemImage: "arrow.clockwise") {
                run {
                    await LLMEngine.shared.unload()
                    try ModelFiles.delete(selected.id)
                    try await LLMEngine.shared.load(selected)
                }
            }
            .disabled(busy || selectedOnPhone == nil)

            Button("Delete from iPhone", systemImage: "trash", role: .destructive) {
                confirmDelete = selected.id
            }
            .disabled(busy || selectedOnPhone == nil)
        } header: {
            Text("Model")
        } footer: {
            Text("The assistant runs on this model, entirely on your iPhone. It downloads once (about 1 GB) and stays until you delete it. iOS may remove it if storage runs very low; it then downloads again when needed.")
        }

        Section {
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
        } header: {
            Text("Custom model")
        } footer: {
            Text("Any MLX model on Hugging Face, such as a fine-tuned version of the assistant.")
        }

        if !downloaded.isEmpty {
            Section("On this iPhone") {
                ForEach(downloaded) { model in
                    LabeledContent {
                        Text(Self.size(model.bytes)).monospacedDigit()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ModelOption.presets.first { $0.id == model.id }?.label ?? model.id)
                            if model.id == selected.id {
                                Text("Selected").font(.caption).foregroundStyle(.tint)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { confirmDelete = model.id }
                    }
                }
                LabeledContent("Total", value: Self.size(downloaded.reduce(0) { $0 + $1.bytes }))
            }
        }
    }

    private var isReady: Bool { status.state == .ready }

    @ViewBuilder private var statusView: some View {
        switch status.state {
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Ready" + (selectedOnPhone.map { " · \(Self.size($0.bytes))" } ?? ""))
            }
            .foregroundStyle(.green)
        case .downloading(let f):
            Text(f > 0 ? "Downloading \(Int(f * 100))%" : "Starting download…").monospacedDigit()
        case .loading:
            Text("Loading…")
        case .failed(let message):
            Text(message).foregroundStyle(.red).font(.footnote)
        case .notStarted:
            Text(selectedOnPhone.map { "Downloaded · \(Self.size($0.bytes))" } ?? "Not downloaded")
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        downloaded = ModelFiles.downloaded()
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await work() } catch { Log.error(.model, "\(error)") }
            busy = false
            refresh()
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}


/// Settings → Voice: the natural (Kokoro) voice or an Apple voice, with a preview.
private struct VoiceSection: View {
    @Bindable var settings: AppSettings
    @State private var previewer = Speaker()
    @State private var downloaded = ModelFiles.bytes(for: NaturalVoice.repo) > 0
    @State private var downloading = false
    @State private var failure: String?
    private let appleVoices = Speaker.availableVoices()

    var body: some View {
        Section {
            if NaturalVoice.isSupported {
                Toggle("Natural voice", isOn: $settings.naturalVoice)
                if settings.naturalVoice {
                    Picker("Voice", selection: $settings.kokoroVoice) {
                        ForEach(NaturalVoice.voices) { Text($0.label).tag($0.id) }
                    }
                    if !downloaded {
                        Button(downloading ? "Downloading natural voice…" : "Download natural voice (about 330 MB)",
                               systemImage: "arrow.down.circle") {
                            downloading = true
                            failure = nil
                            Task {
                                do {
                                    try await NaturalVoice.shared.load()
                                } catch {
                                    failure = error.localizedDescription
                                }
                                downloading = false
                                downloaded = ModelFiles.bytes(for: NaturalVoice.repo) > 0
                            }
                        }
                        .disabled(downloading)
                    }
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            if !NaturalVoice.isSupported || !settings.naturalVoice {
                Picker("Voice", selection: $settings.voiceID) {
                    Text("Best available").tag("")
                    ForEach(appleVoices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(Self.quality(voice))").tag(voice.identifier)
                    }
                }
            }
            Button("Preview", systemImage: "play.circle") {
                // Playback mode, so the silent switch doesn't mute the preview.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
                previewer.stopSpeaking()
                previewer.speak("Hi, you've reached \(settings.ownerName)'s phone. Can I take a message?")
            }
        } header: {
            Text("Voice")
        } footer: {
            Text(NaturalVoice.isSupported && settings.naturalVoice
                 ? "A neural voice (Kokoro) that runs on this iPhone and sounds much more human. It downloads once."
                 : "For a more natural Apple voice, download an Enhanced or Premium English voice in the iPhone's Settings → Accessibility → Spoken Content → Voices, then pick it here.")
        }
    }

    private static func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }
}
