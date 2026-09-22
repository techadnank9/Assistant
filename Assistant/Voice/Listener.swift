@preconcurrency import AVFoundation
import Speech

/// On-device speech to text (SpeechAnalyzer) with end-of-turn detection:
/// a turn ends when there are words and the transcript has stopped changing.
actor Listener {
    private let locale: Locale
    private var module: (any SpeechModule)?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Words already handed to the agent. Results before this are ignored.
    private var consumedThrough = CMTime.zero
    private var framesFed: Int64 = 0
    private var finalized = ""
    private var volatile = ""
    private var lastChange = Date.distantPast
    private var loggedConversionFailure = false

    /// Live caption of what the caller is saying right now.
    private(set) var partial = ""
    /// Set when the recognizer stops with an error, so the call can end instead of waiting forever.
    private(set) var failure: Error?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    func prepare() async throws {
        let module = try await Self.makeModule(locale: locale)
        self.module = module

        // Apple requires reserving the language before its speech model can be checked or downloaded.
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            Log.error(.speech, "Couldn't reserve \(locale.identifier): \(error)")
        }
        let status = await AssetInventory.status(forModules: [module])
        Log.info(.speech, "Speech model status: \(status)")
        if status == .unsupported { throw VoiceError.speechUnavailable }
        if status != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.info(.speech, "Downloading the speech model")
            try await request.downloadAndInstall()
            Log.info(.speech, "Speech model installed")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        if analyzerFormat == nil, let dictation = module as? DictationTranscriber {
            analyzerFormat = await dictation.availableCompatibleAudioFormats.first
        }
        if analyzerFormat == nil {
            // 16 kHz mono is what the on-device recognizers take natively.
            analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)
        }
        Log.info(.speech, "Analyzer format: \(analyzerFormat.map { "\($0.sampleRate) Hz, \($0.channelCount) ch" } ?? "none")")

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        try await analyzer.start(inputSequence: stream)
        Log.info(.speech, "Listening")

        resultsTask = Task {
            do {
                if let transcriber = module as? SpeechTranscriber {
                    for try await r in transcriber.results { self.handle(String(r.text.characters), r.isFinal, r.range.end) }
                } else if let dictation = module as? DictationTranscriber {
                    for try await r in dictation.results { self.handle(String(r.text.characters), r.isFinal, r.range.end) }
                }
            } catch {
                Log.error(.speech, "Transcription stopped: \(error)")
                self.fail(error)
            }
        }
    }

    /// Feeds caller audio. Only call while the agent is listening.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, let input else { return }
        guard let converted = PCM.convert(buffer, to: analyzerFormat) else {
            if !loggedConversionFailure {
                loggedConversionFailure = true
                Log.error(.speech, "Couldn't convert \(buffer.format) to \(analyzerFormat)")
            }
            return
        }
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
            if text.isEmpty, ContinuousClock.now > deadline || failure != nil { return nil }
        }
        return nil
    }

    private func fail(_ error: Error) {
        #if !targetEnvironment(simulator)  // the simulator has no speech model; its caller injects text
            failure = error
        #endif
    }

    /// Adds recognized words directly (the simulator's scripted caller; its recognizer has no model).
    func inject(_ text: String) {
        handle(text, true, .positiveInfinity)
    }

    func finish() async {
        input?.finish()
        await analyzer?.cancelAndFinishNow()
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

    /// SpeechTranscriber (newer iPhones) is the most accurate; DictationTranscriber covers the rest.
    private static func makeModule(locale: Locale) async throws -> any SpeechModule {
        if SpeechTranscriber.isAvailable,
           await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil {
            Log.info(.speech, "Using SpeechTranscriber")
            return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        }
        guard await DictationTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            Log.error(.speech, "No on-device transcriber supports \(locale.identifier)")
            throw VoiceError.speechUnavailable
        }
        Log.info(.speech, "SpeechTranscriber unavailable here; using DictationTranscriber")
        return DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    }

    private func handle(_ raw: String, _ isFinal: Bool, _ end: CMTime) {
        // Skip words that belong to a turn the agent already answered.
        guard CMTimeCompare(end, consumedThrough) > 0 else { return }
        let text = raw.trimmingCharacters(in: .whitespaces)
        if isFinal {
            Log.info(.speech, "Heard: \(text)")
            if !text.isEmpty { finalized = finalized.isEmpty ? text : finalized + " " + text }
            volatile = ""
        } else {
            volatile = text
        }
        partial = currentText
        lastChange = .now
    }
}
