import SwiftUI

/// Phase 2: talk to the agent through the phone's mic, exactly as a caller would.
struct TalkView: View {
    @State private var agent: VoiceAgent?
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let agent {
                    LiveCallView(agent: agent, title: "Test call")
                } else {
                    start
                }
            }
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

/// Live transcript of a conversation, used for test calls and real ones.
struct LiveCallView: View {
    let agent: VoiceAgent
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(agent.turns) { turn in
                            TurnRow(turn: turn).id(turn.id)
                        }
                        if !agent.caption.isEmpty {
                            TurnRow(turn: Turn(speaker: .caller, text: agent.caption))
                                .opacity(0.5)
                                .id("caption")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: agent.turns.last?.text) { proxy.scrollTo(agent.turns.last?.id, anchor: .bottom) }
                .onChange(of: agent.caption) { proxy.scrollTo("caption", anchor: .bottom) }
            }
            Button("End", systemImage: "phone.down.fill") { agent.hangUp() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .padding(.bottom, 24)
                .disabled(agent.phase == .ended)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            HStack(spacing: 6) {
                Circle().fill(phaseColor).frame(width: 8, height: 8)
                Text(phaseLabel).font(.subheadline).foregroundStyle(.secondary)
            }
            .animation(.default, value: agent.phase)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var phaseLabel: String {
        switch agent.phase {
        case .starting: "Getting ready…"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .ended: "Ended"
        }
    }

    private var phaseColor: Color {
        switch agent.phase {
        case .listening: .green
        case .thinking: .orange
        case .speaking: .blue
        case .starting, .ended: .gray
        }
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
