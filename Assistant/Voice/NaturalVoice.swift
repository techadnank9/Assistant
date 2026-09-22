import AVFoundation
import Foundation
import Observation
import MLX
import MLXAudioTTS

/// Which voices are on this iPhone, and what's downloading right now. Read by Settings.
@MainActor
@Observable
final class VoiceStatus {
    static let shared = VoiceStatus()

    /// Voice id → 0...1 while its download is running.
    var progress: [String: Double] = [:]
    /// Voice id → why its last download failed.
    var failure: [String: String] = [:]
    /// Voices that can be spoken without the network.
    var ready: Set<String> = []

    func refresh() {
        ready = Set(NaturalVoice.voices.map(\.id).filter(NaturalVoice.isReady))
    }
}

/// Kokoro-82M: a neural voice that runs on the iPhone (MLX) and sounds far more human than
/// Apple's built-in voices. The engine downloads once (327 MB); each voice is 0.5 MB.
actor NaturalVoice {
    static let shared = NaturalVoice()
    static let repo = "mlx-community/Kokoro-82M-bf16"

    struct Voice: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let voices: [Voice] = [
        Voice(id: "af_heart", label: "Heart · US female"),
        Voice(id: "af_bella", label: "Bella · US female"),
        Voice(id: "af_nicole", label: "Nicole · US female, soft"),
        Voice(id: "am_michael", label: "Michael · US male"),
        Voice(id: "am_fenrir", label: "Fenrir · US male, deep"),
        Voice(id: "bf_emma", label: "Emma · UK female"),
        Voice(id: "bm_george", label: "George · UK male"),
    ]

    /// MLX can't run in the simulator, so it falls back to Apple's voices there.
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
            false
        #else
            true
        #endif
    }

    private var model: KokoroModel?
    private var loading: Task<KokoroModel, Error>?

    var isLoaded: Bool { model != nil }

    /// The engine (shared by every voice) and one 0.5 MB voice file.
    static let engineFiles = ["config.json", "kokoro-v1_0.safetensors"]
    static func voiceFile(_ voice: String) -> String { "voices/\(voice).safetensors" }

    /// This voice can be spoken without the network: the shared engine plus its own file.
    static func isReady(_ voice: String) -> Bool {
        ModelFiles.localDirectory(for: repo, requiring: engineFiles + [voiceFile(voice)]) != nil
            || ModelFiles.localDirectory(for: repo, requiring: engineFiles) != nil && hasHubVoices
    }

    /// True when the engine is here, so any further voice is only a 0.5 MB download.
    static var engineIsDownloaded: Bool {
        ModelFiles.localDirectory(for: repo, requiring: engineFiles) != nil
    }

    /// Ready to speak with the chosen voice, without needing the network.
    @MainActor static var isDownloaded: Bool { isReady(AppSettings.shared.kokoroVoice) }

    /// Older Hugging Face cache downloads keep every voice together.
    private static var hasHubVoices: Bool {
        guard let dir = ModelFiles.localDirectory(for: repo, requiring: engineFiles) else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("voices").path)
    }

    /// Downloads (first time) and loads the voice model. Concurrent callers share one load.
    @discardableResult
    func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> KokoroModel {
        if let model { return model }
        if let loading { return try await loading.value }
        let task = Task { () throws -> KokoroModel in
            let start = Date.now
            Log.info(.audio, "Loading natural voice (Kokoro)")
            // The engine is 327 MB and every voice shares it; each voice file is only 0.5 MB.
            // So download the engine plus whichever voice is selected, and nothing else.
            let voice = await MainActor.run { AppSettings.shared.kokoroVoice }
            try await self.fetch(voice: voice) { fraction in
                progress(fraction)
                Task { @MainActor in
                    VoiceStatus.shared.progress[voice] = fraction < 1 ? fraction : nil
                }
            }
            let directory = ModelFiles.localDirectory(for: Self.repo, requiring: Self.engineFiles)
                ?? BackgroundDownloads.directory(for: Self.repo)
            let processor = MisakiTextProcessor()
            try await processor.prepare()   // pronunciation data, ~9 MB
            let model = try await KokoroModel.fromModelDirectory(directory, textProcessor: processor)
            Log.info(.audio, "Natural voice ready in \(Int(Date.now.timeIntervalSince(start)))s")
            await MainActor.run { VoiceStatus.shared.refresh() }
            return model
        }
        loading = task
        defer { loading = nil }
        do {
            let loaded = try await task.value
            model = loaded
            return loaded
        } catch {
            Log.error(.audio, "Natural voice failed to load: \(error)")
            throw error
        }
    }

    /// Starts a voice's download in the background: the shared engine the first time (327 MB),
    /// then this voice's own file (0.5 MB). Safe to call again while it's running.
    @MainActor
    static func download(_ voice: String) {
        let status = VoiceStatus.shared
        guard isSupported, status.progress[voice] == nil, !isReady(voice) else { return }
        status.progress[voice] = 0
        status.failure[voice] = nil
        Log.info(.audio, "Downloading voice \(voice)\(engineIsDownloaded ? "" : " and the voice engine")")
        Task {
            do {
                try await shared.fetch(voice: voice) { fraction in
                    Task { @MainActor in VoiceStatus.shared.progress[voice] = fraction }
                }
                status.progress[voice] = nil
                status.refresh()
                Log.info(.audio, "Voice \(voice) ready")
            } catch {
                status.progress[voice] = nil
                status.failure[voice] = error.localizedDescription
                Log.error(.audio, "Voice \(voice) failed to download: \(error)")
            }
        }
    }

    /// Starts the selected voice's download at launch, because the setup screen is skipped
    /// once the microphone, speech and model are already set up.
    @MainActor
    static func startDownloadIfNeeded() {
        VoiceStatus.shared.refresh()
        guard isSupported, AppSettings.shared.naturalVoice else { return }
        download(AppSettings.shared.kokoroVoice)
    }

    /// Makes sure the engine and one voice file are on disk.
    func fetch(voice: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let wanted = Set(Self.engineFiles + [Self.voiceFile(voice)])
        if ModelFiles.localDirectory(for: Self.repo, requiring: Array(wanted)) != nil { return progress(1) }
        _ = try await BackgroundDownloads.shared.ensure(
            repo: Self.repo, include: { wanted.contains($0) }, progress: progress)
    }

    /// Downloads a voice file (0.5 MB) if this is the first time it's used.
    private func ensureVoice(_ voice: String) async throws {
        guard !BackgroundDownloads.hasFiles(Self.repo, [Self.voiceFile(voice)]),
              ModelFiles.localDirectory(for: Self.repo, requiring: [Self.voiceFile(voice)]) == nil
        else { return }
        Log.info(.audio, "Fetching voice \(voice)")
        _ = try await BackgroundDownloads.shared.ensure(
            repo: Self.repo, include: { $0 == Self.voiceFile(voice) })
    }

    /// Renders one sentence to a WAV file in memory.
    func synthesize(_ text: String, voice: String) async throws -> Data {
        let model = try await load()
        try await ensureVoice(voice)
        let start = Date.now
        let audio = try await model.generate(
            text: text, voice: voice, refAudio: nil, refText: nil, language: nil,
            generationParameters: model.defaultGenerationParameters)
        let samples = audio.asArray(Float.self)
        // Synthesis allocates a lot of short-lived buffers. Give them back rather than letting the
        // cache sit on memory the model and the call audio need.
        GPUMemory.releaseCache("after speaking")
        let seconds = Double(samples.count) / Double(model.sampleRate)
        Log.info(.audio, "Natural voice: \(String(format: "%.1f", seconds))s of audio in \(String(format: "%.2f", Date.now.timeIntervalSince(start)))s")
        return Self.wav(samples, sampleRate: model.sampleRate)
    }

    /// 16-bit mono WAV, which AVAudioPlayer plays directly from memory.
    private static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32_767))
        }
        return data
    }
}
