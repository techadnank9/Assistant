import AVFoundation
import Foundation
import MLX
import MLXAudioTTS

/// Kokoro-82M: a neural voice that runs on the iPhone (MLX) and sounds far more human than
/// Apple's built-in voices. Downloads once (~330 MB) from Hugging Face.
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

    /// Ready to speak with the chosen voice, without needing the network.
    @MainActor static var isDownloaded: Bool {
        let voice = AppSettings.shared.kokoroVoice
        return ModelFiles.localDirectory(for: repo, requiring: engineFiles + [voiceFile(voice)]) != nil
            || ModelFiles.localDirectory(for: repo, requiring: engineFiles) != nil && hasHubVoices
    }

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
            // All voices come in one download that continues in the background if the app closes.
            // The engine is 327 MB and each voice is only 0.5 MB, so download the engine plus the
            // chosen voice; other voices are fetched in a moment when they're picked.
            let voice = await MainActor.run { AppSettings.shared.kokoroVoice }
            let wanted = Set(Self.engineFiles + [Self.voiceFile(voice)])
            let directory: URL
            if let local = ModelFiles.localDirectory(for: Self.repo, requiring: Array(wanted)) {
                directory = local
            } else {
                directory = try await BackgroundDownloads.shared.ensure(
                    repo: Self.repo, include: { wanted.contains($0) }, progress: progress)
            }
            let processor = MisakiTextProcessor()
            try await processor.prepare()   // pronunciation data, ~9 MB
            let model = try await KokoroModel.fromModelDirectory(directory, textProcessor: processor)
            Log.info(.audio, "Natural voice ready in \(Int(Date.now.timeIntervalSince(start)))s")
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
