import MLXLMCommon

/// The model the agent runs on. Phase 5 swaps this for a local fine-tuned directory:
/// `ModelConfiguration(directory: URL(...), extraEOSTokens: ["<|im_end|>"])`.
enum ModelChoice {
    static let current = ModelConfiguration(
        id: "mlx-community/Qwen3-1.7B-4bit",
        extraEOSTokens: ["<|im_end|>"]
    )

    static let systemPrompt = """
        You are a friendly phone assistant who answers calls when the owner can't. \
        Keep replies short and spoken-sounding: one or two sentences, no lists, no markdown.
        """
}
