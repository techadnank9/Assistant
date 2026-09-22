import Foundation
import Observation

struct Message: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// The Chat tab: typed conversation with the same on-device model the agent uses.
@MainActor
@Observable
final class ChatModel {
    enum Status: Equatable {
        case loading(Double)
        case ready
        case generating
        case failed(String)
    }

    private(set) var messages: [Message] = []
    private(set) var status: Status = .loading(0)
    private(set) var tokensPerSecond: Double?

    private var conversation: UUID?
    private var generation: Task<Void, Never>?

    var canSend: Bool { status == .ready }

    func loadModel() async {
        status = .loading(0)
        do {
            try await LLMEngine.shared.load(AppSettings.shared.model) { fraction in
                Task { @MainActor in self.status = .loading(fraction) }
            }
            conversation = try await LLMEngine.shared.open(instructions: Self.instructions(), maxTokens: 512)
            status = .ready
        } catch {
            Log.error(.model, "Chat couldn't start: \(error)")
            status = .failed(error.localizedDescription)
        }
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !prompt.isEmpty, let opened = conversation else { return }
        // A new chat starts from a fresh briefing, so it knows about calls taken since launch.
        let isFirst = messages.isEmpty

        messages.append(Message(role: .user, text: prompt))
        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        status = .generating

        generation = Task {
            let start = Date.now
            var chunks = 0
            var raw = ""
            do {
                var conversation = opened
                if isFirst {
                    await LLMEngine.shared.close(opened)
                    conversation = try await LLMEngine.shared.open(instructions: Self.instructions(), maxTokens: 512)
                    self.conversation = conversation
                }
                for try await chunk in try await LLMEngine.shared.respond(in: conversation, to: prompt) {
                    raw += chunk
                    chunks += 1
                    update(reply.id, ModelText.visible(raw))
                }
                let elapsed = Date.now.timeIntervalSince(start)
                if elapsed > 0 { tokensPerSecond = Double(chunks) / elapsed }
            } catch is CancellationError {
            } catch {
                Log.error(.model, "Chat reply failed: \(error)")
                update(reply.id, "⚠️ \(error.localizedDescription)")
            }
            status = .ready
        }
    }

    private static func instructions() -> String {
        Prompts.chat(owner: AppSettings.shared.ownerName, profile: AppSettings.shared.ownerProfile,
                     briefing: MessageStore.shared.briefing())
    }

    /// Looks the reply up by id so a cleared conversation can't be written into.
    private func update(_ id: UUID, _ text: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].text = text
    }

    func stop() {
        generation?.cancel()
    }

    func newConversation() {
        stop()
        messages.removeAll()
        tokensPerSecond = nil
        Task {
            if let conversation { await LLMEngine.shared.close(conversation) }
            conversation = try? await LLMEngine.shared.open(instructions: Self.instructions(), maxTokens: 512)
        }
    }
}
