import Foundation
import Observation
import os

/// App-wide logging: goes to the system log (Console.app, `log stream`) and to an
/// in-memory list shown in Settings → Logs, so problems are visible on the phone too.
enum Log {
    enum Area: String {
        case app, model, voice, speech, audio, calls, messages
    }

    private static let loggers: [Area: Logger] = {
        var map: [Area: Logger] = [:]
        for area in [Area.app, .model, .voice, .speech, .audio, .calls, .messages] {
            map[area] = Logger(subsystem: "ai.assistantagent.call", category: area.rawValue)
        }
        return map
    }()

    static func info(_ area: Area, _ message: String) {
        loggers[area]?.info("\(message, privacy: .public)")
        record(area, message, isError: false)
    }

    static func error(_ area: Area, _ message: String) {
        loggers[area]?.error("\(message, privacy: .public)")
        record(area, message, isError: true)
    }

    private static func record(_ area: Area, _ message: String, isError: Bool) {
        let entry = LogEntry(date: .now, area: area.rawValue, message: message, isError: isError)
        Task { @MainActor in LogStore.shared.append(entry) }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let area: String
    let message: String
    let isError: Bool

    var line: String {
        "\(date.formatted(.dateTime.hour().minute().second())) [\(area)]\(isError ? " ERROR" : "") \(message)"
    }
}

@MainActor
@Observable
final class LogStore {
    static let shared = LogStore()
    private(set) var entries: [LogEntry] = []

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    var text: String { entries.map(\.line).joined(separator: "\n") }
}
