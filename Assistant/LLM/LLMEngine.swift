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

    /// Downloads the weights on first use (cached afterwards) and loads them into memory.
    func load(_ option: ModelOption, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard loadedModel != option.id else { return }
        conversations.removeAll()
        container = nil
        let device = await Self.device()
        container = try await Device.withDefaultDevice(device) {
            try await #huggingFaceLoadModelContainer(
                configuration: option.configuration,
                progressHandler: { progress($0.fractionCompleted) }
            )
        }
        loadedModel = option.id
    }

    /// Starts a conversation and returns its handle. Pass `history` to seed turns
    /// that already happened, like a greeting spoken before the model was involved.
    func open(instructions: String, history: [Chat.Message] = [], maxTokens: Int = 256) throws -> UUID {
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
        guard let session = conversations[id] else { throw EngineError.notLoaded }
        let device = await Self.device()
        // Generation runs in a child task, which inherits this task-local device.
        return Device.withDefaultDevice(device) { session.streamResponse(to: prompt) }
    }

    func close(_ id: UUID) {
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
