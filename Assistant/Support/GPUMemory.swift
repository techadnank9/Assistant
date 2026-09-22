import Foundation
import MLX
import UIKit

/// MLX keeps freed Metal buffers in a cache so the next allocation is instant. On a Mac that's free
/// speed; on a phone it's how the app gets killed halfway through a conversation. Two models are
/// resident (Qwen, about 1 GB, and the Kokoro voice, about 330 MB), speech recognition and call
/// audio want their share, and iOS kills whichever process is biggest without warning or a crash
/// report. So the cache gets a ceiling, and everything goes back the moment iOS asks.
@MainActor
enum GPUMemory {
    /// Enough cache to keep generation quick, small enough to leave room for the voice and audio.
    private static let cacheLimit = 48 * 1024 * 1024

    private static var configured = false

    static func configure() {
        guard !configured else { return }
        configured = true
        MLX.GPU.set(cacheLimit: cacheLimit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            releaseCache("iOS memory warning")
        }
        Log.info(.model, "GPU cache limited to \(cacheLimit / 1_000_000) MB")
    }

    /// Hands the cached buffers back. The model itself stays loaded.
    nonisolated static func releaseCache(_ reason: String) {
        let before = MLX.GPU.cacheMemory
        MLX.GPU.clearCache()
        Log.info(.model, "Freed \(before / 1_000_000) MB of GPU cache (\(reason)); \(usage)")
    }

    /// For the log, so a crash report isn't the only evidence.
    nonisolated static var usage: String {
        "active \(MLX.GPU.activeMemory / 1_000_000) MB, cache \(MLX.GPU.cacheMemory / 1_000_000) MB, peak \(MLX.GPU.peakMemory / 1_000_000) MB"
    }
}
