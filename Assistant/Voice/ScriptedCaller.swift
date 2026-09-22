#if targetEnvironment(simulator)
@preconcurrency import AVFoundation

/// Simulator-only stand-in for the microphone: speaks scripted caller lines (synthesized speech)
/// into the recognizer after the agent finishes each reply, so the whole loop can be tested
/// without a mic. Agent speech is timed but not played.
final class ScriptedCaller: AudioIO, @unchecked Sendable {
    let incoming: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private let lines = [
        "Hi, this is Rachel from Anthropic.",
        "I'm a recruiter and I'd love to set up a call with Adnan about an applied AI role.",
        "My email is rachel at anthropic dot com.",
        "Thanks so much, bye!",
    ]
    private var next = 0
    private var queued: [AVAudioPCMBuffer] = []
    private let meter = LevelMeter()
    var level: Float { meter.value }
    private var stopped = false
    /// The simulator's recognizer has no speech model, so the words are also handed over directly.
    var onSpeak: (@Sendable (String) -> Void)?

    init() {
        (incoming, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(400))
    }

    func start() async throws {
        Log.info(.audio, "Simulator: scripted caller instead of the microphone")
    }

    func stop() {
        stopped = true
        continuation.finish()
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        queued.append(buffer)
    }

    /// "Plays" the agent's reply in real time (metered for the orb), then the caller answers.
    func waitUntilPlayed() async {
        let buffers = queued
        queued.removeAll()
        for buffer in buffers {
            for chunk in Self.split(buffer, frames: 4800) where !stopped {
                meter.push(chunk)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard !stopped, next < lines.count else { return }
        let line = lines[next]
        next += 1
        Task { await self.speak(line) }
    }

    @MainActor private func speak(_ line: String) async {
        try? await Task.sleep(for: .milliseconds(400))
        Log.info(.audio, "Scripted caller says: \(line)")
        onSpeak?(line)
        let audio = await Speaker().render(line, to: playbackFormat)
        let silence = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: 4800)!
        silence.frameLength = 4800  // zero-filled 100 ms
        // Feed in real time, 100 ms at a time, then a pause so the turn ends.
        for buffer in audio {
            for chunk in Self.split(buffer, frames: 4800) {
                meter.push(chunk)
                continuation.yield(chunk)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        for _ in 0..<20 {
            continuation.yield(silence)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func split(_ buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount) -> [AVAudioPCMBuffer] {
        guard let source = buffer.floatChannelData?[0] else { return [] }
        var out: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            let count = min(frames, buffer.frameLength - offset)
            let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count)!
            chunk.frameLength = count
            chunk.floatChannelData![0].update(from: source + Int(offset), count: Int(count))
            out.append(chunk)
            offset += count
        }
        return out
    }
}
#endif
