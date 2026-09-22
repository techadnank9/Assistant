import SwiftUI

struct ChatView: View {
    @Environment(ChatModel.self) private var chat
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if chat.messages.isEmpty { emptyState }
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message, isStreaming: isStreaming(message))
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.last?.text) {
                    guard let last = chat.messages.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { statusLabel }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { chat.newConversation() }
                        .disabled(chat.messages.isEmpty)
                }
            }
        }
    }

    private func isStreaming(_ message: Message) -> Bool {
        chat.status == .generating && message.id == chat.messages.last?.id
    }

    @ViewBuilder private var statusLabel: some View {
        switch chat.status {
        case .loading(let fraction):
            Label(fraction > 0 && fraction < 1 ? "\(Int(fraction * 100))%" : "Loading",
                  systemImage: "arrow.down.circle")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        case .failed:
            Label("Error", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .ready, .generating:
            if let tps = chat.tokensPerSecond {
                Text("\(tps, specifier: "%.0f") tok/s")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "phone.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            switch chat.status {
            case .loading(let fraction):
                Text("Loading the model on this iPhone")
                    .font(.headline)
                ProgressView(value: fraction)
                    .frame(maxWidth: 220)
                Text("About 1 GB, downloaded once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let error):
                Text("Couldn't load the model").font(.headline)
                Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await chat.loadModel() } }
                    .buttonStyle(.bordered)
            default:
                Text("Running on this iPhone").font(.headline)
                Text("Chat with the model the phone agent uses.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.fill.tertiary, in: .rect(cornerRadius: 20))
                .onSubmit(send)

            if chat.status == .generating {
                Button("Stop", systemImage: "stop.circle.fill", action: chat.stop)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 32))
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 32))
                    .disabled(!chat.canSend || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        chat.send(draft)
        draft = ""
    }
}

private struct MessageBubble: View {
    let message: Message
    let isStreaming: Bool

    var body: some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: 48) }
            Group {
                if message.text.isEmpty && isStreaming {
                    ProgressView().padding(.vertical, 2)
                } else {
                    Text(message.text).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .background(isUser ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.secondary),
                        in: .rect(cornerRadius: 18))
            if !isUser { Spacer(minLength: 48) }
        }
    }
}
