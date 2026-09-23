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
        // Pick up model downloads that continued (or finished) while the app was closed.
        BackgroundDownloads.shared.reconnect()
        // PushKit has to be ready at launch, including when iOS wakes us for a call.
        GPUMemory.configure()
        Breadcrumb.reportUnfinishedRun()
        CallManager.shared.startListeningForCalls()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// iOS relaunches the app to hand over downloads that finished while it was closed.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloads.sessionID else { return completionHandler() }
        BackgroundDownloads.shared.backgroundCompletion = completionHandler
        BackgroundDownloads.shared.reconnect()
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
    @State private var setup = SetupModel()
    @State private var setupDone = false
    /// "Start talking" on the setup screen goes straight into a conversation.
    @State private var talkNow = false

    var body: some View {
        Group {
            if !setup.checked {
                // Brief launch check; matches the orb screen so there's no flash.
                Color(hex: 0x07080D).ignoresSafeArea()
            } else if setupDone || setup.isReady && !setupShownThisLaunch {
                tabs
            } else {
                SetupView(setup: setup) {
                    AppSettings.shared.profilePromptSeen = true
                    talkNow = true
                    setupDone = true
                    Task { await chat.loadModel() }
                }
                .onAppear { setupShownThisLaunch = true }
            }
        }
        .task { await setup.check() }
    }

    /// Once the setup screen has appeared, keep it until the user taps Start talking.
    @State private var setupShownThisLaunch = false

    private var tabs: some View {
        TabView {
            Tab("Assistant", systemImage: "waveform") { TalkView(autoStart: talkNow) }
            Tab("Messages", systemImage: "tray") { MessagesView() }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                ChatView().environment(chat)
            }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .task {
            await chat.loadModel()
            // Warm the natural voice after the language model (downloading it first if needed, in the
            // background: the setup screen is skipped once everything else is ready).
            NaturalVoice.startDownloadIfNeeded()
        }
        .fullScreenCover(item: Binding(get: { calls.activeAgent.map(AgentBox.init) }, set: { _ in })) { box in
            LiveCallView(agent: box.agent, title: "Live call")
        }
    }
}

private struct AgentBox: Identifiable {
    let agent: VoiceAgent
    var id: ObjectIdentifier { ObjectIdentifier(agent) }
}
