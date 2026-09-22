import Accelerate
@preconcurrency import AVFoundation
import QuartzCore

/// Where the agent hears and speaks. `LocalAudio` is the phone's mic and speaker
/// (Phase 2); `CallAudioDevice` is a live Twilio call (Phase 3).
protocol AudioIO: AnyObject, Sendable {
    /// Audio of the person talking to the agent.
    var incoming: AsyncStream<AVAudioPCMBuffer> { get }
    /// Format that `play` expects.
    var playbackFormat: AVAudioFormat { get }

    func start() async throws
    func stop()
    /// Queues agent speech. Must already be in `playbackFormat`.
    func play(_ buffer: AVAudioPCMBuffer)
    /// Returns once everything queued with `play` has been heard.
    func waitUntilPlayed() async
    /// Loudness of whatever is being heard or spoken right now, 0...1. Drives the voice orb.
    var level: Float { get }
    /// True when speech should be played by the system speech synthesizer straight to the
    /// speaker (the phone's own mic and speaker) rather than handed over as audio buffers (a call).
    var usesSystemSpeech: Bool { get }
    /// Called each time the agent has finished saying something.
    func agentFinishedSpeaking()
}

extension AudioIO {
    var usesSystemSpeech: Bool { false }
    func agentFinishedSpeaking() {}
}

/// Smoothed loudness from raw samples. Safe to feed from a real-time audio thread.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var stamp = CACurrentMediaTime()

    func push(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        // Map roughly -50 dB (room tone) ... -10 dB (loud speech) onto 0...1.
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = min(1, max(0, (db + 50) / 40))
        let now = CACurrentMediaTime()
        lock.withLock {
            peak = max(normalized, decayed(at: now))
            stamp = now
        }
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        push(data[0], count: Int(buffer.frameLength))
    }

    var value: Float {
        lock.withLock { decayed(at: CACurrentMediaTime()) }
    }

    /// Falls back toward silence quickly so the orb settles between words.
    private func decayed(at now: CFTimeInterval) -> Float {
        peak * Float(exp(-(now - stamp) * 5))
    }
}

enum PCM {
    /// Concatenates buffers that share a format.
    static func join(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let format = buffers.first?.format else { return nil }
        let total = buffers.reduce(0) { $0 + $1.frameLength }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return nil }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let destination = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        var offset = 0
        for buffer in buffers {
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bytes = Int(buffer.frameLength) * bytesPerFrame
            for channel in 0..<min(source.count, destination.count) {
                guard let from = source[channel].mData, let to = destination[channel].mData else { continue }
                (to + offset).copyMemory(from: from, byteCount: bytes)
            }
            offset += bytes
        }
        out.frameLength = total
        return out
    }

    /// Converts a whole buffer between formats (sample rate, channel count, sample type).
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}

/// A single-reader, single-writer PCM queue safe to touch from a real-time audio thread.
final class SampleQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var readIndex = 0

    var isEmpty: Bool { lock.withLock { readIndex >= samples.count } }

    func append(_ newSamples: UnsafeBufferPointer<Float>) {
        lock.withLock {
            if readIndex > 48_000 {
                samples.removeFirst(readIndex)
                readIndex = 0
            }
            samples.append(contentsOf: newSamples)
        }
    }

    /// Fills `out` with queued samples, padding with silence. Returns how many were real.
    @discardableResult
    func read(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        lock.withLock {
            let available = min(out.count, samples.count - readIndex)
            for i in 0..<available { out[i] = samples[readIndex + i] }
            for i in available..<out.count { out[i] = 0 }
            readIndex += available
            return available
        }
    }

    func removeAll() {
        lock.withLock {
            samples.removeAll()
            readIndex = 0
        }
    }
}
