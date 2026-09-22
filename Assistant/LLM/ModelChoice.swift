import Foundation
import MLXLMCommon

/// Which weights the agent runs on. Phase 5 adds the fine-tuned model here
/// (or type its Hugging Face repo id into Settings).
struct ModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String

    static let base = ModelOption(id: "mlx-community/Qwen3-1.7B-4bit", label: "Qwen3 1.7B (base)")
    static let small = ModelOption(id: "mlx-community/Qwen3-0.6B-4bit", label: "Qwen3 0.6B (fastest)")
    static let presets: [ModelOption] = [.base, .small]

    var configuration: ModelConfiguration {
        ModelConfiguration(id: id, extraEOSTokens: ["<|im_end|>"])
    }
}

enum Prompts {
    static let chat = """
        You are a friendly phone assistant who answers calls when the owner can't. \
        Keep replies short and spoken-sounding: one or two sentences, no lists, no markdown.
        """

    /// Marker the model appends when the call should end. Stripped before speaking.
    static let endMarker = "[END]"

    static func greeting(owner: String) -> String {
        "Hi, you've reached \(owner)'s phone. \(owner) can't pick up right now, this is their assistant. Can I take a message?"
    }

    static func call(owner: String, callerNumber: String?) -> String {
        let caller = callerNumber.map { "The caller's number is \($0)." } ?? "The caller's number is unknown."
        return """
            You are \(owner)'s phone assistant, answering a live phone call because \(owner) can't pick up. \
            \(caller) Your job is to take a message: find out who is calling, why, and the best way to reach them back. \

            Rules:
            - You are speaking out loud. Reply in one or two short, warm sentences. Never use lists, emoji or markdown.
            - Ask for one missing thing at a time: name, then reason, then callback number or time if they haven't said it.
            - Never promise what \(owner) will do. Say you'll pass the message on.
            - Don't give out personal information about \(owner).
            - The caller's words come from speech recognition and may have small errors; don't point them out.
            - When you have the message, or the caller says goodbye, read back the key details in one sentence, \
            say goodbye, and end your reply with \(endMarker).
            """
    }

    static let summary = """
        You write call summaries for a busy person. Read the phone transcript and reply in exactly this format, \
        with nothing else:
        Name: <caller's name, or Unknown>
        Callback: <number or time to call back, or None>
        Urgent: <yes or no>
        Summary: <one sentence saying who called and what they want>
        """
}
