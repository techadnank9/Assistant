import Foundation
import SwiftData
import UIKit
import UserNotifications

/// Saves each finished call, summarizes it with Qwen, and notifies you.
@MainActor
final class MessageStore {
    static let shared = MessageStore()

    let container: ModelContainer = {
        do {
            return try ModelContainer(for: CallRecord.self)
        } catch {
            fatalError("Couldn't open the message store: \(error)")
        }
    }()

    func save(transcript: [Turn], callerNumber: String?, startedAt: Date, isTest: Bool) async {
        // Nothing but our own greeting: the caller hung up straight away.
        guard transcript.contains(where: { $0.speaker == .caller }) else { return }

        // Finishing can outlive the call, which is when iOS would otherwise suspend us.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Summarize call")
        defer { UIApplication.shared.endBackgroundTask(background) }

        let record = CallRecord(
            date: startedAt, duration: Date.now.timeIntervalSince(startedAt),
            callerNumber: callerNumber, transcript: transcript, isTest: isTest)
        container.mainContext.insert(record)
        try? container.mainContext.save()

        await summarize(record)
        await notify(record)
    }

    func summarize(_ record: CallRecord) async {
        let transcript = record.transcript
            .map { "\($0.speaker == .caller ? "Caller" : "Assistant"): \($0.text)" }
            .joined(separator: "\n")
        guard let reply = try? await LLMEngine.shared.complete(instructions: Prompts.summary, prompt: transcript)
        else { return }

        let fields = Summary.parse(reply)
        record.callerName = fields.name
        record.callback = fields.callback
        record.isUrgent = fields.urgent
        record.summary = fields.summary ?? reply
        try? container.mainContext.save()
    }

    private func notify(_ record: CallRecord) async {
        let content = UNMutableNotificationContent()
        content.title = record.isUrgent ? "Urgent message from \(record.title)" : "Message from \(record.title)"
        content.body = record.summary ?? "New message. Open to read the transcript."
        content.sound = .default
        if record.isUrgent { content.interruptionLevel = .timeSensitive }
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

enum Summary {
    struct Fields {
        var name: String?
        var callback: String?
        var urgent = false
        var summary: String?
    }

    /// Reads the `Name: / Callback: / Urgent: / Summary:` lines the summary prompt asks for.
    static func parse(_ text: String) -> Fields {
        var fields = Fields()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            let missing = ["unknown", "none", "n/a", ""].contains(value.lowercased())
            switch key {
            case "name": fields.name = missing ? nil : value
            case "callback": fields.callback = missing ? nil : value
            case "urgent": fields.urgent = value.lowercased().hasPrefix("y")
            case "summary": fields.summary = missing ? nil : value
            default: break
            }
        }
        return fields
    }
}
