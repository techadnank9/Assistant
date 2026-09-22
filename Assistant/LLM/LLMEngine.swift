import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import UIKit

/// Owns the on-device model and every conversation running on it:
/// the chat tab, voice sessions and calls, and one-shot summaries.
actor LLMEngine {
    static let shared = LLMEngine()

    private var container: ModelContainer?
    private var loadedModel: String?
    private var conversations: [UUID: ChatSession] = [:]

    var isLoaded: Bool { container != nil }

    #if targetEnvironment(simulator)
        /// MLX can't start in the simulator (its Metal device aborts at init), so simulator builds
        /// use scripted replies. Everything around the model — speech, voice, UI, saving — is real.
        private var simulatorTurns: [UUID: Int] = [:]
        private var simulatorSummaries: Set<UUID> = []
    #endif

    /// Downloads the weights on first use (cached afterwards) and loads them into memory.
    func load(_ option: ModelOption, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard loadedModel != option.id else { return }
        #if targetEnvironment(simulator)
            Log.info(.model, "Simulator: using scripted replies instead of \(option.id)")
            loadedModel = option.id
            progress(1)
            return
        #endif
        conversations.removeAll()
        container = nil
        let device = await Self.device()
        let start = Date.now
        Log.info(.model, "Loading \(option.id) on \(device)")
        let lastLogged = LockedValue(-1)
        do {
            container = try await Device.withDefaultDevice(device) {
                try await #huggingFaceLoadModelContainer(
                    configuration: option.configuration,
                    progressHandler: { p in
                        progress(p.fractionCompleted)
                        let tenth = Int(p.fractionCompleted * 10)
                        if lastLogged.swap(tenth) != tenth {
                            Log.info(.model, "Download \(tenth * 10)%")
                        }
                    }
                )
            }
        } catch {
            Log.error(.model, "Load failed: \(error)")
            throw error
        }
        loadedModel = option.id
        Log.info(.model, "Loaded in \(Int(Date.now.timeIntervalSince(start)))s")
    }

    /// Starts a conversation and returns its handle. Pass `history` to seed turns
    /// that already happened, like a greeting spoken before the model was involved.
    func open(instructions: String, history: [Chat.Message] = [], maxTokens: Int = 256) throws -> UUID {
        #if targetEnvironment(simulator)
            let scripted = UUID()
            simulatorTurns[scripted] = 0
            if instructions == Prompts.summary { simulatorSummaries.insert(scripted) }
            return scripted
        #endif
        guard let container else { throw EngineError.notLoaded }
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.7, topP: 0.8)
        // Qwen3 thinks out loud by default; a phone agent needs to answer right away.
        let context: [String: any Sendable] = ["enable_thinking": false]
        let session = history.isEmpty
            ? ChatSession(container, instructions: instructions, generateParameters: parameters, additionalContext: context)
            : ChatSession(container, instructions: instructions, history: history,
                          generateParameters: parameters, additionalContext: context)
        let id = UUID()
        conversations[id] = session
        return id
    }

    func respond(in id: UUID, to prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        #if targetEnvironment(simulator)
            return simulatedReply(in: id, to: prompt)
        #endif
        guard let session = conversations[id] else {
            Log.error(.model, "Respond called with no loaded model or unknown conversation")
            throw EngineError.notLoaded
        }
        let device = await Self.device()
        // Generation runs in a child task, which inherits this task-local device.
        return Device.withDefaultDevice(device) { session.streamResponse(to: prompt) }
    }

    func close(_ id: UUID) {
        #if targetEnvironment(simulator)
            simulatorTurns[id] = nil
            simulatorSummaries.remove(id)
        #endif
        conversations[id] = nil
    }

    /// Single prompt, single answer. Used for call summaries.
    func complete(instructions: String, prompt: String) async throws -> String {
        let id = try open(instructions: instructions, maxTokens: 200)
        defer { conversations[id] = nil }
        var text = ""
        for try await chunk in try await respond(in: id, to: prompt) { text += chunk }
        return ModelText.visible(text)
    }

    #if targetEnvironment(simulator)
        private func simulatedReply(in id: UUID, to prompt: String) -> AsyncThrowingStream<String, Error> {
            let turn = simulatorTurns[id, default: 0]
            simulatorTurns[id] = turn + 1
            let reply: String
            if simulatorSummaries.contains(id) {
                reply = "Name: Test Caller\nCallback: None\nUrgent: no\nSummary: A simulator test call; the caller said \"\(prompt.prefix(60))\"."
            } else {
                let script = [
                    "Thanks. Who am I speaking with?",
                    "Got it. And what's this about?",
                    "Thanks. What's the best number to reach you?",
                    "Perfect, I'll pass that on. Bye! \(Prompts.endMarker)",
                ]
                reply = script[min(turn, script.count - 1)]
            }
            let words = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            return AsyncThrowingStream { continuation in
                Task {
                    for (i, word) in words.enumerated() {
                        try? await Task.sleep(for: .milliseconds(40))
                        continuation.yield(i == 0 ? word : " " + word)
                    }
                    continuation.finish()
                }
            }
        }
    #endif

    /// iOS refuses GPU work from background apps. A call answered from the lock screen
    /// leaves the app in the background, so fall back to the CPU there.
    @MainActor private static func device() -> Device {
        UIApplication.shared.applicationState == .background ? .cpu : .gpu
    }

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The model isn't loaded yet." }
    }
}

/// Tiny thread-safe box for values touched from download callbacks.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }

    /// Stores `new` and returns what was there before.
    func swap(_ new: T) -> T {
        lock.withLock {
            let old = value
            value = new
            return old
        }
    }
}

enum ModelText {
    /// Qwen3 can still emit an empty think block with thinking disabled; hide it.
    static func visible(_ raw: String) -> String {
        var text = raw
        if let start = text.range(of: "<think>") {
            if let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
