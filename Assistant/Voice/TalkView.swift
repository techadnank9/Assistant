import SwiftUI

/// Phase 2: talk to the agent through the phone's mic, exactly as a caller would.
struct TalkView: View {
    @State private var agent: VoiceAgent?
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            start
            .fullScreenCover(item: $agent) { LiveCallView(agent: $0, title: "Test call") }
            .navigationTitle("Talk")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var start: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Pretend you're calling")
                .font(.title3.weight(.semibold))
            Text("The agent greets you and takes a message, just like on a real call. It all runs on this iPhone. The message shows up under Messages.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let lastError {
                Text(lastError).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button("Start test call", systemImage: "phone.fill", action: begin)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
        .padding(24)
    }

    private func begin() {
        #if targetEnvironment(simulator)
            let io: AudioIO = ScriptedCaller()
        #else
            let io: AudioIO = LocalAudio()
        #endif
        let agent = VoiceAgent(io: io, owner: AppSettings.shared.ownerName, callerNumber: nil)
        self.agent = agent
        lastError = nil
        Task {
            let transcript = await agent.run()
            lastError = agent.error
            self.agent = nil
            await MessageStore.shared.save(
                transcript: transcript, callerNumber: nil, startedAt: agent.startedAt, isTest: true)
        }
    }
}

/// The live call screen, for test calls and real ones: the voice orb, what's being said
/// right now, and the transcript one tap away.
struct LiveCallView: View {
    let agent: VoiceAgent
    let title: String
    @State private var showTranscript = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(phaseLabel)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: agent.phase)
            }
            .padding(.top, 24)

            Spacer(minLength: 24)

            VoiceOrb(phase: agent.phase) { agent.audioLevel }
                .frame(width: 240, height: 240)

            Spacer(minLength: 24)

            Text(currentLine)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(agent.phase == .listening ? 0.7 : 0.95))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .top)
                .padding(.horizontal, 32)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: currentLine)

            HStack(spacing: 48) {
                Button { showTranscript = true } label: {
                    Image(systemName: "text.bubble")
                        .font(.title2)
                        .frame(width: 64, height: 64)
                        .background(.white.opacity(0.12), in: .circle)
                }
                .accessibilityLabel("Transcript")

                Button { agent.hangUp() } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .frame(width: 72, height: 72)
                        .background(.red, in: .circle)
                }
                .accessibilityLabel("End call")
                .disabled(agent.phase == .ended)
            }
            .foregroundStyle(.white)
            .buttonStyle(PressScaleStyle())
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x07080D).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTranscript) {
            NavigationStack {
                List(agent.turns) { TurnRow(turn: $0) }
                    .navigationTitle("Transcript")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// What's being said right now: the caller's live caption while listening,
    /// otherwise the agent's latest line.
    private var currentLine: String {
        if agent.phase == .listening, !agent.caption.isEmpty { return agent.caption }
        if agent.phase == .starting { return "" }
        return agent.turns.last(where: { $0.speaker == .agent })?.text ?? ""
    }

    private var phaseLabel: String {
        switch agent.phase {
        case .starting: "Connecting…"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .ended: "Call ended"
        }
    }
}

/// Buttons compress slightly under the finger so a tap feels registered.
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TurnRow: View {
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(turn.speaker == .caller ? "Caller" : "Assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(turn.speaker == .caller ? Color.secondary : Color.accentColor)
            Text(turn.text)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
