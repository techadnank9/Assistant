@preconcurrency import AVFoundation

/// Text to speech that renders to PCM buffers instead of the speaker,
/// so the same audio can go to a phone call.
@MainActor
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    init(language: String = "en-US") {
        voice = Self.chosenVoice(language: language)
        synthesizer.usesApplicationAudioSession = true
    }

    /// The voice picked in Settings, else the best installed one: premium and enhanced voices
    /// sound far more human than the default compact ones.
    static func chosenVoice(language: String = "en-US") -> AVSpeechSynthesisVoice? {
        let picked = AppSettings.shared.voiceID
        if !picked.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: picked) { return voice }
        return availableVoices(language: language).first ?? AVSpeechSynthesisVoice(language: language)
    }

    /// English voices on this iPhone, best quality first.
    static func availableVoices(language: String = "en-US") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    /// Renders `text` and returns the audio, converted to `format`.
    func render(_ text: String, to format: AVAudioFormat) async -> [AVAudioPCMBuffer] {
        var chunks = await synthesize(text, voice: voice)
        if chunks.isEmpty, let fallback = AVSpeechSynthesisVoice(language: "en-US"),
           fallback.identifier != voice?.identifier {
            // The chosen voice produced nothing (e.g. not fully installed): use the built-in one.
            Log.error(.audio, "Voice \(voice?.name ?? "default") produced no audio; retrying with \(fallback.name)")
            chunks = await synthesize(text, voice: fallback)
        }
        // Resample once for the whole sentence so chunk edges don't click.
        guard let joined = PCM.join(chunks), let converted = PCM.convert(joined, to: format) else {
            Log.error(.audio, "Text-to-speech produced no audio for: \(text)")
            return []
        }
        return [converted]
    }

    /// Collects the synthesizer's buffers. Never waits forever: if the synthesizer goes quiet
    /// for 4 seconds without its end-of-speech signal, it returns what it has.
    private func synthesize(_ text: String, voice: AVSpeechSynthesisVoice?) async -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05

        let collector = BufferCollector()
        let result: Chunks = await withCheckedContinuation { continuation in
            collector.onFinish = { continuation.resume(returning: Chunks(buffers: $0)) }
            synthesizer.write(utterance) { audio in
                guard let pcm = audio as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    collector.finish()
                    return
                }
                collector.add(pcm)
            }
            Task {
                while !collector.isFinished {
                    try? await Task.sleep(for: .milliseconds(500))
                    if collector.idleSeconds > 4 {
                        Log.error(.audio, "Text-to-speech stalled; continuing with \(collector.count) chunks")
                        collector.finish()
                    }
                }
            }
        }
        return result.buffers
    }
}

/// Buffers handed across the continuation; each is written once and then only read.
private struct Chunks: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
}

/// Thread-safe sink for synthesizer callbacks, which arrive on an arbitrary queue.
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [AVAudioPCMBuffer] = []
    private var finished = false
    private var lastActivity = Date.now
    var onFinish: (([AVAudioPCMBuffer]) -> Void)?

    var isFinished: Bool { lock.withLock { finished } }
    var count: Int { lock.withLock { chunks.count } }
    var idleSeconds: TimeInterval { lock.withLock { Date.now.timeIntervalSince(lastActivity) } }

    func add(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !finished else { return }
            chunks.append(buffer)
            lastActivity = .now
        }
    }

    /// Resumes the waiting caller exactly once.
    func finish() {
        let result: [AVAudioPCMBuffer]? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return chunks
        }
        if let result { onFinish?(result) }
    }
}
