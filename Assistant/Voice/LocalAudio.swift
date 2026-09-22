@preconcurrency import AVFoundation

/// The phone's own mic and speaker, for talking to the agent without a call.
final class LocalAudio: AudioIO, @unchecked Sendable {
    let incoming: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private let engine = AVAudioEngine()
    private let queue = SampleQueue()
    private var speaker: AVAudioSourceNode?
    private let meter = LevelMeter()
    var level: Float { meter.value }

    init() {
        (incoming, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(200))
    }

    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        guard await AVAudioApplication.requestRecordPermission() else {
            Log.error(.audio, "Microphone permission denied")
            throw VoiceError.microphoneDenied
        }

        let input = engine.inputNode
        // Voice processing cancels the agent's own voice picked up by the mic. Some hardware
        // (and the simulator) reports no usable format with it on, so fall back to the raw mic.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            Log.error(.audio, "Voice processing unavailable: \(error)")
        }
        var inputFormat = input.outputFormat(forBus: 0)
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            Log.error(.audio, "Mic reported no format with voice processing; retrying without it")
            try? input.setVoiceProcessingEnabled(false)
            inputFormat = input.outputFormat(forBus: 0)
        }
        Log.info(.audio, "Mic format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Log.error(.audio, "No usable microphone")
            throw VoiceError.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [continuation, meter] buffer, _ in
            meter.push(buffer)
            continuation.yield(buffer)
        }

        let queue = queue
        let meter = meter
        let speaker = AVAudioSourceNode(format: playbackFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let out = UnsafeMutableBufferPointer<Float>(
                start: buffers[0].mData?.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            if queue.read(into: out) > 0, let base = out.baseAddress {
                meter.push(base, count: out.count)
            }
            return noErr
        }
        self.speaker = speaker
        engine.attach(speaker)
        engine.connect(speaker, to: engine.mainMixerNode, format: playbackFormat)
        try engine.start()
        Log.info(.audio, "Local audio started")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.removeAll()
        continuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        queue.append(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    func waitUntilPlayed() async {
        while !queue.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        // Let the output hardware drain its last buffer.
        try? await Task.sleep(for: .milliseconds(150))
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
