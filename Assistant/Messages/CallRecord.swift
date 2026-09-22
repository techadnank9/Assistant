import Foundation
import SwiftData

/// One message the agent took, from a real call or a test in the Talk tab.
@Model
final class CallRecord {
    var date: Date
    var duration: TimeInterval
    var callerNumber: String?
    var callerName: String?
    var callback: String?
    var summary: String?
    var isUrgent: Bool
    var isTest: Bool
    var isRead: Bool
    var transcriptData: Data

    init(date: Date, duration: TimeInterval, callerNumber: String?, transcript: [Turn], isTest: Bool) {
        self.date = date
        self.duration = duration
        self.callerNumber = callerNumber
        self.isUrgent = false
        self.isTest = isTest
        self.isRead = false
        self.transcriptData = (try? JSONEncoder().encode(transcript)) ?? Data()
    }

    var transcript: [Turn] {
        (try? JSONDecoder().decode([Turn].self, from: transcriptData)) ?? []
    }

    var title: String {
        callerName ?? callerNumber ?? (isTest ? "Test call" : "Unknown caller")
    }
}
