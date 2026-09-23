import SwiftUI

/// Home screen: the voice orb. Tap it to talk to the assistant exactly as a caller would.
struct TalkView: View {
    /// Start talking as soon as the screen appears (opened from Chat's voice button).
    var autoStart = false
    /// Shown as a close button when the screen is presented over something else.
    var onClose: (() -> Void)?
    @State private var agent: VoiceAgent?
    @State private var lastError: String?
    @State private var settings = AppSettings.shared

    private var mode: VoiceAgent.Mode { VoiceAgent.Mode(rawValue: settings.orbMode) ?? .owner }

    var body: some View {
        LiveCallView(agent: agent, title: "Assistant", error: lastError, onStart: begin, onClose: close,
                     mode: Binding(get: { mode }, set: { settings.orbMode = $0.rawValue }))
            .task { if autoStart { begin() } }
    }

    private var close: (() -> Void)? {
        guard let onClose else { return nil }
        return {
            agent?.hangUp()
            onClose()
        }
    }

    private func begin() {
        guard agent == nil else { return }
        #if targetEnvironment(simulator)
            let io: AudioIO = ScriptedCaller()
        #else
            let io: AudioIO = LocalAudio()
        #endif
        let agent = VoiceAgent(io: io, owner: AppSettings.shared.ownerName, callerNumber: nil, mode: mode)
        self.agent = agent
        lastError = nil
        Task {
            let transcript = await agent.run()
            lastError = agent.error
            self.agent = nil
            // Only practice calls produce a message; talking to your own assistant doesn't.
            guard agent.mode == .caller else { return }
            await MessageStore.shared.save(
                transcript: transcript, callerNumber: nil, startedAt: agent.startedAt, isTest: true)
        }
    }
}

/// The orb screen. With no agent it waits for a tap; with one it shows the live
/// conversation: state, what's being said right now, transcript and end call.
struct LiveCallView: View {
    let agent: VoiceAgent?
    let title: String
    var error: String?
    var onStart: (() -> Void)?
    var onClose: (() -> Void)?
    /// Shown as a picker while idle (home screen only).
    var mode: Binding<VoiceAgent.Mode>?
    @State private var showTranscript = false
    private static let subtitleEnd = "subtitle-end"

    private var phase: VoiceAgent.Phase { agent?.phase ?? .idle }

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
                    .animation(.easeOut(duration: 0.2), value: phase)
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)

            .overlay(alignment: .topLeading) {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.12), in: .circle)
                    }
                    .accessibilityLabel("Close")
                    .padding(.leading, 16)
                    .padding(.top, 12)
                }
            }

            if let mode, agent == nil {
                Picker("Mode", selection: mode) {
                    ForEach(VoiceAgent.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .padding(.top, 16)
            }

            Spacer(minLength: 24)

            Button { onStart?() } label: {
                VoiceOrb(phase: phase) { agent?.audioLevel ?? 0 }
                    .frame(width: 240, height: 240)
                    .contentShape(.circle)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(agent != nil || onStart == nil)
            .accessibilityHint(agent == nil ? "Starts a conversation with the assistant" : "")

            Spacer(minLength: 24)

            // Live subtitle: the words appear as they're generated and it follows them down,
            // so you can read along with what's being said rather than seeing a clipped line.
            ScrollViewReader { scroll in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(currentLine)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(error != nil && agent == nil ? .red.opacity(0.9) : .white.opacity(phase == .listening || phase == .idle ? 0.7 : 0.95))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 32)
                    Color.clear.frame(height: 1).id(Self.subtitleEnd)
                }
                .frame(height: 132)
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: currentLine) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        scroll.scrollTo(Self.subtitleEnd, anchor: .bottom)
                    }
                }
            }

            controls
                .frame(height: 72)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x07080D).ignoresSafeArea())
        // Dark only on this screen; preferredColorScheme would flip the whole app.
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .tabBar)
        .sheet(isPresented: $showTranscript) {
            NavigationStack {
                List(agent?.turns ?? []) { TurnRow(turn: $0) }
                    .navigationTitle("Transcript")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private var controls: some View {
        if let agent {
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
            .transition(.opacity)
        } else {
            Text("Everything runs on this iPhone")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .transition(.opacity)
        }
    }

    /// Idle: the prompt (or last error). Live: the caller's caption while listening,
    /// otherwise the agent's latest line.
    private var currentLine: String {
        let model = ModelStatus.shared.message
        guard let agent else {
            let prompt = mode?.wrappedValue == .caller
                ? "Tap the orb and pretend you're calling"
                : "Tap the orb to talk"
            return error ?? model ?? prompt
        }
        if agent.phase == .listening, !agent.caption.isEmpty { return agent.caption }
        if agent.phase == .starting { return agent.status ?? model ?? "Getting ready…" }
        return agent.turns.last(where: { $0.speaker == .agent })?.text ?? ""
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: "Ready"
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
