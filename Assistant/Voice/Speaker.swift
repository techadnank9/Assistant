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

    // MARK: Speaking out loud (the phone's own speaker)

    private let tracker = SpeechTracker()

    // Natural (Kokoro) voice: sentences queue up; the next is rendered while the current one plays.
    private var naturalQueue: [String] = []
    private var naturalBusy = false
    private var player: AVAudioPlayer?
    private var naturalTask: Task<Void, Never>?

    /// True when the downloaded neural voice should be used instead of Apple's.
    static var usesNaturalVoice: Bool {
        NaturalVoice.isSupported && AppSettings.shared.naturalVoice
            && NaturalVoice.isDownloaded
    }

    /// Speaks `text` through the loudspeaker. Utterances queue up and play in order.
    func speak(_ text: String) {
        if Self.usesNaturalVoice {
            Log.info(.audio, "Speaking (natural): \(text)")
            naturalQueue.append(contentsOf: Self.chunks(text))
            if !naturalBusy {
                naturalBusy = true
                naturalTask = Task { await runNatural() }
            }
            return
        }
        speakWithApple(text)
    }

    private func speakWithApple(_ text: String) {
        if synthesizer.delegate == nil { synthesizer.delegate = tracker }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        tracker.queued(characters: text.count)
        Log.info(.audio, "Speaking: \(text)")
        synthesizer.speak(utterance)
    }

    /// Returns when everything queued with `speak` has been said. Never hangs: gives up after
    /// roughly twice the expected speaking time.
    func waitUntilSpoken() async {
        let start = Date.now
        let characters = tracker.queuedCharacters + naturalQueue.reduce(0) { $0 + $1.count }
        let limit = 10 + Double(max(characters, 40)) / 5
        while tracker.pending > 0 || naturalBusy {
            if Date.now.timeIntervalSince(start) > limit {
                Log.error(.audio, "Speech didn't finish after \(Int(limit))s (speaking: \(synthesizer.isSpeaking)); moving on")
                stopSpeaking()
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        tracker.reset()
        Log.info(.audio, "Finished speaking in \(String(format: "%.1f", Date.now.timeIntervalSince(start)))s")
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        tracker.reset()
        naturalQueue.removeAll()
        naturalTask?.cancel()
        player?.stop()
        naturalBusy = false
    }

    private func runNatural() async {
        let voice = AppSettings.shared.kokoroVoice
        var upcoming: (text: String, audio: Task<Data?, Never>)?
        while !Task.isCancelled, upcoming != nil || !naturalQueue.isEmpty {
            let current: (text: String, audio: Data?)
            if let next = upcoming {
                current = (next.text, await next.audio.value)
            } else {
                let text = naturalQueue.removeFirst()
                current = (text, await Self.render(text, voice: voice))
            }
            upcoming = nil
            if !naturalQueue.isEmpty {
                let text = naturalQueue.removeFirst()
                upcoming = (text, Task { await Self.render(text, voice: voice) })
            }
            if let audio = current.audio, await play(audio) { continue }
            // Neural voice failed for this sentence: say it with Apple's voice instead.
            speakWithApple(current.text)
            while tracker.pending > 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        }
        naturalBusy = false
    }

    private static func render(_ text: String, voice: String) async -> Data? {
        do {
            return try await NaturalVoice.shared.synthesize(text, voice: voice)
        } catch {
            Log.error(.audio, "Natural voice couldn't render \"\(text)\": \(error)")
            return nil
        }
    }

    /// Plays WAV data to the end. Returns false if it couldn't play.
    private func play(_ audio: Data) async -> Bool {
        do {
            let player = try AVAudioPlayer(data: audio)
            self.player = player
            guard player.play() else {
                Log.error(.audio, "AVAudioPlayer refused to play")
                return false
            }
            while player.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            return true
        } catch {
            Log.error(.audio, "Couldn't play natural voice audio: \(error)")
            return false
        }
    }

    /// Whole sentences grouped into takes of up to ~300 characters: one natural take for a normal
    /// reply, split only when a reply is long enough that rendering it in one go would delay it.
    private static func chunks(_ text: String) -> [String] {
        var takes: [String] = []
        for sentence in sentences(text) {
            if let last = takes.last, last.count + sentence.count < 300 {
                takes[takes.count - 1] = last + " " + sentence
            } else {
                takes.append(sentence)
            }
        }
        return takes
    }

    private static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if ".!?".contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
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

/// Counts utterances still to be spoken, from the synthesizer's delegate callbacks.
private final class SpeechTracker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var characters = 0

    var pending: Int { lock.withLock { count } }
    var queuedCharacters: Int { lock.withLock { characters } }

    func queued(characters added: Int) {
        lock.withLock {
            count += 1
            characters += added
        }
    }

    func reset() {
        lock.withLock {
            count = 0
            characters = 0
        }
    }

    private func done() {
        lock.withLock { count = max(0, count - 1) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { done() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { done() }
}
