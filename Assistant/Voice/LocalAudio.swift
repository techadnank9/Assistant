@preconcurrency import AVFoundation

/// The phone's own mic and speaker, for talking to the agent without a call.
final class LocalAudio: AudioIO, @unchecked Sendable {
    let incoming: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private let engine = AVAudioEngine()
    private let meter = LevelMeter()
    var level: Float { meter.value }

    init() {
        (incoming, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(200))
    }

    var usesSystemSpeech: Bool { true }

    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        // Plain play-and-record to the loudspeaker. The agent is half-duplex (it doesn't listen while
        // speaking), so no echo cancellation is needed, and speech plays through the system synthesizer.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        guard await AVAudioApplication.requestRecordPermission() else {
            Log.error(.audio, "Microphone permission denied")
            throw VoiceError.microphoneDenied
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        Log.info(.audio, "Mic format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch, route: \(Self.route)")
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Log.error(.audio, "No usable microphone")
            throw VoiceError.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [continuation, meter] buffer, _ in
            meter.push(buffer)
            continuation.yield(buffer)
        }
        try engine.start()
        Log.info(.audio, "Local audio started")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Unused: speech goes through the system synthesizer (`usesSystemSpeech`).
    func play(_ buffer: AVAudioPCMBuffer) {}
    func waitUntilPlayed() async {}

    private static var route: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
    }
}

enum VoiceError: LocalizedError {
    case microphoneDenied
    case speechUnavailable
    case speechDenied
    case noMicrophone
    case speechSetupTimedOut

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Turn it on in Settings."
        case .speechUnavailable: "On-device speech recognition isn't available for this language."
        case .speechDenied: "Speech recognition access is off. Turn it on in Settings."
        case .noMicrophone: "No microphone is available right now."
        case .speechSetupTimedOut: "Speech recognition is still downloading. Try again in a minute."
        }
    }
}
