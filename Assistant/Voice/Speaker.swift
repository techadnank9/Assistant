@preconcurrency import AVFoundation

/// Text to speech that renders to PCM buffers instead of the speaker,
/// so the same audio can go to a phone call.
@MainActor
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    init(language: String = "en-US") {
        // Premium and enhanced voices sound far more human; use the best one installed.
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        voice = voices.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
        synthesizer.usesApplicationAudioSession = true
    }

    /// Renders `text` and returns the audio, converted to `format`.
    func render(_ text: String, to format: AVAudioFormat) async -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05

        let chunks: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            nonisolated(unsafe) var chunks: [AVAudioPCMBuffer] = []
            nonisolated(unsafe) var resumed = false
            synthesizer.write(utterance) { audio in
                guard !resumed else { return }
                guard let pcm = audio as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    resumed = true
                    continuation.resume(returning: chunks)
                    return
                }
                chunks.append(pcm)
            }
        }
        // Resample once for the whole sentence so chunk edges don't click.
        guard let joined = PCM.join(chunks), let converted = PCM.convert(joined, to: format) else { return [] }
        return [converted]
    }
}
