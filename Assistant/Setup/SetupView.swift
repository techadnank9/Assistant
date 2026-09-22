import SwiftUI

/// Shown before the orb whenever something the assistant needs is missing.
struct SetupView: View {
    @Bindable var setup: SetupModel
    let onDone: () -> Void
    @State private var settings = AppSettings.shared
    @State private var editingProfile = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VoiceOrb(phase: setup.isReady ? .speaking : .idle) { 0 }
                    .frame(width: 120, height: 120)
                    .padding(.top, 32)

                VStack(spacing: 8) {
                    Text("Let's set up your assistant")
                        .font(.title2.weight(.semibold))
                    Text("Everything runs privately on this iPhone. This takes a minute, and only happens once.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    StepRow(icon: "mic.fill", title: "Microphone",
                            detail: "So the assistant can hear you.",
                            step: setup.microphone, buttonTitle: "Allow") {
                        Task { await setup.requestMicrophone() }
                    }
                    StepRow(icon: "waveform", title: "Speech recognition",
                            detail: "Understands you on the phone, offline.",
                            step: setup.speech, buttonTitle: "Try again") {
                        setup.startDownloads()
                    }
                    StepRow(icon: "cpu", title: "Assistant model",
                            detail: "Qwen3, running on this iPhone.",
                            step: setup.model, buttonTitle: "Try again") {
                        setup.startDownloads()
                    }
                    if setup.offersNaturalVoice {
                        StepRow(icon: "person.wave.2.fill", title: "Natural voice",
                                detail: "Optional. A human-sounding voice, on the iPhone.",
                                step: setup.voice, buttonTitle: "Try again") {
                            setup.startDownloads()
                        }
                    }
                    StepRow(icon: "bell.fill", title: "Notifications",
                            detail: "Optional. Get a summary after each call.",
                            step: setup.notifications, buttonTitle: "Allow") {
                        Task { await setup.requestNotifications() }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onDone) {
                Text(setup.isReady ? "Start talking" : "Finishing setup…")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!setup.isReady)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .animation(.easeOut(duration: 0.2), value: setup.isReady)
        }
        .foregroundStyle(.white)
        .background(Color(hex: 0x07080D).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task { setup.startDownloads() }
        .sheet(isPresented: $editingProfile) { ProfileEditor(settings: settings) }
    }

}

private struct StepRow: View {
    let icon: String
    let title: String
    let detail: String
    let step: SetupModel.Step
    /// Shown when the step is waiting (permissions) or failed (downloads); "Settings" when denied.
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(isProblem ? .red.opacity(0.9) : .white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                if case .working(_, let progress?) = step {
                    ProgressView(value: progress)
                        .tint(.white)
                        .animation(.linear(duration: 0.25), value: progress)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(14)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 18))
    }

    private func actionButton(_ title: String) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.white)
    }

    private var subtitle: String {
        switch step {
        case .working(let line?, let progress?): "\(line) \(Int(progress * 100))%"
        case .working(let line?, nil): line
        case .failed(let message): message
        case .denied: "Turned off. Tap to open Settings and turn it on."
        default: detail
        }
    }

    private var isProblem: Bool {
        switch step {
        case .failed, .denied: true
        default: false
        }
    }

    @ViewBuilder private var trailing: some View {
        switch step {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        case .working(_, nil):
            ProgressView().tint(.white)
        case .working:
            EmptyView()
        case .denied:
            actionButton("Settings")
        case .failed:
            actionButton(buttonTitle)
        case .waiting:
            // Downloads start by themselves; permissions and the profile wait for a tap.
            if buttonTitle != "Try again" { actionButton(buttonTitle) } else { ProgressView().tint(.white) }
        }
    }
}

/// Your name and a few lines about your work, used by every prompt.
struct ProfileEditor: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Your name") {
                    TextField("Name", text: $settings.ownerName)
                }
                Section {
                    TextField("e.g. AI engineer in San Francisco. Building voice agents. Previously team lead at Centific.",
                              text: $settings.ownerProfile, axis: .vertical)
                        .lineLimit(5...12)
                } header: {
                    Text("What you do")
                } footer: {
                    Text("Your assistant shares only this with callers who ask, and never your address, schedule or whereabouts.")
                }
            }
            .navigationTitle("About you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }
}
