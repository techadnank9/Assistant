@preconcurrency import AVFoundation
import MLXLMCommon
import Observation
import UIKit

struct Turn: Identifiable, Codable, Hashable {
    enum Speaker: String, Codable { case caller, agent }
    var id = UUID()
    let speaker: Speaker
    var text: String
}

/// The voice loop: listen → Qwen → speak, until the message is taken.
/// Runs the same way over the phone's mic (Talk tab) and over a live call.
@MainActor
@Observable
final class VoiceAgent {
    enum Phase: Equatable { case idle, starting, listening, thinking, speaking, ended }

    /// `.caller`: answers a caller and takes a message (real calls, "Test a call").
    /// `.owner`: the owner talking to their own assistant, like a voice chat.
    enum Mode: String, CaseIterable, Identifiable {
        case owner, caller
        var id: String { rawValue }
        var label: String { self == .owner ? "My assistant" : "Test a call" }
    }

    private(set) var phase: Phase = .starting {
        didSet { Breadcrumb.record(phase == .ended ? nil : "\(phase)") }
    }
    private(set) var turns: [Turn] = []
    private(set) var caption = ""
    /// What's happening during setup ("Setting up speech recognition… 40%"), shown under the orb.
    private(set) var status: String?
    private(set) var error: String?
    let startedAt = Date.now

    private let io: AudioIO
    /// Live loudness of the conversation, read every frame by the orb (not observed).
    nonisolated var audioLevel: Float { io.level }
    private let owner: String
    private let callerNumber: String?
    let mode: Mode
    private let listener = Listener()
    private let speaker = Speaker()
    private var conversation: UUID?
    private var hungUp = false
    private var listening: Task<String?, Never>?
    private var instructions = ""

    /// Longest a call may run before the agent wraps up.
    private let maxDuration: TimeInterval = 240

    init(io: AudioIO, owner: String, callerNumber: String?, mode: Mode = .caller) {
        self.mode = mode
        self.io = io
        self.owner = owner
        self.callerNumber = callerNumber
    }

    /// Runs the whole conversation and returns the transcript.
    func run() async -> [Turn] {
        Log.info(.voice, "Conversation started (caller \(callerNumber ?? "local test"))")
        do {
            try await start()
            try await converse()
        } catch is CancellationError {
            Log.info(.voice, "Conversation cancelled")
        } catch {
            Log.error(.voice, "Conversation failed: \(error)")
            self.error = error.localizedDescription
        }
        Log.info(.voice, "Conversation ended after \(turns.count) turns")
        await finish()
        return turns
    }

    /// Ends the conversation from outside, e.g. the caller hung up.
    func hangUp() {
        guard !hungUp else { return }
        hungUp = true
        listening?.cancel()
        speaker.stopSpeaking()
        // Drops any queued speech so the agent goes quiet immediately.
        io.stop()
    }

    private func start() async throws {
        phase = .starting
        // You're talking, not tapping, so iOS sees an idle screen and locks it mid-sentence.
        // Keep the screen awake for as long as the conversation lasts.
        UIApplication.shared.isIdleTimerDisabled = true
        // Microphone first: the permission prompt appears the moment you tap.
        status = "Starting the microphone…"
        Log.info(.voice, "Starting audio")
        try await io.start()
        status = nil

        // Only feed the recognizer while listening, so the agent never transcribes itself.
        let listener = listener
        #if targetEnvironment(simulator)
            (io as? ScriptedCaller)?.onSpeak = { text in Task { await listener.inject(text) } }
        #endif
        Task { [weak self, io] in
            for await buffer in io.incoming {
                guard let self, self.phase == .listening else { continue }
                await listener.feed(buffer)
            }
        }

        // Talk straight away: the greeting needs neither the recognizer nor the model, so the
        // orb answers even while first-time downloads are still running.
        let greeting = mode == .owner ? Prompts.ownerGreeting(owner: owner) : Prompts.greeting(owner: owner)
        try await say(greeting)

        phase = .starting
        Log.info(.voice, "Preparing speech recognition")
        try await listener.prepare { line in
            Task { @MainActor [weak self] in self?.status = line }
        }
        // On first use this downloads the model; the orb screen shows the progress meanwhile.
        status = nil
        Log.info(.voice, "Loading model")
        try await LLMEngine.shared.load(AppSettings.shared.model)
        let profile = AppSettings.shared.ownerProfile
        instructions = mode == .owner
            ? Prompts.voiceChat(owner: owner, profile: profile, briefing: MessageStore.shared.briefing())
            : Prompts.call(owner: owner, callerNumber: callerNumber, profile: profile)
        conversation = try await LLMEngine.shared.open(
            instructions: instructions, history: [.assistant(greeting)], maxTokens: 220)
    }

