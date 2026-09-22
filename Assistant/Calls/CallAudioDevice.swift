@preconcurrency import AVFoundation
import TwilioVoice

/// Connects a Twilio call to the voice agent instead of the mic and earpiece.
///
/// One AVAudioEngine, clocked by the phone's audio hardware, runs two source nodes:
/// - `callerNode` pulls the caller's audio out of Twilio. A tap sends it to speech-to-text.
/// - `agentNode` plays the agent's queued speech and pushes the same samples into the call.
/// Both also reach the speaker when "listen in" is on, so you can hear the call.
final class CallAudioDevice: NSObject, AudioDevice, AudioIO, @unchecked Sendable {
    static let sampleRate = 48_000.0

    let incoming: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private let listenIn: Bool
    private let engine = AVAudioEngine()
    private let agentAudio = SampleQueue()
    private let lock = NSLock()
    private var renderContext: AudioDeviceContext?
    private var captureContext: AudioDeviceContext?
    private var sessionActive = false
    private var nodesAttached = false

    /// Scratch space for Int16 samples, so the real-time thread never allocates.
    private let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 8192)

    init(listenIn: Bool) {
        self.listenIn = listenIn
        (incoming, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(200))
        super.init()
    }

    deinit {
        scratch.deallocate()
    }

    // MARK: CallKit hooks

    func audioSessionActivated() {
        lock.withLock { sessionActive = true }
        startEngineIfReady()
    }

    func audioSessionDeactivated() {
        lock.withLock { sessionActive = false }
        engine.stop()
    }

    // MARK: AudioIO (the agent's side)

    /// The call's audio is started by Twilio and CallKit, so wait for it to be flowing.
    func start() async throws {
        for _ in 0..<100 where !engine.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func stop() {
        continuation.finish()
        agentAudio.removeAll()
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        agentAudio.append(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    func waitUntilPlayed() async {
        while !agentAudio.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(150))
    }

    // MARK: AudioDevice (Twilio's side)

    private var twilioFormat: AudioFormat {
        AudioFormat(channels: AudioFormat.ChannelsMono, sampleRate: UInt32(Self.sampleRate), framesPerBuffer: 480)!
    }

    func renderFormat() -> AudioFormat? { twilioFormat }
    func captureFormat() -> AudioFormat? { twilioFormat }
    func initializeRenderer() -> Bool { true }
    func initializeCapturer() -> Bool { true }

    func startRendering(_ context: AudioDeviceContext) -> Bool {
        lock.withLock { renderContext = context }
        startEngineIfReady()
        return true
    }

    func stopRendering() -> Bool {
        lock.withLock { renderContext = nil }
        return true
    }

    func startCapturing(_ context: AudioDeviceContext) -> Bool {
        lock.withLock { captureContext = context }
        startEngineIfReady()
        return true
    }

    func stopCapturing() -> Bool {
        lock.withLock { captureContext = nil }
        return true
    }

    // MARK: Engine

    private func startEngineIfReady() {
        let ready = lock.withLock { sessionActive && renderContext != nil }
        guard ready, !engine.isRunning else { return }
        if !nodesAttached {
            attachNodes()
            nodesAttached = true
        }
        engine.prepare()
        try? engine.start()
    }

    private func attachNodes() {
        let format = playbackFormat
        let callerNode = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, list in
            let out = Self.channel(list, frameCount)
            guard let context = lock.withLock({ renderContext }), out.count <= 8192 else {
                out.update(repeating: 0)
                return noErr
            }
            scratch.withMemoryRebound(to: Int8.self, capacity: out.count * 2) {
                AudioDeviceReadRenderData(context: context, data: $0, sizeInBytes: out.count * 2)
            }
            for i in 0..<out.count { out[i] = Float(scratch[i]) / 32_768 }
            return noErr
        }

        let agentNode = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, list in
            let out = Self.channel(list, frameCount)
            agentAudio.read(into: out)
            guard let context = lock.withLock({ captureContext }), out.count <= 8192 else { return noErr }
            for i in 0..<out.count {
                scratch[i] = Int16(max(-1, min(1, out[i])) * 32_767)
            }
            scratch.withMemoryRebound(to: Int8.self, capacity: out.count * 2) {
                AudioDeviceWriteCaptureData(context: context, data: $0, sizeInBytes: out.count * 2)
            }
            return noErr
        }

        for node in [callerNode, agentNode] {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            node.volume = listenIn ? 1 : 0
        }
        callerNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [continuation] buffer, _ in
            continuation.yield(buffer)
        }
    }

    private static func channel(_ list: UnsafeMutablePointer<AudioBufferList>, _ frames: AVAudioFrameCount)
        -> UnsafeMutableBufferPointer<Float>
    {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return UnsafeMutableBufferPointer(
            start: buffers[0].mData?.assumingMemoryBound(to: Float.self), count: Int(frames))
    }
}
