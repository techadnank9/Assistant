import Foundation
import Observation

struct Message: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

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

    let engine = LLMEngine()
    private var generation: Task<Void, Never>?

    var canSend: Bool { status == .ready }

    func loadModel() async {
        do {
            try await engine.load { fraction in
                Task { @MainActor in self.status = .loading(fraction) }
            }
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !prompt.isEmpty else { return }

        messages.append(Message(role: .user, text: prompt))
        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        status = .generating

        generation = Task {
            let start = Date.now
            var chunks = 0
            var raw = ""
            do {
                for try await chunk in try await engine.respond(to: prompt) {
                    raw += chunk
                    chunks += 1
                    update(reply.id, Self.visibleText(raw))
                }
                let elapsed = Date.now.timeIntervalSince(start)
                if elapsed > 0 { tokensPerSecond = Double(chunks) / elapsed }
            } catch is CancellationError {
            } catch {
                update(reply.id, "⚠️ \(error.localizedDescription)")
            }
            status = .ready
        }
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
        Task { await engine.reset() }
    }

    /// Qwen3 can still emit an empty think block with thinking disabled; hide it.
    private static func visibleText(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: "<think>") {
            if let end = text.range(of: "</think>", range: range.upperBound..<text.endIndex) {
                text.removeSubrange(range.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(range.lowerBound..<text.endIndex)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
