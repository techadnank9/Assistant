import SwiftData
import SwiftUI

/// Phase 4: every message the agent has taken.
struct MessagesView: View {
    @Query(sort: \CallRecord.date, order: .reverse) private var records: [CallRecord]
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            List {
                ForEach(records) { record in
                    NavigationLink(value: record) { MessageRow(record: record) }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(records[index]) }
                }
            }
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No messages yet", systemImage: "tray",
                        description: Text("When the assistant answers a call, the message and a summary show up here. Try one from the Talk tab."))
                }
            }
            .navigationTitle("Messages")
            .navigationDestination(for: CallRecord.self) { MessageDetailView(record: $0) }
        }
    }
}

private struct MessageRow: View {
    let record: CallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !record.isRead {
                    Circle().fill(.tint).frame(width: 8, height: 8)
                }
                Text(record.title).font(.headline)
                if record.isUrgent {
                    Text("Urgent")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red.opacity(0.15), in: .capsule)
                        .foregroundStyle(.red)
                }
                if record.isTest {
                    Text("Test").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(record.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.summary ?? "Summarizing…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

struct MessageDetailView: View {
    let record: CallRecord

    var body: some View {
        List {
            Section {
                if let summary = record.summary { Text(summary) } else { Text("Summarizing…").foregroundStyle(.secondary) }
                if let name = record.callerName { LabeledContent("Name", value: name) }
                if let number = record.callerNumber {
                    LabeledContent("Number") {
                        Link(number, destination: URL(string: "tel:\(number.filter { $0.isNumber || $0 == "+" })")!)
                    }
                }
                if let callback = record.callback { LabeledContent("Call back", value: callback) }
                LabeledContent("Length", value: Duration.seconds(record.duration).formatted(.units(allowed: [.minutes, .seconds])))
            } header: {
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Transcript") {
                ForEach(record.transcript) { TurnRow(turn: $0) }
            }
        }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let number = record.callerNumber,
               let url = URL(string: "tel:\(number.filter { $0.isNumber || $0 == "+" })") {
                Link(destination: url) { Label("Call back", systemImage: "phone") }
            }
        }
        .onAppear { record.isRead = true }
    }
}
