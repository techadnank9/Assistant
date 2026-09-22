import SwiftData
import SwiftUI
import UserNotifications

@main
struct AssistantApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(MessageStore.shared.container)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Log.info(.app, "Launched")
        // PushKit has to be ready at launch, including when iOS wakes us for a call.
        CallManager.shared.startListeningForCalls()
        UNUserNotificationCenter.current().delegate = self
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        return true
    }

    /// Show message notifications even while the app is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

struct RootView: View {
    @State private var chat = ChatModel()
    @State private var calls = CallManager.shared

    var body: some View {
        TabView {
            Tab("Assistant", systemImage: "waveform") { TalkView() }
            Tab("Messages", systemImage: "tray") { MessagesView() }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                ChatView().environment(chat)
            }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .task { await chat.loadModel() }
        .fullScreenCover(item: Binding(get: { calls.activeAgent.map(AgentBox.init) }, set: { _ in })) { box in
            LiveCallView(agent: box.agent, title: "Live call")
        }
    }
}

private struct AgentBox: Identifiable {
    let agent: VoiceAgent
    var id: ObjectIdentifier { ObjectIdentifier(agent) }
}
