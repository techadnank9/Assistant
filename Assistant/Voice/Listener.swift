@preconcurrency import AVFoundation
import Speech

/// On-device speech to text (SpeechAnalyzer) with end-of-turn detection:
/// a turn ends when there are words and the transcript has stopped changing.
actor Listener {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var analyzerFormat: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Words already handed to the agent. Results before this are ignored.
    private var consumedThrough = CMTime.zero
    private var framesFed: Int64 = 0
    private var finalized = ""
    private var volatile = ""
    private var lastChange = Date.distantPast

    /// Live caption of what the caller is saying right now.
    private(set) var partial = ""

    init(locale: Locale = Locale(identifier: "en-US")) {
        transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func prepare() async throws {
        guard await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) != nil else {
            throw VoiceError.speechUnavailable
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [transcriber] in
            do {
                for try await result in transcriber.results { self.handle(result) }
            } catch {}
        }
    }

    /// Feeds caller audio. Only call while the agent is listening.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, let input,
              let converted = PCM.convert(buffer, to: analyzerFormat) else { return }
        framesFed += Int64(converted.frameLength)
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// Waits for the caller to finish a sentence. Returns nil if nobody speaks within `timeout`.
    func nextUtterance(timeout: Duration = .seconds(12), pause: TimeInterval = 1.0) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let text = currentText
            if !text.isEmpty, Date.now.timeIntervalSince(lastChange) >= pause {
                consume()
                return text
            }
            if text.isEmpty, ContinuousClock.now > deadline { return nil }
        }
        return nil
    }

    func finish() async {
        input?.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    private var currentText: String {
        [finalized, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func consume() {
        consumedThrough = CMTime(value: framesFed, timescale: CMTimeScale(analyzerFormat?.sampleRate ?? 16_000))
        finalized = ""
        volatile = ""
        partial = ""
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        // Skip words that belong to a turn the agent already answered.
        guard CMTimeCompare(result.range.end, consumedThrough) > 0 else { return }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
        if result.isFinal {
            if !text.isEmpty { finalized = finalized.isEmpty ? text : finalized + " " + text }
            volatile = ""
        } else {
            volatile = text
        }
        partial = currentText
        lastChange = .now
    }
}
