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

    /// Sets up on-device recognition, downloading Apple's speech model the first time.
    /// `status` receives short progress lines for the screen.
    func prepare(status: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let module = try await Self.setUp(locale: locale, status: status)
        self.module = module

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
    func nextUtterance(timeout: Duration = .seconds(12)) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let text = currentText
            if !text.isEmpty, Date.now.timeIntervalSince(lastChange) >= Self.pause(after: text) {
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

    /// How long a silence means "done talking". A finished sentence gets a short, natural gap;
    /// a thought that trails off ("so…", "and um…") gets time to continue, like a person would.
    static func pause(after text: String) -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastWord = trimmed.lowercased()
            .split(whereSeparator: { $0 == " " }).last.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
        if continuationWords.contains(lastWord) { return 2.8 }
        if let last = trimmed.last, ".?!".contains(last) { return 1.3 }
        return 1.8   // no punctuation yet: probably mid-thought
    }

    private static let continuationWords: Set<String> = [
        "and", "but", "or", "so", "because", "cause", "um", "uh", "uhm", "er", "like", "the", "a", "an", "to",
        "of", "with", "for", "my", "your", "is", "was", "i", "i'm", "we", "if", "that", "then", "also", "about",
        "at", "in", "on", "just", "actually", "well", "which", "who", "when", "where",
    ]

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

    /// Makes sure an on-device recognizer and its speech model are installed, returning the module
    /// to use. Used by the setup screen (ahead of time) and by `prepare` (instant once installed).
    static func setUp(
        locale: Locale = Locale(identifier: "en-US"),
        status: @escaping @Sendable (String) -> Void = { _ in },
        timeout: Duration = .seconds(60)
    ) async throws -> any SpeechModule {
        // Apple requires reserving the language before its speech model can be checked or downloaded.
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            Log.error(.speech, "Couldn't reserve \(locale.identifier): \(error)")
        }
        let module = try await makeModule(locale: locale)
        do {
            try await install(module, status: status, timeout: timeout)
            return module
        } catch where module is SpeechTranscriber {
            // The newest recognizer's model is large; don't keep the caller waiting on it.
            Log.error(.speech, "SpeechTranscriber setup failed (\(error)); falling back to DictationTranscriber")
            let fallback = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            try await install(fallback, status: status, timeout: timeout + .seconds(30))
            return fallback
        }
    }

    /// True when a recognizer's speech model is already on the phone (no download needed).
    static func isInstalled(locale: Locale = Locale(identifier: "en-US")) async -> Bool {
        guard let module = try? await makeModule(locale: locale) else { return false }
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    /// Downloads a module's speech model if needed, reporting progress, within `timeout`.
    fileprivate static func install(
        _ module: any SpeechModule, status: @escaping @Sendable (String) -> Void, timeout: Duration
    ) async throws {
        let state = await AssetInventory.status(forModules: [module])
        Log.info(.speech, "Speech model status: \(state)")
        if state == .unsupported { throw VoiceError.speechUnavailable }
        guard state != .installed,
              let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        else { return }

        Log.info(.speech, "Downloading the speech model")
        status("Setting up speech recognition…")
        let reporter = Task {
            while !Task.isCancelled {
                let percent = Int(request.progress.fractionCompleted * 100)
                if percent > 0 { status("Setting up speech recognition… \(percent)%") }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { reporter.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await request.downloadAndInstall() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw VoiceError.speechSetupTimedOut
            }
            try await group.next()
            group.cancelAll()
        }
        Log.info(.speech, "Speech model installed")
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
