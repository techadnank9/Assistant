import SwiftUI

/// Settings → Logs: what the app has been doing, newest last, shareable.
struct LogsView: View {
    @State private var store = LogStore.shared

    var body: some View {
        ScrollViewReader { proxy in
            List(store.entries) { entry in
                Text(entry.line)
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.isError ? .red : .primary)
                    .textSelection(.enabled)
                    .id(entry.id)
            }
            .listStyle(.plain)
            .onAppear { proxy.scrollTo(store.entries.last?.id, anchor: .bottom) }
        }
        .overlay {
            if store.entries.isEmpty { ContentUnavailableView("No logs yet", systemImage: "doc.text") }
        }
        .navigationTitle("Logs")
        .toolbar {
            ShareLink(item: store.text) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}
