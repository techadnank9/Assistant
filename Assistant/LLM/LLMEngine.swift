import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Owns the on-device model and the running conversation.
/// Shared by the chat screen now and the voice loop in Phase 2.
actor LLMEngine {
    private var container: ModelContainer?
    private var session: ChatSession?

    /// Downloads the weights on first run (cached afterwards) and loads them into memory.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard container == nil else { return }
        let container = try await #huggingFaceLoadModelContainer(
            configuration: ModelChoice.current,
            progressHandler: { progress($0.fractionCompleted) }
        )
        self.container = container
        self.session = makeSession(container)
    }

    func respond(to prompt: String) throws -> AsyncThrowingStream<String, Error> {
        guard let session else { throw EngineError.notLoaded }
        return session.streamResponse(to: prompt)
    }

    func reset() {
        guard let container else { return }
        session = makeSession(container)
    }

    private func makeSession(_ container: ModelContainer) -> ChatSession {
        ChatSession(
            container,
            instructions: ModelChoice.systemPrompt,
            generateParameters: GenerateParameters(maxTokens: 512, temperature: 0.7, topP: 0.8),
            // Qwen3 thinks out loud by default; a phone agent needs to answer right away.
            additionalContext: ["enable_thinking": false]
        )
    }

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The model isn't loaded yet." }
    }
}