    private func converse() async throws {
        var silentTurns = 0
        while !hungUp, !Task.isCancelled {
            phase = .listening
            let captions = Task { [listener] in
                while !Task.isCancelled {
                    self.caption = await listener.partial
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let listen = Task { [listener] in await listener.nextUtterance() }
            listening = listen
            let heard = await listen.value
            captions.cancel()
            caption = ""
            if hungUp { return }

            guard let heard else {
                if let failure = await listener.failure { throw failure }
                Log.info(.voice, "No speech before timeout")
                silentTurns += 1
                if silentTurns >= 2 {
                    try await say(mode == .owner
                        ? "I'll be here whenever you need me."
                        : "I didn't catch anything, so I'll let you go. Goodbye!")
                    return
                }
                try await say(mode == .owner ? "I'm listening." : "Sorry, are you still there?")
                continue
            }
            silentTurns = 0
            Log.info(.voice, "Caller: \(heard)")
            turns.append(Turn(speaker: .caller, text: heard))

            // A caller gets a time limit; the owner can talk as long as they like.
            let overtime = mode == .caller && Date.now.timeIntervalSince(startedAt) > maxDuration
            let prompt = overtime
                ? heard + "\n\n(We're out of time. Read back the message and say goodbye now.)"
                : heard
            let reply = try await think(and: prompt)
            if mode == .caller, reply.contains(Prompts.endMarker) || overtime {
                // Don't cut them off. Offer the door, then wait a few seconds in case they
                // have one more thing — people usually do.
                if try await anythingElse() { continue }
                return
            }
        }
    }

    /// Streams Qwen's reply and speaks it sentence by sentence as it arrives.
    private func think(and prompt: String, allowRetry: Bool = true) async throws -> String {
        guard let conversation else { return "" }
        let earlierOpenings = Set(turns.filter { $0.speaker == .agent }.map { Self.opening($0.text) })
        var repeating = false
        // Speak each sentence the moment it exists, everywhere. Waiting for the whole reply before
        // making a sound left a long silence after the text had already appeared on screen; the
        // speaker renders the next sentence while the current one plays, so it still runs together.
        let speakWhileThinking = true
        phase = .thinking
        let thinkStart = Date.now
        var firstToken = true
        var raw = ""
        var spoken = 0
        let index = turns.count
        turns.append(Turn(speaker: .agent, text: ""))

        for try await chunk in try await LLMEngine.shared.respond(in: conversation, to: prompt) {
            if hungUp { break }
            if firstToken {
                firstToken = false
                Log.info(.voice, "First token after \(Int(Date.now.timeIntervalSince(thinkStart) * 1000)) ms")
            }
            raw += chunk
            let visible = ModelText.visible(raw).replacingOccurrences(of: Prompts.endMarker, with: "")
            turns[index].text = visible.trimmingCharacters(in: .whitespaces)
            // Speak each complete sentence as soon as it exists.
            while let end = Self.sentenceEnd(in: visible, from: spoken) {
                let sentence = String(visible[visible.index(visible.startIndex, offsetBy: spoken)..<end])
                // About to repeat an earlier reply? Stop before saying it and nudge the model forward.
                if spoken == 0, allowRetry, sentence.split(separator: " ").count >= 4,
                   earlierOpenings.contains(Self.opening(sentence)) {
                    repeating = true
                    break
                }
                guard speakWhileThinking else { break }
                spoken = visible.distance(from: visible.startIndex, to: end)
                await queue(sentence)
            }
            if repeating { break }
        }
        if repeating {
            Log.info(.voice, "Caught a repeated reply; nudging the model forward")
            turns.remove(at: index)
            try await restartConversation()
            let nudge = mode == .owner ? Prompts.ownerRepeatNudge : Prompts.repeatNudge
            return try await think(and: prompt + "\n\n" + nudge, allowRetry: false)
        }
        let visible = turns[index].text
        Log.info(.voice, "Agent: \(visible)")
        Log.info(.voice, "Memory: \(GPUMemory.usage)")
        if spoken < visible.count {
            await queue(String(visible.dropFirst(spoken)))
        }
        await waitForSpeech()
        return raw
    }

    /// Says goodbye properly and listens a little longer. Returns true if the caller spoke again,
    /// in which case the conversation carries on instead of ending on them.
    private func anythingElse() async throws -> Bool {
        guard !hungUp else { return false }
        try await say("If there's nothing else, I'll let you go. Thanks so much for calling, and I'll pass this on.")
        phase = .listening
        let captions = Task { [listener] in
            while !Task.isCancelled {
                self.caption = await listener.partial
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let listen = Task { [listener] in await listener.nextUtterance(timeout: .seconds(4)) }
        listening = listen
        let heard = await listen.value
        captions.cancel()
        caption = ""
        guard let heard, !hungUp else { return false }
        Log.info(.voice, "Caller had more to say: \(heard)")
        turns.append(Turn(speaker: .caller, text: heard))
        _ = try await think(and: heard + "\n\n(They had something more to add. Answer it, and only close again once they're really done.)")
        return true
    }

    private func say(_ text: String) async throws {
        turns.append(Turn(speaker: .agent, text: text))
        await queue(text)
        await waitForSpeech()
    }

    /// Waits for everything queued to be heard, whichever way it's being played.
    private func waitForSpeech() async {
        if io.usesSystemSpeech {
            await speaker.waitUntilSpoken()
            // A short gap so the mic doesn't catch the tail of the agent's own voice.
            try? await Task.sleep(for: .milliseconds(250))
        } else {
            await io.waitUntilPlayed()
        }
        io.agentFinishedSpeaking()
    }

    private func queue(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !hungUp else { return }
        if io.usesSystemSpeech {
            speaker.speak(text)
        } else {
            for buffer in await speaker.render(text, to: io.playbackFormat) {
                io.play(buffer)
            }
        }
        phase = .speaking
    }

    private func finish() async {
        phase = .ended
        UIApplication.shared.isIdleTimerDisabled = false
        if let conversation { await LLMEngine.shared.close(conversation) }
        await listener.finish()
        io.stop()
        turns.removeAll { $0.text.isEmpty }
    }

    /// Rebuilds the model's conversation from the transcript, minus the caller's latest line
    /// (which is sent again with the nudge). Used after abandoning a repeated reply.
    private func restartConversation() async throws {
        if let conversation { await LLMEngine.shared.close(conversation) }
        var history: [Chat.Message] = []
        for turn in turns.dropLast() {
            history.append(turn.speaker == .agent ? .assistant(turn.text) : .user(turn.text))
        }
        conversation = try await LLMEngine.shared.open(instructions: instructions, history: history, maxTokens: 220)
    }

    /// First sentence, lowercased without punctuation, for spotting repeats.
    private static func opening(_ text: String) -> String {
        let first = text.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? text
        return first.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    /// End of the first full sentence at or after `offset`, if one has finished.
    private static func sentenceEnd(in text: String, from offset: Int) -> String.Index? {
        guard offset < text.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: offset)
        var index = start
        while index < text.endIndex {
            let next = text.index(after: index)
            // A terminator followed by a space; the stream hasn't settled on anything later.
            if ".!?".contains(text[index]), next < text.endIndex, text[next] == " " {
                return next
            }
            index = next
        }
        return nil
    }
}

extension VoiceAgent: Identifiable {}
