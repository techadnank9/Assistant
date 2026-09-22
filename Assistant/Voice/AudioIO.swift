@preconcurrency import AVFoundation

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
