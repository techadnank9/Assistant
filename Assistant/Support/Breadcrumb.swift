import Foundation

/// iOS kills an app that uses too much memory without a crash, a dialog or anything on screen —
/// from the outside it just goes blank. So the app writes down what it was doing, and says so on
/// the next launch. Without this there is nothing to debug from.
enum Breadcrumb {
    private static let key = "lastActivity"

    /// `nil` when the work finished normally.
    static func record(_ activity: String?) {
        let defaults = UserDefaults.standard
        if let activity {
            defaults.set(activity, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Call once at launch: if a conversation was in flight last time, the app didn't end it.
    static func reportUnfinishedRun() {
        guard let activity = UserDefaults.standard.string(forKey: key) else { return }
        Log.error(.voice, "Last run stopped while \(activity) — the app was killed, most likely by iOS for memory. \(GPUMemory.usage)")
        record(nil)
    }
}
